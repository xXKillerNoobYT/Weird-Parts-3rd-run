import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_name_test.dart' show NameFixture, nameSnapshot;
import 'company_jobs_widget_test.dart' show waitForWidget;

void main() {
  testWidgets(
    'actual editor retains lost reply command and renders conflicts with attribution',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      var loseReply = true;
      final commands = CompanyJobCommands(
        enrollment: f.enrollment,
        afterCommit: () async {
          if (loseReply) {
            loseReply = false;
            throw StateError('reply lost');
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
      final edit = find.byKey(Key('company-job-edit-${f.createCommand.jobId}'));
      await waitForWidget(tester, edit);
      await tester.tap(edit);
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('company-job-edit-name')),
        'Edited in UI',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('company-job-save-name')));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(
        tester,
        find.byKey(const Key('company-job-retry-name')),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('company-job-edit-name')))
            .enabled,
        isFalse,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('company-job-retry-name')));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(
        tester,
        find.descendant(
          of: find.byKey(Key('company-job-${f.createCommand.jobId}')),
          matching: find.text('Edited in UI'),
        ),
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobNames).get()),
        hasLength(1),
      );
      await tester.runAsync(
        () =>
            f.commands.renameJob(f.rename('Competing'), ownerSession: f.owner),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(commands: f.commands, owner: f.owner),
            ),
          ),
        ),
      );
      await waitForWidget(
        tester,
        find.byKey(Key('company-job-name-conflict-${f.createCommand.jobId}')),
      );
      expect(find.text('Edited in UI'), findsOneWidget);
      expect(find.text('Competing'), findsOneWidget);
      expect(find.textContaining(f.owner.identity.deviceId), findsNWidgets(2));
      await tester.tap(
        find.byKey(Key('company-job-resolve-name-${f.createCommand.jobId}')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('company-job-edit-name')),
        'Resolved in UI',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('company-job-save-name')));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(
        tester,
        find.descendant(
          of: find.byKey(Key('company-job-${f.createCommand.jobId}')),
          matching: find.text('Resolved in UI'),
        ),
      );
      expect(
        find.byKey(Key('company-job-name-conflict-${f.createCommand.jobId}')),
        findsNothing,
      );
      expect(
        (await tester.runAsync(
          () => f.commands.listJobViews(ownerSession: f.owner),
        ))!.single.nameHeads,
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'stale editor reports full conflict capacity and clears unsaved retry',
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
      final edit = find.byKey(Key('company-job-edit-${f.createCommand.jobId}'));
      await waitForWidget(tester, edit);
      await tester.tap(edit);
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('company-job-edit-name')),
        'Unsaved capacity edit',
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 32; i++) {
          await f.commands.renameJob(
            f.rename('Concurrent $i'),
            ownerSession: f.owner,
          );
        }
      });
      final before = await tester.runAsync(() => nameSnapshot(f));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('company-job-save-name')));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(
        tester,
        find.text(
          'Name conflict capacity reached. Resolve existing names first. No edit was saved.',
        ),
      );
      expect(find.byKey(const Key('company-job-retry-name')), findsNothing);
      expect(find.byKey(const Key('company-job-edit-name')), findsNothing);
      expect(await tester.runAsync(() => nameSnapshot(f)), before);
      expect(
        (await tester.runAsync(() => f.db.select(f.db.companyJobNames).get())),
        hasLength(32),
      );
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
