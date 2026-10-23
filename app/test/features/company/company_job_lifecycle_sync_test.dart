@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_join_test.dart' show JoinFixture, activateFixtureB;
import 'company_created_job_sync_test.dart' show openSyncPair;
import 'company_job_name_sync_test.dart' show safeNameFailure;

SetJobLifecycle deletion(
  CompanyJobView v,
  OwnerSession owner, {
  JobLifecycleChoice choice = JobLifecycleChoice.deleted,
  bool resolve = false,
}) => SetJobLifecycle(
  companyId: owner.identity.companyId,
  shopId: owner.identity.shopId,
  jobId: v.baseJob.id,
  requestId: const Uuid().v4(),
  creationDigest: v.creationDigest,
  observed: v.lifecycle.context,
  choice: choice,
  resolvingConflict: resolve,
);

void main() {
  for (final name in [false, true]) {
    for (final fromA in [false, true]) {
      test(
        '${name ? 'name' : 'details'} versus deletion converges from ${fromA ? 'deleter' : 'editor'}, keep and second deletion',
        () async {
          final f = await JoinFixture.create(allowOwnerAdditions: true);
          await activateFixtureB(f);
          final pair = await openSyncPair(f);
          final ac = CompanyJobCommands(enrollment: f.aEnrollment),
              bc = CompanyJobCommands(enrollment: f.bEnrollment);
          try {
            expect(
              (await pair.a.syncNow()).complete,
              isTrue,
              reason: safeNameFailure(pair),
            );
            final av = (await ac.listJobViews(ownerSession: f.owner)).single;
            final bv = (await bc.listJobViews(ownerSession: pair.ownerB))
                .single;
            final original = await f.aDb.select(f.aDb.companyJobs).get();
            await ac.setJobLifecycle(
              deletion(av, f.owner),
              ownerSession: f.owner,
            );
            if (name) {
              await bc.renameJob(
                RenameJob(
                  companyId: f.owner.identity.companyId,
                  shopId: f.owner.identity.shopId,
                  jobId: bv.baseJob.id,
                  requestId: const Uuid().v4(),
                  creationDigest: bv.creationDigest,
                  observedHeads: bv.nameHeads,
                  observedLifecycleHeads: bv.lifecycle.lifecycleHeads,
                  name: 'Offline name',
                ),
                ownerSession: pair.ownerB,
              );
            } else {
              await bc.patchJobDetails(
                PatchJobDetails(
                  companyId: f.owner.identity.companyId,
                  shopId: f.owner.identity.shopId,
                  jobId: bv.baseJob.id,
                  requestId: const Uuid().v4(),
                  creationDigest: bv.creationDigest,
                  observedHeads: {
                    JobDetailField.notes: [],
                    JobDetailField.status: [],
                  },
                  observedLifecycleHeads: bv.lifecycle.lifecycleHeads,
                  patch: const JobDetailsPatch(
                    notes: SetField('Offline notes'),
                    status: SetField(CompanyJobStatus.archived),
                  ),
                ),
                ownerSession: pair.ownerB,
              );
            }
            final run = await (fromA ? pair.a : pair.b).syncNow();
            expect(run.complete, isTrue, reason: safeNameFailure(pair));
            for (final v in [
              (await ac.listJobViews(ownerSession: f.owner)).single,
              (await bc.listJobViews(ownerSession: pair.ownerB)).single,
            ]) {
              expect(
                v.lifecycle.state,
                CompanyJobLifecycleState.deleteConflict,
              );
              expect(
                v.lifecycle.alternatives.map((a) => a.originalDeviceId).toSet(),
                {f.owner.identity.deviceId, pair.ownerB.identity.deviceId},
              );
            }
            var current = (await ac.listJobViews(ownerSession: f.owner)).single;
            final keep = deletion(
              current,
              f.owner,
              choice: JobLifecycleChoice.kept,
              resolve: true,
            );
            await ac.setJobLifecycle(keep, ownerSession: f.owner);
            expect(
              (await pair.a.syncNow()).complete,
              isTrue,
              reason: safeNameFailure(pair),
            );
            current = (await ac.listJobViews(ownerSession: f.owner)).single;
            expect(current.lifecycle.state, CompanyJobLifecycleState.live);
            if (!name) {
              expect(current.details.status.value, CompanyJobStatus.archived);
            }
            await ac.setJobLifecycle(
              deletion(current, f.owner),
              ownerSession: f.owner,
            );
            expect(
              (await pair.a.syncNow()).complete,
              isTrue,
              reason: safeNameFailure(pair),
            );
            final repeat = await pair.a.syncNow();
            expect(repeat.complete, isTrue, reason: safeNameFailure(pair));
            expect(repeat.sent, 0);
            expect(repeat.received, 0);
            expect(
              (await bc.listJobViews(ownerSession: pair.ownerB))
                  .single
                  .lifecycle
                  .state,
              CompanyJobLifecycleState.deleted,
            );
            expect(await f.aDb.select(f.aDb.companyJobs).get(), original);
          } finally {
            await pair.a.closeAndDrain();
            await pair.b.closeAndDrain();
          }
        },
      );
    }
  }
  test('delayed v1 edit conflicts, keep retains unseen field edit and exact history', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    final ac = CompanyJobCommands(enrollment: f.aEnrollment),
        bc = CompanyJobCommands(enrollment: f.bEnrollment);
    try {
      expect((await pair.a.syncNow()).complete, isTrue);
      final a = (await ac.listJobViews(ownerSession: f.owner)).single;
      final b = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
      await ac.setJobLifecycle(deletion(a, f.owner), ownerSession: f.owner);
      for (final value in ['Old A', 'Old B']) {
        await bc.renameJob(
          RenameJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: b.baseJob.id,
            requestId: const Uuid().v4(),
            creationDigest: b.creationDigest,
            observedHeads: [],
            name: value,
          ),
          ownerSession: pair.ownerB,
        );
      }
      final rows = await f.bDb.select(f.bDb.companyJobNames).get();
      Future<void> apply(int i) async {
        await ac.applyIncomingName(
          Uint8List.fromList(utf8.encode(rows[i].operationBytes)),
          ownerSession: f.owner,
          availability: pair.a.availability,
        );
      }

      await apply(0);
      final conflict = (await ac.listJobViews(ownerSession: f.owner)).single;
      expect(conflict.lifecycle.state, CompanyJobLifecycleState.deleteConflict);
      final keep = deletion(
        conflict,
        f.owner,
        choice: JobLifecycleChoice.kept,
        resolve: true,
      );
      await ac.setJobLifecycle(keep, ownerSession: f.owner);
      await apply(1);
      final kept = (await ac.listJobViews(ownerSession: f.owner)).single;
      expect(kept.lifecycle.state, CompanyJobLifecycleState.live);
      expect(kept.hasConflict, isTrue);
      expect(kept.candidates.map((c) => c.name).toSet(), {'Old A', 'Old B'});
      expect(
        (await ac.setJobLifecycle(keep, ownerSession: f.owner)).operationId,
        isNotEmpty,
      );
      expect(
        (await f.bDb.select(f.bDb.companyJobNames).get()).map(
          (r) => r.operationBytes,
        ),
        rows.map((r) => r.operationBytes),
      );
    } finally {
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
    }
  });
}
