import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

import 'company_job_name_test.dart' show NameFixture;
import 'company_jobs_widget_test.dart' show waitForWidget;
import 'company_job_test_support.dart' show JobTestStore;
import 'company_join_test.dart' show JoinFixture, activateFixtureB, sqlSnapshot;
import 'company_join_widget_test.dart' show JoinLoopbackHttpOverrides;
import 'company_created_job_sync_test.dart' show openSyncPair;
import 'company_job_lifecycle_sync_test.dart' show deletion;

void main() {
  late ({
    JoinFixture fixture,
    CompanyJobCommands commands,
    String job,
    String peer,
  })
  conflictData;
  setUpAll(
    () => HttpOverrides.runWithHttpOverrides(() async {
      final f = await JoinFixture.create(allowOwnerAdditions: true);
      await activateFixtureB(f);
      final pair = await openSyncPair(f);
      final ac = CompanyJobCommands(enrollment: f.aEnrollment),
          bc = CompanyJobCommands(enrollment: f.bEnrollment);
      try {
        expect((await pair.a.syncNow()).complete, isTrue);
        final view = (await ac.listJobViews(ownerSession: f.owner)).single;
        await ac.setJobLifecycle(
          deletion(view, f.owner),
          ownerSession: f.owner,
        );
        await bc.renameJob(
          RenameJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: view.baseJob.id,
            requestId: const Uuid().v4(),
            creationDigest: view.creationDigest,
            observedHeads: [],
            name: 'Concurrent UI edit',
          ),
          ownerSession: pair.ownerB,
        );
        final op = (await f.bDb.select(f.bDb.companyJobNames).get()).single;
        await ac.applyIncomingName(
          Uint8List.fromList(utf8.encode(op.operationBytes)),
          ownerSession: f.owner,
          availability: pair.a.availability,
        );
        conflictData = (
          fixture: f,
          commands: ac,
          job: view.baseJob.id,
          peer: pair.ownerB.identity.deviceId,
        );
      } finally {
        await pair.a.closeAndDrain();
        await pair.b.closeAndDrain();
      }
    }, JoinLoopbackHttpOverrides()),
  );
  testWidgets(
    'attributed deletion conflict offers both choices and explicit Delete Job resolves it',
    (tester) async {
      final data = conflictData;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(
                commands: data.commands,
                owner: data.fixture.owner,
              ),
            ),
          ),
        ),
      );
      final conflict = find.byKey(
        Key('company-job-delete-conflict-${data.job}'),
      );
      await waitForWidget(tester, conflict);
      expect(find.text('Keep edited Job'), findsOneWidget);
      expect(find.textContaining(data.peer), findsWidgets);
      final delete = find.byKey(Key('company-job-delete-${data.job}'));
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Delete Job'));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, find.text('Deleted Job history'));
      expect(
        (await tester.runAsync(
          () => data.commands.listJobViews(ownerSession: data.fixture.owner),
        ))!.single.lifecycle.state,
        CompanyJobLifecycleState.deleted,
      );
    },
  );
  testWidgets(
    'recovered profile creates readable Job without offering unavailable deletion',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      final db = AppDatabase.forTesting(
        NativeDatabase(File('${f.root.path}/widget-recovered.sqlite')),
      );
      addTearDown(() async {
        await db.close();
        await f.close();
      });
      final owner = (await tester.runAsync(() async {
        final security = InstallationSecurity(
          store: JobTestStore(),
          namespace: 'synthetic.lifecycle-widget-recovered',
        );
        await security.start(db);
        final enrollment = CompanyEnrollment(db: db, installation: security);
        await enrollment.recover(
          policy: CompanyContinuityPolicy.localContinuity,
          sourceFile: File('${f.root.path}/authority.wpca'),
          sourcePassphrase: 'synthetic names authority',
          newPin: '1234',
          newRecoveryPassphrase: 'recovered widget lifecycle authority',
          newRecoveryFile: File('${f.root.path}/widget-recovered.wpca'),
        );
        return (enrollment: enrollment, owner: await enrollment.signIn('1234'));
      }))!;
      final commands = CompanyJobCommands(enrollment: owner.enrollment);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(commands: commands, owner: owner.owner),
            ),
          ),
        ),
      );
      final create = find.byKey(const Key('company-create-job'));
      await waitForWidget(tester, create);
      await tester.enterText(
        find.byKey(const Key('company-job-name')),
        'Recovered UI Job',
      );
      await tester.runAsync(() async {
        await tester.tap(create);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, find.text('Recovered UI Job'));
      expect(find.widgetWithText(TextButton, 'Delete Job'), findsNothing);
      expect(find.textContaining('Only fresh genesis'), findsOneWidget);
      expect(
        await tester.runAsync(() => db.select(db.companyJobLifecycles).get()),
        isEmpty,
      );
    },
  );
  testWidgets(
    'stale delete confirmation releases its request and permits a fresh choice',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(commands: f.commands, owner: f.owner),
            ),
          ),
        ),
      );
      final delete = find.byKey(
        Key('company-job-delete-${f.createCommand.jobId}'),
      );
      await waitForWidget(tester, delete);
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete Job?'), findsOneWidget);
      final renamed = await tester.runAsync(() async {
        await f.commands.renameJob(
          f.rename('Changed during confirmation'),
          ownerSession: f.owner,
        );
        return (
          sql: await sqlSnapshot(f.db),
          protected: f.store.states[f.security.namespace]!,
          view: (await f.commands.listJobViews(ownerSession: f.owner)).single,
        );
      });
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Delete Job'));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, find.text('Changed during confirmation'));
      expect(await tester.runAsync(() => sqlSnapshot(f.db)), renamed!.sql);
      expect(
        f.store.states[f.security.namespace]!.revision,
        renamed.protected.revision,
      );
      expect(
        f.store.states[f.security.namespace]!.bytes,
        renamed.protected.bytes,
      );
      expect(
        find.byKey(const Key('company-job-retry-lifecycle')),
        findsNothing,
      );
      expect(
        find.text(
          'Displayed Job context changed. Review it before deleting or resolving.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<TextButton>(delete).onPressed, isNotNull);
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Delete Job'));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, find.text('Deleted Job history'));
      final saved = (await tester.runAsync(
        () => f.db.select(f.db.companyJobLifecycles).get(),
      ))!.single;
      final command = SetJobLifecycle.fromOperationBytes(
        Uint8List.fromList(utf8.encode(saved.operationBytes)),
      );
      expect(command.observed.tagged, renamed.view.lifecycle.context.tagged);
      expect(
        await tester.runAsync(
          () => f.db.select(f.db.companyJobLifecyclePeerAcks).get(),
        ),
        isEmpty,
      );
    },
  );
  testWidgets(
    'stale name save after deleting the edited Job keeps raw input cancelable without writes',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      final otherJobId = const Uuid().v4();
      await tester.runAsync(
        () => f.commands.createJob(
          CreateJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: otherJobId,
            requestId: const Uuid().v4(),
            name: 'Other live Job',
          ),
          ownerSession: f.owner,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(commands: f.commands, owner: f.owner),
            ),
          ),
        ),
      );
      final edit = find.byKey(Key('company-job-edit-${f.createCommand.jobId}'));
      await waitForWidget(tester, edit);
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pump();
      final nameField = find.byKey(const Key('company-job-edit-name'));
      const rawName = '  Unsaved name before deletion · exact  ';
      await tester.enterText(nameField, rawName);
      final delete = find.byKey(
        Key('company-job-delete-${f.createCommand.jobId}'),
      );
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete Job?'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Delete Job'));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, find.text('Deleted Job history'));
      final deleted = (await tester.runAsync(() async {
        final view = (await f.commands.listJobViews(ownerSession: f.owner))
            .singleWhere((view) => view.baseJob.id == f.createCommand.jobId);
        final protected = f.store.states[f.security.namespace]!;
        return (
          view: view,
          sql: await sqlSnapshot(f.db),
          protectedRevision: protected.revision,
          protectedBytes: Uint8List.fromList(protected.bytes),
          nameOperations: await f.db.select(f.db.companyJobNames).get(),
          operations: await f.db.select(f.db.jobLineOperations).get(),
          audits: await f.db.select(f.db.jobLineAudits).get(),
        );
      }))!;
      expect(deleted.view.lifecycle.state, CompanyJobLifecycleState.deleted);
      expect(tester.widget<TextField>(nameField).controller!.text, rawName);

      final save = find.byKey(const Key('company-job-save-name'));
      await tester.ensureVisible(save);
      await tester.runAsync(() async {
        await tester.tap(save);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, find.byKey(const Key('company-job-error')));
      expect(await tester.runAsync(() => sqlSnapshot(f.db)), deleted.sql);
      expect(
        f.store.states[f.security.namespace]!.revision,
        deleted.protectedRevision,
      );
      expect(
        f.store.states[f.security.namespace]!.bytes,
        deleted.protectedBytes,
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobNames).get()),
        deleted.nameOperations,
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.jobLineOperations).get()),
        deleted.operations,
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.jobLineAudits).get()),
        deleted.audits,
      );
      expect(tester.widget<TextField>(nameField).controller!.text, rawName);
      final cancel = find.widgetWithText(TextButton, 'Cancel name edit');
      expect(cancel, findsOneWidget);
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      expect(tester.widget<TextField>(nameField).enabled, isTrue);
      expect(find.byKey(const Key('company-job-retry-name')), findsNothing);
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pump();
      expect(nameField, findsNothing);
      final otherEdit = find.byKey(Key('company-job-edit-$otherJobId'));
      expect(tester.widget<TextButton>(otherEdit).onPressed, isNotNull);
      await tester.ensureVisible(otherEdit);
      await tester.tap(otherEdit);
      await tester.pump();
      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'Other live Job',
      );
      expect(tester.widget<TextField>(nameField).enabled, isTrue);
      expect(await tester.runAsync(() => sqlSnapshot(f.db)), deleted.sql);
      expect(
        f.store.states[f.security.namespace]!.revision,
        deleted.protectedRevision,
      );
      expect(
        f.store.states[f.security.namespace]!.bytes,
        deleted.protectedBytes,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final failure in [
    StateError('lost lifecycle completion'),
    const JobLineRefusal('post-commit lifecycle validation failed'),
  ]) {
    testWidgets(
      failure is StateError
          ? 'delete confirmation and retained uncertain retry survive normal-list filtering'
          : 'post-commit JobLineRefusal retains exact lifecycle retry after filtering',
      (tester) async {
        final f = (await tester.runAsync(NameFixture.create))!;
        addTearDown(f.close);
        var loseReply = true;
        final commands = CompanyJobCommands(
          enrollment: f.enrollment,
          afterCommit: () async {
            if (loseReply) {
              loseReply = false;
              throw failure;
            }
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CompanyJobsPanel(commands: commands, owner: f.owner),
              ),
            ),
          ),
        );
        final delete = find.byKey(
          Key('company-job-delete-${f.createCommand.jobId}'),
        );
        await waitForWidget(tester, delete);
        await tester.ensureVisible(delete);
        await tester.tap(delete);
        await tester.pumpAndSettle();
        expect(find.text('Delete Job?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(
          await tester.runAsync(
            () => f.db.select(f.db.companyJobLifecycles).get(),
          ),
          isEmpty,
        );
        await tester.tap(delete);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, 'Delete Job'));
          await Future<void>.delayed(const Duration(seconds: 1));
        });
        final retry = find.byKey(const Key('company-job-retry-lifecycle'));
        await waitForWidget(tester, find.text('Deleted Job history'));
        await waitForWidget(tester, retry);
        expect(
          find.descendant(
            of: find.byKey(const Key('company-jobs-list')),
            matching: find.byKey(Key('company-job-${f.createCommand.jobId}')),
          ),
          findsNothing,
        );
        final saved = (await tester.runAsync(
          () => f.db.select(f.db.companyJobLifecycles).get(),
        ))!.single;
        await tester.ensureVisible(retry);
        await tester.runAsync(() async {
          await tester.tap(retry);
          await Future<void>.delayed(const Duration(seconds: 1));
        });
        await tester.pump();
        expect(
          find.byKey(const Key('company-job-retry-lifecycle')),
          findsNothing,
        );
        expect(
          (await tester.runAsync(
            () => f.db.select(f.db.companyJobLifecycles).get(),
          ))!.single,
          saved,
        );
        await tester.ensureVisible(find.text('Deleted Job history'));
        await tester.tap(find.text('Deleted Job history'));
        await tester.pumpAndSettle();
        expect(find.text('Baseline'), findsOneWidget);
        expect(
          find.byKey(Key('company-job-delete-${f.createCommand.jobId}')),
          findsNothing,
        );
      },
    );
  }
}
