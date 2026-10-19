import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_name_test.dart' show NameFixture;
import 'company_join_test.dart' show sqlSnapshot;

void main() {
  test('production offline deletion survives reopen and exact retry without changing creation', () async {
    final f = await NameFixture.create();
    try {
      final before = await f.db.select(f.db.companyJobs).get();
      final jobs = await f.db.select(f.db.jobs).get();
      final view = (await f.commands.listJobViews(ownerSession: f.owner))
          .single;
      final command = SetJobLifecycle(
        companyId: f.owner.identity.companyId,
        shopId: f.owner.identity.shopId,
        jobId: f.createCommand.jobId,
        requestId: const Uuid().v4(),
        creationDigest: f.creationDigest,
        observed: view.lifecycle.context,
        choice: JobLifecycleChoice.deleted,
      );
      final receipt = await f.commands.setJobLifecycle(
        command,
        ownerSession: f.owner,
      );
      expect(
        (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .lifecycle
            .state,
        CompanyJobLifecycleState.deleted,
      );
      await f.reopen();
      expect(
        (await f.commands.setJobLifecycle(
          command,
          ownerSession: f.owner,
        )).bytes,
        receipt.bytes,
      );
      expect(
        (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .lifecycle
            .state,
        CompanyJobLifecycleState.deleted,
      );
      expect(await f.db.select(f.db.companyJobs).get(), before);
      expect(await f.db.select(f.db.jobs).get(), jobs);
      await expectLater(
        f.commands.renameJob(f.rename('Cannot revive'), ownerSession: f.owner),
        throwsA(isA<JobLineRefusal>()),
      );
    } finally {
      await f.close();
    }
  });

  test('observed edits stay deleted; stale deletion and changed-content retry refuse', () async {
    final f = await NameFixture.create();
    try {
      final empty = (await f.commands.listJobViews(ownerSession: f.owner))
          .single;
      final stale = lifecycle(f, empty);
      await f.commands.renameJob(
        f.rename('Observed edit'),
        ownerSession: f.owner,
      );
      final before = await sqlSnapshot(f.db);
      await expectLater(
        f.commands.setJobLifecycle(stale, ownerSession: f.owner),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await sqlSnapshot(f.db), before);
      final view = (await f.commands.listJobViews(ownerSession: f.owner))
          .single;
      final command = lifecycle(f, view);
      await f.commands.setJobLifecycle(command, ownerSession: f.owner);
      expect(
        (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .lifecycle
            .state,
        CompanyJobLifecycleState.deleted,
      );
      await expectLater(
        f.commands.setJobLifecycle(
          lifecycle(f, view, request: command.requestId, resolve: true),
          ownerSession: f.owner,
        ),
        throwsA(anything),
      );
      expect(await f.db.select(f.db.companyJobLifecycles).get(), hasLength(1));
    } finally {
      await f.close();
    }
  });

  test(
    'local rollback and lost completion reconcile typed lifecycle intent',
    () async {
      final f = await NameFixture.create();
      try {
        final view = (await f.commands.listJobViews(ownerSession: f.owner))
            .single;
        final command = lifecycle(f, view);
        final before = await sqlSnapshot(f.db);
        await expectLater(
          CompanyJobCommands(
            enrollment: f.enrollment,
            beforeCommit: () async => throw StateError('rollback'),
          ).setJobLifecycle(command, ownerSession: f.owner),
          throwsStateError,
        );
        expect(await sqlSnapshot(f.db), before);
        await expectLater(
          CompanyJobCommands(
            enrollment: f.enrollment,
            afterCommit: () async => throw StateError('lost completion'),
          ).setJobLifecycle(command, ownerSession: f.owner),
          throwsStateError,
        );
        final saved =
            (await f.db.select(f.db.companyJobLifecycles).get()).single;
        expect(
          await f.db.select(f.db.companyJobLifecyclePeerAcks).get(),
          isEmpty,
        );
        await f.reopen();
        expect(f.security.readiness, InstallationReadiness.ready);
        expect(
          (await f.commands.setJobLifecycle(
            command,
            ownerSession: f.owner,
          )).bytes,
          saved.receiptBytes,
        );
        expect(
          await f.db.select(f.db.companyJobLifecycles).get(),
          hasLength(1),
        );
      } finally {
        await f.close();
      }
    },
  );

  test('child history and final-commit child injection refuse without discarding evidence', () async {
    final f = await NameFixture.create();
    try {
      final view = (await f.commands.listJobViews(ownerSession: f.owner))
          .single;
      final command = lifecycle(f, view);
      Future<void> child() => f.db.customStatement(
        "INSERT INTO job_line_audits VALUES ('synthetic-child', '{}')",
      );
      await child();
      final before = await sqlSnapshot(f.db);
      await expectLater(
        f.commands.setJobLifecycle(command, ownerSession: f.owner),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await sqlSnapshot(f.db), before);
      expect(
        (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .displayName,
        'Baseline',
      );
      await f.db.customStatement('DELETE FROM job_line_audits');
      final clean = await sqlSnapshot(f.db);
      await expectLater(
        CompanyJobCommands(
          enrollment: f.enrollment,
          beforeCommit: child,
        ).setJobLifecycle(command, ownerSession: f.owner),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await sqlSnapshot(f.db), clean);
    } finally {
      await f.close();
    }
  });

  test('causal contexts reject duplicates, unknown tags and combined dependencies above 32', () {
    expect(
      () => JobCausalContext.fromTagged(['x/${'a' * 64}']),
      throwsA(isA<JobLineRefusal>()),
    );
    expect(
      () => JobCausalContext.fromTagged(['l/${'a' * 64}', 'l/${'a' * 64}']),
      throwsA(isA<JobLineRefusal>()),
    );
    expect(
      () => JobCausalContext.fromTagged(
        List.generate(33, (i) => 'l/${i.toRadixString(16).padLeft(64, '0')}'),
      ),
      throwsA(isA<JobLineRefusal>()),
    );
    const id = '00000000-0000-4000-8000-000000000001';
    expect(
      () => RenameJob(
        companyId: id,
        shopId: id,
        jobId: id,
        requestId: id,
        creationDigest: 'a' * 64,
        name: 'Bounded',
        observedHeads: List.generate(
          32,
          (i) => i.toRadixString(16).padLeft(64, '0'),
        ),
        observedLifecycleHeads: ['b' * 64],
      ),
      throwsA(isA<JobLineRefusal>()),
    );
  });
}

SetJobLifecycle lifecycle(
  NameFixture f,
  CompanyJobView view, {
  String? request,
  bool resolve = false,
  JobLifecycleChoice choice = JobLifecycleChoice.deleted,
}) => SetJobLifecycle(
  companyId: f.owner.identity.companyId,
  shopId: f.owner.identity.shopId,
  jobId: view.baseJob.id,
  requestId: request ?? const Uuid().v4(),
  creationDigest: view.creationDigest,
  observed: view.lifecycle.context,
  choice: choice,
  resolvingConflict: resolve,
);
