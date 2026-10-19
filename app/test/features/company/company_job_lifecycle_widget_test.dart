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
import 'company_join_test.dart' show JoinFixture, activateFixtureB;
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
    'delete confirmation and retained uncertain retry survive normal-list filtering',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      var loseReply = true;
      final commands = CompanyJobCommands(
        enrollment: f.enrollment,
        afterCommit: () async {
          if (loseReply) {
            loseReply = false;
            throw StateError('lost lifecycle completion');
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
