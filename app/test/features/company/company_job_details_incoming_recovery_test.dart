@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_join_test.dart' show JoinFixture, activateFixtureB, sqlSnapshot;
import 'company_created_job_sync_test.dart' show openSyncPair;
import 'company_job_details_sync_test.dart' show patch, digest;

void main() {
  for (final after in [false, true]) {
    test(
      'incoming details ${after ? 'lost reply' : 'rollback'} recovers with no false ACK and exact retry',
      () async {
        final f = await JoinFixture.create(allowOwnerAdditions: true);
        await activateFixtureB(f);
        final pair = await openSyncPair(f);
        late Uint8List bytes;
        String? receipt;
        try {
          final ac = CompanyJobCommands(enrollment: f.aEnrollment),
              bc = CompanyJobCommands(enrollment: f.bEnrollment);
          final creation = (await f.aDb.select(f.aDb.companyJobs).get()).single;
          await bc.applyIncomingCreate(
            Uint8List.fromList(utf8.encode(creation.operationBytes)),
            ownerSession: pair.ownerB,
            availability: pair.b.availability,
          );
          final view = (await ac.listJobViews(ownerSession: f.owner)).single;
          await ac.patchJobDetails(
            patch(
              view,
              f.owner,
              const JobDetailsPatch(notes: SetField('Incoming durable')),
              {JobDetailField.notes: []},
            ),
            ownerSession: f.owner,
          );
          bytes = Uint8List.fromList(
            utf8.encode(
              (await f.aDb.select(f.aDb.companyJobDetails).get())
                  .single
                  .operationBytes,
            ),
          );
          final fault = CompanyJobCommands(
            enrollment: f.bEnrollment,
            beforeCommit: after
                ? null
                : () async => throw StateError('before commit'),
            afterCommit: after
                ? () async => throw StateError('after commit')
                : null,
          );
          await expectLater(
            fault.applyIncomingDetails(
              bytes,
              ownerSession: pair.ownerB,
              availability: pair.b.availability,
            ),
            throwsA(isA<StateError>()),
          );
          final rows = await f.bDb.select(f.bDb.companyJobDetails).get();
          expect(rows.length, after ? 1 : 0);
          if (after) {
            receipt = rows.single.receiptBytes;
          }
          expect(
            (await f.bDb.select(f.bDb.companyJobDetailPeerAcks).get()).length,
            0,
          );
        } finally {
          await pair.a.closeAndDrain();
          await pair.b.closeAndDrain();
        }
        await f.reopenB();
        expect(f.b.readiness, InstallationReadiness.ready);
        final next = await openSyncPair(f);
        try {
          final bc = CompanyJobCommands(enrollment: f.bEnrollment);
          final result = await bc.applyIncomingDetails(
            bytes,
            ownerSession: next.ownerB,
            availability: next.b.availability,
          );
          if (after) {
            expect(result, receipt);
          }
          expect((await f.bDb.select(f.bDb.companyJobDetails).get()).length, 1);
          expect(
            (await f.bDb.select(f.bDb.companyJobDetailPeerAcks).get()).length,
            0,
          );
          expect(
            (await bc.listJobViews(ownerSession: next.ownerB))
                .single
                .details
                .notes
                .value,
            'Incoming durable',
          );
        } finally {
          await next.a.closeAndDrain();
          await next.b.closeAndDrain();
        }
      },
    );
  }
  test('signed details child rejects without parent then exact bytes retry after dependency', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    try {
      final ac = CompanyJobCommands(enrollment: f.aEnrollment),
          bc = CompanyJobCommands(enrollment: f.bEnrollment);
      final creation = (await f.aDb.select(f.aDb.companyJobs).get()).single;
      await bc.applyIncomingCreate(
        Uint8List.fromList(utf8.encode(creation.operationBytes)),
        ownerSession: pair.ownerB,
        availability: pair.b.availability,
      );
      final view = (await ac.listJobViews(ownerSession: f.owner)).single;
      final parent = await ac.patchJobDetails(
        patch(view, f.owner, const JobDetailsPatch(notes: SetField('Parent')), {
          JobDetailField.notes: [],
        }),
        ownerSession: f.owner,
      );
      final child = await ac.patchJobDetails(
        patch(view, f.owner, const JobDetailsPatch(notes: SetField('Child')), {
          JobDetailField.notes: [parent.operationId],
        }),
        ownerSession: f.owner,
      );
      final rows = await f.aDb.select(f.aDb.companyJobDetails).get();
      final childBytes = Uint8List.fromList(
        utf8.encode(
          rows
              .singleWhere((r) => r.operationCommitment == child.operationId)
              .operationBytes,
        ),
      );
      final parentBytes = Uint8List.fromList(
        utf8.encode(
          rows
              .singleWhere((r) => r.operationCommitment == parent.operationId)
              .operationBytes,
        ),
      );
      final unchanged = digest({
        'sql': await sqlSnapshot(f.bDb),
        'protected': base64Encode(f.bStore.states[f.b.namespace]!.bytes),
      });
      await expectLater(
        bc.applyIncomingDetails(
          childBytes,
          ownerSession: pair.ownerB,
          availability: pair.b.availability,
        ),
        throwsA(isA<JobDetailsDependencyRefusal>()),
      );
      expect(
        digest({
          'sql': await sqlSnapshot(f.bDb),
          'protected': base64Encode(f.bStore.states[f.b.namespace]!.bytes),
        }),
        unchanged,
      );
      await bc.applyIncomingDetails(
        parentBytes,
        ownerSession: pair.ownerB,
        availability: pair.b.availability,
      );
      final first = await bc.applyIncomingDetails(
        childBytes,
        ownerSession: pair.ownerB,
        availability: pair.b.availability,
      );
      final retry = await bc.applyIncomingDetails(
        childBytes,
        ownerSession: pair.ownerB,
        availability: pair.b.availability,
      );
      expect(digest(retry), digest(first));
      expect((await f.bDb.select(f.bDb.companyJobDetails).get()).length, 2);
      final current = (await bc.listJobViews(ownerSession: pair.ownerB))
          .single
          .details
          .notes;
      expect(current.value, 'Child');
      expect(current.heads, [child.operationId]);
      expect(
        (await f.bDb.select(f.bDb.companyJobDetailPeerAcks).get()).length,
        0,
      );
    } finally {
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
    }
  });
}
