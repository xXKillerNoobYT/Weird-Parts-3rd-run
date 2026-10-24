@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_join_test.dart' show JoinFixture, activateFixtureB, sqlSnapshot;
import 'company_created_job_sync_test.dart' show openSyncPair;
import 'company_job_name_test.dart' show canonicalNameTest;

PatchJobDetails patch(
  CompanyJobView v,
  OwnerSession owner,
  JobDetailsPatch values,
  Map<JobDetailField, List<String>> parents, {
  Set<JobDetailField> resolve = const {},
}) => PatchJobDetails(
  companyId: owner.identity.companyId,
  shopId: owner.identity.shopId,
  jobId: v.baseJob.id,
  requestId: const Uuid().v4(),
  creationDigest: v.creationDigest,
  patch: values,
  observedHeads: parents,
  resolvingFields: resolve,
);
String digest(Object? value) =>
    hashes.sha256.convert(utf8.encode(canonicalNameTest(value))).toString();

void main() {
  for (final fromA in [true, false]) {
    test(
      'details exchange merges fields, preserves same-field alternatives, nested agreement and exact repeat from ${fromA ? 'A' : 'B'}',
      () async {
        final f = await JoinFixture.create(allowOwnerAdditions: true);
        await activateFixtureB(f);
        final pair = await openSyncPair(f);
        final ac = CompanyJobCommands(enrollment: f.aEnrollment),
            bc = CompanyJobCommands(enrollment: f.bEnrollment);
        try {
          expect((await pair.a.syncNow()).complete, isTrue);
          var av = (await ac.listJobViews(ownerSession: f.owner)).single;
          final originalA = digest(
            (await f.aDb.select(f.aDb.companyJobs).get()).single.toJson(),
          );
          final originalB = digest(
            (await f.bDb.select(f.bDb.companyJobs).get()).single.toJson(),
          );
          await ac.patchJobDetails(
            patch(
              av,
              f.owner,
              const JobDetailsPatch(
                customer: SetField('Acme'),
                status: SetField(CompanyJobStatus.archived),
              ),
              {JobDetailField.customer: [], JobDetailField.status: []},
            ),
            ownerSession: f.owner,
          );
          await bc.patchJobDetails(
            patch(
              av,
              pair.ownerB,
              const JobDetailsPatch(notes: SetField('Gate 3')),
              {JobDetailField.notes: []},
            ),
            ownerSession: pair.ownerB,
          );
          final run = await (fromA ? pair.a : pair.b).syncNow();
          expect(run.complete, isTrue);
          expect(run.sent, 1);
          expect(run.received, 1);
          av = (await ac.listJobViews(ownerSession: f.owner)).single;
          var bv = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
          for (final v in [av, bv]) {
            expect(v.details.customer.value, 'Acme');
            expect(v.details.status.value, CompanyJobStatus.archived);
            expect(v.details.notes.value, 'Gate 3');
          }
          final repeat = await (fromA ? pair.a : pair.b).syncNow();
          expect(repeat.complete, isTrue);
          expect(repeat.sent, 0);
          expect(repeat.received, 0);
          if (fromA) {
            final noteParents = av.details.notes.heads;
            await ac.patchJobDetails(
              patch(av, f.owner, const JobDetailsPatch(notes: SetField('A')), {
                JobDetailField.notes: noteParents,
              }),
              ownerSession: f.owner,
            );
            await bc.patchJobDetails(
              patch(
                bv,
                pair.ownerB,
                const JobDetailsPatch(notes: SetField('B')),
                {JobDetailField.notes: noteParents},
              ),
              ownerSession: pair.ownerB,
            );
            expect(
              (await (fromA ? pair.a : pair.b).syncNow()).complete,
              isTrue,
            );
            av = (await ac.listJobViews(ownerSession: f.owner)).single;
            bv = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
            expect(av.details.notes.candidates.map((c) => c.value).toSet(), {
              'A',
              'B',
            });
            expect(
              av.details.notes.candidates
                  .map((c) => c.originalDeviceId)
                  .toSet(),
              {f.owner.identity.deviceId, pair.ownerB.identity.deviceId},
            );
            expect(av.details.notes.heads, bv.details.notes.heads);
            expect(av.details.notes.lastAgreedValue, 'Gate 3');
            final bad = patch(
              av,
              f.owner,
              const JobDetailsPatch(notes: SetField('Silent resolution')),
              {JobDetailField.notes: av.details.notes.heads},
            );
            final signed = jsonDecode(
              (await f.aDb.select(f.aDb.companyJobDetails).get())
                  .first
                  .operationBytes,
            ) as Map<String, dynamic>;
            final body = signed['body'] as Map<String, dynamic>;
            body.addAll({
              'request': bad.requestId,
              'command': bad.commitment,
              'units': {
                'notes': {
                  'value': 'Silent resolution',
                  'parents': av.details.notes.heads,
                },
              },
              'resolve': <String>[],
            });
            final proof = signed['authorization'] as Map<String, dynamic>;
            (proof['body'] as Map<String, dynamic>).addAll({
              'request': bad.requestId,
              'command': bad.commitment,
            });
            final state = jsonDecode(
              utf8.decode(f.aStore.states[f.a.namespace]!.bytes),
            ) as Map;
            final key = await Ed25519().newKeyPairFromSeed(
              base64Decode(state['seed'] as String),
            );
            proof['signature'] = base64Encode(
              (await Ed25519().sign(
                utf8.encode(
                  'wiredpart.job.details.authorization@1:${canonicalNameTest(proof['body'])}',
                ),
                keyPair: key,
              )).bytes,
            );
            signed['signature'] = base64Encode(
              (await Ed25519().sign(
                utf8.encode(
                  'wiredpart.job.details.operation@1:${canonicalNameTest(body)}',
                ),
                keyPair: key,
              )).bytes,
            );
            final unchanged = digest({
              'sql': await sqlSnapshot(f.bDb),
              'protected': base64Encode(f.bStore.states[f.b.namespace]!.bytes),
            });
            await expectLater(
              bc.applyIncomingDetails(
                Uint8List.fromList(utf8.encode(canonicalNameTest(signed))),
                ownerSession: pair.ownerB,
                availability: pair.b.availability,
              ),
              throwsA(
                isA<JobLineRefusal>().having(
                  (e) => e.reason,
                  'reason',
                  contains('explicit resolution'),
                ),
              ),
            );
            expect(
              digest({
                'sql': await sqlSnapshot(f.bDb),
                'protected': base64Encode(
                  f.bStore.states[f.b.namespace]!.bytes,
                ),
              }),
              unchanged,
            );
            final heads = av.details.notes.heads;
            await ac.patchJobDetails(
              patch(
                av,
                f.owner,
                const JobDetailsPatch(notes: SetField('C')),
                {JobDetailField.notes: heads},
                resolve: {JobDetailField.notes},
              ),
              ownerSession: f.owner,
            );
            await bc.patchJobDetails(
              patch(
                bv,
                pair.ownerB,
                const JobDetailsPatch(notes: SetField('D')),
                {JobDetailField.notes: heads},
                resolve: {JobDetailField.notes},
              ),
              ownerSession: pair.ownerB,
            );
            expect(
              (await (fromA ? pair.a : pair.b).syncNow()).complete,
              isTrue,
            );
            av = (await ac.listJobViews(ownerSession: f.owner)).single;
            bv = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
            expect(av.details.notes.candidates.map((c) => c.value).toSet(), {
              'C',
              'D',
            });
            expect(av.details.notes.lastAgreedValue, 'Gate 3');
            expect(bv.details.notes.lastAgreedValue, 'Gate 3');
            expect(
              digest(
                (await f.aDb.select(f.aDb.companyJobs).get()).single.toJson(),
              ),
              originalA,
            );
            expect(
              digest(
                (await f.bDb.select(f.bDb.companyJobs).get()).single.toJson(),
              ),
              originalB,
            );
            expect(
              (await f.aDb.select(f.aDb.companyJobDetails).get()).length,
              6,
            );
            expect(
              (await f.bDb.select(f.bDb.companyJobDetails).get()).length,
              6,
            );
            final acks = await f.aDb
                .select(f.aDb.companyJobDetailPeerAcks)
                .get();
            expect(acks.length, 6);
            expect(
              acks.every(
                (r) =>
                    jsonDecode(r.ackBytes)['body']['kind'] ==
                    'company.job.details.ack@1',
              ),
              isTrue,
            );
          } else {
            expect(
              (await f.aDb.select(f.aDb.companyJobDetails).get()).length,
              2,
            );
            final acks = await f.bDb
                .select(f.bDb.companyJobDetailPeerAcks)
                .get();
            expect(acks.length, 2);
            expect(
              acks.every(
                (r) =>
                    jsonDecode(r.ackBytes)['body']['kind'] ==
                    'company.job.details.ack@1',
              ),
              isTrue,
            );
            expect(
              digest(
                (await f.aDb.select(f.aDb.companyJobs).get()).single.toJson(),
              ),
              originalA,
            );
            expect(
              digest(
                (await f.bDb.select(f.bDb.companyJobs).get()).single.toJson(),
              ),
              originalB,
            );
          }
        } finally {
          await pair.a.closeAndDrain();
          await pair.b.closeAndDrain();
        }
        await f.reopenB();
        final owner = await f.bEnrollment.signIn('1234');
        final read = (await CompanyJobCommands(
          enrollment: f.bEnrollment,
        ).listJobViews(ownerSession: owner)).single;
        expect(read.details.notes.hasConflict, fromA);
        expect(read.details.notes.lastAgreedValue, 'Gate 3');
        expect(read.details.customer.value, 'Acme');
      },
    );
  }
}
