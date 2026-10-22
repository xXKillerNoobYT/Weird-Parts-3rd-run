@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_join_test.dart' show JoinFixture, activateFixtureB, sqlSnapshot;
import 'company_created_job_sync_test.dart' show openSyncPair, syncAttackWire;
import 'company_job_lifecycle_sync_test.dart' show deletion;
import 'company_job_name_test.dart' show canonicalNameTest;

void main() {
  test('missing cross-family dependency and descendants stay unacknowledged while unrelated Job applies', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    try {
      final ac = CompanyJobCommands(enrollment: f.aEnrollment);
      await ac.createJob(
        CreateJob(
          companyId: f.owner.identity.companyId,
          shopId: f.owner.identity.shopId,
          jobId: const Uuid().v4(),
          requestId: const Uuid().v4(),
          name: 'Unrelated eligible Job',
        ),
        ownerSession: f.owner,
      );
      final creations = await f.aDb.select(f.aDb.companyJobs).get();
      final blockedBase = creations.first;
      CompanyJobLifecycle held(String digest, List<String> parents) =>
          CompanyJobLifecycle(
            companyId: blockedBase.companyId,
            shopId: blockedBase.shopId,
            jobId: blockedBase.jobId,
            originGeneration: blockedBase.originGeneration,
            requestId: const Uuid().v4(),
            operationCommitment: digest,
            commandCommitment: 'c' * 64,
            operationBytes: canonicalNameTest({
              'body': {
                'contract': 'job.lifecycle.set@1',
                'creation': CreatedJobHoldingsInventory.local([blockedBase])
                    .descriptors
                    .single['digest'],
                'parents': parents,
                'device': f.owner.identity.deviceId,
                'installation': f.a.identity!.id.value,
              },
            }),
            receiptKey: 'a' * 64,
            receiptBytes: '{}',
            auditBytes: '{}',
            outgoing: true,
          );
      final inventory = CreatedJobHoldingsInventory.local([
        ...creations,
        held('d' * 64, ['n/${'e' * 64}']),
        held('f' * 64, ['l/${'d' * 64}']),
      ]);
      final run = const Uuid().v4();
      Future<Map<String, Object?>> send(
        String action,
        Map<String, Object?> data,
      ) async => pair.b.receive(
        await syncAttackWire(
          pair.a.controller.pairedJoinSession!,
          base64Encode(f.b.identity!.publicKey),
          run,
          action,
          data,
        ),
      );
      await send('start', {
        'inventory': inventory.meta,
        'store': f.a.receivingStoreGeneration!.value,
      });
      await send('holdings', {
        'ordinal': 0,
        'digest': inventory.digest,
        'items': inventory.page(0),
        'confirmedStores': List.filled(4, null),
      });
      final unrelated = creations.last;
      final d = inventory.descriptors.singleWhere(
        (d) => d['kind'] == null && d['job'] == unrelated.jobId,
      );
      final reply = await send('put', {
        'descriptor': d,
        'offset': 0,
        'bytes': base64Encode(utf8.encode(unrelated.operationBytes)),
      });
      expect(reply['ciphertext'], isA<String>());
      expect(
        (await f.bDb.select(f.bDb.companyJobs).get()).single.jobId,
        unrelated.jobId,
      );
      expect(await f.bDb.select(f.bDb.companyJobLifecycles).get(), isEmpty);
      expect(
        await f.bDb.select(f.bDb.companyJobLifecyclePeerAcks).get(),
        isEmpty,
      );
      await send('finish', {'complete': false, 'unsupported': 0});
    } finally {
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
    }
  });
  for (final after in [false, true]) {
    test(
      'incoming lifecycle ${after ? 'lost completion' : 'rollback'} has no false ACK and exact retry after reopen',
      () async {
        final f = await JoinFixture.create(allowOwnerAdditions: true);
        await activateFixtureB(f);
        final pair = await openSyncPair(f);
        late Uint8List bytes;
        String? originalReceipt;
        try {
          expect((await pair.a.syncNow()).complete, isTrue);
          final ac = CompanyJobCommands(enrollment: f.aEnrollment);
          final view = (await ac.listJobViews(ownerSession: f.owner)).single;
          await ac.setJobLifecycle(
            deletion(view, f.owner),
            ownerSession: f.owner,
          );
          bytes = Uint8List.fromList(
            utf8.encode(
              (await f.aDb.select(f.aDb.companyJobLifecycles).get())
                  .single
                  .operationBytes,
            ),
          );
          final before = await sqlSnapshot(f.bDb);
          await expectLater(
            CompanyJobCommands(
              enrollment: f.bEnrollment,
              beforeCommit: after
                  ? null
                  : () async => throw StateError('before commit'),
              afterCommit: after
                  ? () async => throw StateError('lost completion')
                  : null,
            ).applyIncomingLifecycle(
              bytes,
              ownerSession: pair.ownerB,
              availability: pair.b.availability,
            ),
            throwsStateError,
          );
          final rows = await f.bDb.select(f.bDb.companyJobLifecycles).get();
          expect(rows, hasLength(after ? 1 : 0));
          if (after) {
            originalReceipt = rows.single.receiptBytes;
          } else {
            expect(await sqlSnapshot(f.bDb), before);
          }
          expect(
            await f.bDb.select(f.bDb.companyJobLifecyclePeerAcks).get(),
            isEmpty,
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
          final receipt = await bc.applyIncomingLifecycle(
            bytes,
            ownerSession: next.ownerB,
            availability: next.b.availability,
          );
          if (after) expect(receipt, originalReceipt);
          expect(
            await f.bDb.select(f.bDb.companyJobLifecycles).get(),
            hasLength(1),
          );
          expect(
            await f.bDb.select(f.bDb.companyJobLifecyclePeerAcks).get(),
            isEmpty,
          );
          expect(
            (await bc.listJobViews(ownerSession: next.ownerB))
                .single
                .lifecycle
                .state,
            CompanyJobLifecycleState.deleted,
          );
          final before = await sqlSnapshot(f.bDb);
          for (final mutation in ['version', 'signature', 'foreign']) {
            final op = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
            if (mutation == 'version') {
              (op['body'] as Map)['v'] = 2;
            }
            if (mutation == 'signature') {
              op['signature'] = base64Encode(List.filled(64, 0));
            }
            if (mutation == 'foreign') {
              (op['body'] as Map)['job'] =
                  '00000000-0000-4000-8000-000000000001';
            }
            await expectLater(
              bc.applyIncomingLifecycle(
                Uint8List.fromList(utf8.encode(canonicalNameTest(op))),
                ownerSession: next.ownerB,
                availability: next.b.availability,
              ),
              throwsA(anything),
            );
            expect(await sqlSnapshot(f.bDb), before);
          }
        } finally {
          await next.a.closeAndDrain();
          await next.b.closeAndDrain();
        }
      },
    );
  }
}
