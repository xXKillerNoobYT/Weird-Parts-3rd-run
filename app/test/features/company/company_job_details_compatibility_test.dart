@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_join_test.dart' show JoinFixture, activateFixtureB, sqlSnapshot;
import 'company_created_job_sync_test.dart' show openSyncPair, syncAttackWire;
import 'company_job_details_sync_test.dart' show patch, digest;
import 'company_job_name_test.dart' show canonicalNameTest;

void main() {
  test('legacy signed create/name member grant keeps rights and denies details incoming', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    try {
      final bc = CompanyJobCommands(enrollment: f.bEnrollment),
          ac = CompanyJobCommands(enrollment: f.aEnrollment);
      final creation = (await f.aDb.select(f.aDb.companyJobs).get()).single;
      await bc.applyIncomingCreate(
        Uint8List.fromList(utf8.encode(creation.operationBytes)),
        ownerSession: pair.ownerB,
        availability: pair.b.availability,
      );
      final view = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
      final command = patch(
        view,
        pair.ownerB,
        const JobDetailsPatch(notes: SetField('Authorized details')),
        {JobDetailField.notes: []},
      );
      await bc.patchJobDetails(command, ownerSession: pair.ownerB);
      final op = jsonDecode(
        (await f.bDb.select(f.bDb.companyJobDetails).get())
            .single
            .operationBytes,
      ) as Map<String, dynamic>;
      final proof = op['authorization'] as Map<String, dynamic>;
      final certificate =
          jsonDecode(proof['membership'] as String) as Map<String, dynamic>;
      ((certificate['body'] as Map)['recipient'] as Map)['capabilities'] = [
        'createJob',
        'renameJob',
      ];
      final aState =
          jsonDecode(utf8.decode(f.aStore.states[f.a.namespace]!.bytes)) as Map;
      final aKey = await Ed25519().newKeyPairFromSeed(
        base64Decode(aState['seed'] as String),
      );
      certificate['signature'] = base64Encode(
        (await Ed25519().sign(
          utf8.encode(
            'wiredpart.company.device.enroll@1:${canonicalNameTest(certificate['body'])}',
          ),
          keyPair: aKey,
        )).bytes,
      );
      proof['membership'] = canonicalNameTest(certificate);
      (proof['body'] as Map)['membership'] = digest(certificate);
      final bState =
          jsonDecode(utf8.decode(f.bStore.states[f.b.namespace]!.bytes)) as Map;
      final bKey = await Ed25519().newKeyPairFromSeed(
        base64Decode(bState['seed'] as String),
      );
      Future<String> signProof(
        String domain,
        Map<String, dynamic> value,
      ) async => base64Encode(
        (await Ed25519().sign(
          utf8.encode('$domain${canonicalNameTest(value['body'])}'),
          keyPair: bKey,
        )).bytes,
      );
      proof['signature'] = await signProof(
        'wiredpart.job.details.authorization@2:',
        proof,
      );
      final member = await resolveCompanyMembership(
        db: f.bDb,
        installation: f.b,
        certificateBytes: canonicalNameTest(certificate),
      );
      expect(member.device['capabilities'], ['createJob', 'renameJob']);
      final create = CreateJob(
        companyId: command.companyId,
        shopId: command.shopId,
        jobId: const Uuid().v4(),
        requestId: const Uuid().v4(),
        name: 'Legacy creation',
      );
      final createProof = jsonDecode(jsonEncode(proof)) as Map<String, dynamic>;
      (createProof['body'] as Map<String, dynamic>).addAll(<String, dynamic>{
        'job': create.jobId,
        'request': create.requestId,
        'command': create.commitment,
      });
      createProof['signature'] = await signProof(
        'wiredpart.job.create.authorization@2:',
        createProof,
      );
      (await CreateJobAuthorization(db: f.bDb, installation: f.b).verify(
        create,
        Uint8List.fromList(utf8.encode(canonicalNameTest(createProof))),
      )).validateLiveOwner(pair.ownerB);
      final name = RenameJob(
        companyId: command.companyId,
        shopId: command.shopId,
        jobId: command.jobId,
        requestId: const Uuid().v4(),
        creationDigest: command.creationDigest,
        observedHeads: [],
        name: 'Legacy rename',
      );
      final nameProof = jsonDecode(jsonEncode(proof)) as Map<String, dynamic>;
      (nameProof['body'] as Map<String, dynamic>).addAll(<String, dynamic>{
        'job': name.jobId,
        'request': name.requestId,
        'command': name.commitment,
      });
      nameProof['signature'] = await signProof(
        'wiredpart.job.name.authorization@2:',
        nameProof,
      );
      (await RenameJobAuthorization(db: f.bDb, installation: f.b).verify(
        name,
        Uint8List.fromList(utf8.encode(canonicalNameTest(nameProof))),
      )).validateLiveOwner(pair.ownerB);
      final unchanged = digest({
        'sql': await sqlSnapshot(f.aDb),
        'protected': base64Encode(f.aStore.states[f.a.namespace]!.bytes),
      });
      await expectLater(
        ac.applyIncomingDetails(
          Uint8List.fromList(utf8.encode(canonicalNameTest(op))),
          ownerSession: f.owner,
          availability: pair.a.availability,
        ),
        throwsA(
          isA<JobLineRefusal>().having(
            (e) => e.reason,
            'reason',
            contains('explicit capability'),
          ),
        ),
      );
      expect(
        digest({
          'sql': await sqlSnapshot(f.aDb),
          'protected': base64Encode(f.aStore.states[f.a.namespace]!.bytes),
        }),
        unchanged,
      );
      expect((await ac.listJobViews(ownerSession: f.owner)).length, 1);
    } finally {
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
    }
  });
  test('sync protocol2 refuses before durable effects', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    try {
      final before = digest(await sqlSnapshot(f.bDb));
      final wire = await syncAttackWire(
        pair.a.controller.pairedJoinSession!,
        base64Encode(f.b.identity!.publicKey),
        const Uuid().v4(),
        'start',
        {},
        'company.job.sync@2',
      );
      await expectLater(
        pair.b.receive(wire),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      expect(digest(await sqlSnapshot(f.bDb)), before);
    } finally {
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
    }
  });
}
