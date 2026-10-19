import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_name_test.dart' show NameFixture, canonicalNameTest;
import 'company_job_lifecycle_test.dart' show lifecycle;
import 'company_join_test.dart' show sqlSnapshot;

String digest(Object? value) =>
    hashes.sha256.convert(utf8.encode(canonicalNameTest(value))).toString();

void main() {
  test('512 shared mutable budget counts lifecycle pressure and preserves real exact retry', () async {
    final f = await NameFixture.create();
    try {
      final view = (await f.commands.listJobViews(ownerSession: f.owner))
          .single;
      final command = lifecycle(f, view);
      final receipt = await f.commands.setJobLifecycle(
        command,
        ownerSession: f.owner,
      );
      final other = CreateJob(
        companyId: command.companyId,
        shopId: command.shopId,
        jobId: const Uuid().v4(),
        requestId: const Uuid().v4(),
        name: 'Unpressured Job',
      );
      await f.commands.createJob(other, ownerSession: f.owner);
      final otherBase = (await f.db.select(f.db.companyJobs).get()).singleWhere(
        (r) => r.jobId == other.jobId,
      );
      final creation = hashes.sha256
          .convert(utf8.encode(otherBase.operationBytes))
          .toString();
      // Count-pressure rows are deliberately not verified history and are never inventoried or applied.
      await f.db.transaction(() async {
        for (var i = 0; i < 511; i++) {
          await f.db
              .into(f.db.companyJobLifecycles)
              .insert(
                CompanyJobLifecycle(
                  companyId: command.companyId,
                  shopId: command.shopId,
                  jobId: const Uuid().v4(),
                  originGeneration: f.security.identity!.generation.value,
                  requestId: const Uuid().v4(),
                  operationCommitment: digest({'pressure': i}),
                  commandCommitment: 'a' * 64,
                  operationBytes: 'unverified count pressure',
                  receiptKey: digest({'pressureReceipt': i}),
                  receiptBytes: '{}',
                  auditBytes: '{}',
                  outgoing: true,
                ).toCompanion(false),
              );
        }
      });
      final before = await sqlSnapshot(f.db),
          protected = f.store.states[f.security.namespace]!.bytes.toList();
      final blocked = SetJobLifecycle(
        companyId: command.companyId,
        shopId: command.shopId,
        jobId: other.jobId,
        requestId: const Uuid().v4(),
        creationDigest: creation,
        observed: JobCausalContext([]),
        choice: JobLifecycleChoice.deleted,
      );
      await expectLater(
        f.commands.setJobLifecycle(blocked, ownerSession: f.owner),
        throwsA(
          isA<JobLineRefusal>().having(
            (e) => e.reason,
            'reason',
            contains('capacity'),
          ),
        ),
      );
      await expectLater(
        f.commands.renameJob(
          RenameJob(
            companyId: command.companyId,
            shopId: command.shopId,
            jobId: other.jobId,
            requestId: const Uuid().v4(),
            creationDigest: creation,
            observedHeads: [],
            observedLifecycleHeads: [],
            name: 'Denied v2',
          ),
          ownerSession: f.owner,
        ),
        throwsA(
          isA<JobLineRefusal>().having(
            (e) => e.reason,
            'reason',
            contains('capacity'),
          ),
        ),
      );
      expect(
        (await f.commands.setJobLifecycle(
          command,
          ownerSession: f.owner,
        )).bytes,
        receipt.bytes,
      );
      expect(await sqlSnapshot(f.db), before);
      expect(f.store.states[f.security.namespace]!.bytes, protected);
    } finally {
      await f.close();
    }
  });

  for (final retry in [false, true]) {
    test(
      '128 per-Job pressure ${retry ? 'preserves real lifecycle retry' : 'refuses v2 metadata before mutation'}',
      () async {
        final f = await NameFixture.create();
        try {
          final view = (await f.commands.listJobViews(ownerSession: f.owner))
              .single;
          final command = lifecycle(f, view);
          final receipt = retry
              ? await f.commands.setJobLifecycle(command, ownerSession: f.owner)
              : null;
          final create = jsonDecode(
            (await f.db.select(f.db.companyJobs).get()).single.operationBytes,
          ) as Map;
          final original = create['body'] as Map;
          await f.db.transaction(() async {
            for (var i = 0; i < (retry ? 127 : 128); i++) {
              final edit = RenameJob(
                companyId: command.companyId,
                shopId: command.shopId,
                jobId: command.jobId,
                requestId: const Uuid().v4(),
                creationDigest: command.creationDigest,
                observedHeads: [],
                name: 'Count pressure $i',
              );
              final body = {
                'v': 1,
                'contract': 'job.name.set@1',
                'company': edit.companyId,
                'shop': edit.shopId,
                'job': edit.jobId,
                'request': edit.requestId,
                'creation': edit.creationDigest,
                'parents': <String>[],
                'name': edit.name,
                'generation': original['generation'],
                'installation': original['installation'],
                'device': original['device'],
                'user': original['user'],
                'command': edit.commitment,
                'facts': original['facts'],
              };
              await f.db
                  .into(f.db.companyJobNames)
                  .insert(
                    CompanyJobName(
                      companyId: edit.companyId,
                      shopId: edit.shopId,
                      jobId: edit.jobId,
                      originGeneration: original['generation'] as String,
                      requestId: edit.requestId,
                      operationCommitment: digest(body),
                      commandCommitment: edit.commitment,
                      operationBytes: canonicalNameTest({
                        'body': body,
                        'authorization': <String, Object?>{},
                        'signature': 'unverified count pressure',
                      }),
                      receiptKey: digest({'pressure': i}),
                      receiptBytes: '{}',
                      auditBytes: '{}',
                      outgoing: true,
                    ).toCompanion(false),
                  );
            }
          });
          final before = await sqlSnapshot(f.db),
              protected = f.store.states[f.security.namespace]!.bytes.toList();
          if (retry) {
            expect(
              (await f.commands.setJobLifecycle(
                command,
                ownerSession: f.owner,
              )).bytes,
              receipt!.bytes,
            );
          } else {
            await expectLater(
              f.commands.renameJob(
                RenameJob(
                  companyId: command.companyId,
                  shopId: command.shopId,
                  jobId: command.jobId,
                  requestId: const Uuid().v4(),
                  creationDigest: command.creationDigest,
                  observedHeads: [],
                  observedLifecycleHeads: [],
                  name: 'Denied v2',
                ),
                ownerSession: f.owner,
              ),
              throwsA(
                isA<JobLineRefusal>().having(
                  (e) => e.reason,
                  'reason',
                  contains('capacity'),
                ),
              ),
            );
          }
          expect(await sqlSnapshot(f.db), before);
          expect(f.store.states[f.security.namespace]!.bytes, protected);
        } finally {
          await f.close();
        }
      },
    );
  }
}
