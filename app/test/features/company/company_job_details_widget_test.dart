import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_name_test.dart' show NameFixture;
import 'company_job_details_test.dart' show details;
import 'company_jobs_widget_test.dart' show waitForWidget;

void main() {
  testWidgets(
    'actual details editor retries identical save and resolves only chosen field',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      var loseReply = true;
      final commands = CompanyJobCommands(
        enrollment: f.enrollment,
        afterCommit: () async {
          if (loseReply) {
            loseReply = false;
            throw StateError('lost reply');
          }
        },
      );
      Widget page(CompanyJobCommands c) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CompanyJobsPanel(commands: c, owner: f.owner),
          ),
        ),
      );
      await tester.pumpWidget(page(commands));
      final edit = find.byKey(
        Key('company-job-edit-details-${f.createCommand.jobId}'),
      );
      await waitForWidget(tester, edit);
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pump();
      final notes = find.byKey(const Key('company-job-details-notes'));
      await tester.ensureVisible(notes);
      await tester.enterText(notes, 'UI note');
      await tester.pump();
      final save = find.byKey(const Key('company-job-save-details'));
      await tester.ensureVisible(save);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.runAsync(() async {
        await tester.tap(save);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      final retry = find.byKey(const Key('company-job-retry-details'));
      await waitForWidget(tester, retry);
      expect(tester.widget<TextField>(notes).enabled, isFalse);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const Key('company-job-reload-details')),
            )
            .onPressed,
        isNull,
      );
      final request = (await tester.runAsync(
        () => f.db.select(f.db.companyJobDetails).get(),
      ))!.single.requestId;
      await tester.ensureVisible(retry);
      await tester.runAsync(() async {
        await tester.tap(retry);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, find.text('Notes: UI note'));
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobDetails).get()),
        hasLength(1),
      );
      expect(
        (await tester.runAsync(
          () => f.db.select(f.db.companyJobDetails).get(),
        ))!.single.requestId,
        request,
      );
      await tester.runAsync(() async {
        await f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(
              notes: SetField('Other note'),
              customer: SetField('A'),
            ),
          ),
          ownerSession: f.owner,
        );
        await f.commands.patchJobDetails(
          details(f, const JobDetailsPatch(customer: SetField('B'))),
          ownerSession: f.owner,
        );
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page(f.commands));
      final conflict = find.byKey(
        Key('company-job-details-conflict-notes-${f.createCommand.jobId}'),
      );
      await waitForWidget(tester, conflict);
      expect(find.text('UI note'), findsOneWidget);
      expect(find.text('Other note'), findsOneWidget);
      final view = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!.single;
      final candidate = view.details.notes.candidates.singleWhere(
        (c) => c.value == 'UI note',
      );
      final choice = find.byKey(
        Key('company-job-details-candidate-notes-${candidate.operationId}'),
      );
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const Key('company-job-save-details')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('company-job-save-details')));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, edit);
      final resolved = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!.single.details;
      expect(resolved.notes.value, 'UI note');
      expect(resolved.notes.hasConflict, isFalse);
      expect(resolved.customer.hasConflict, isTrue);
      expect(resolved.customer.candidates.map((c) => c.value).toSet(), {
        'A',
        'B',
      });
      final customer = resolved.customer.candidates.singleWhere(
        (c) => c.value == 'A',
      );
      final customerChoice = find.byKey(
        Key('company-job-details-candidate-customer-${customer.operationId}'),
      );
      await tester.ensureVisible(customerChoice);
      await tester.tap(customerChoice);
      await tester.pump();
      await tester.runAsync(
        () => f.commands.patchJobDetails(
          details(f, const JobDetailsPatch(customer: SetField('Unseen'))),
          ownerSession: f.owner,
        ),
      );
      final before = (await tester.runAsync(
        () => f.db.select(f.db.companyJobDetails).get(),
      ))!.length;
      await tester.ensureVisible(
        find.byKey(const Key('company-job-save-details')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('company-job-save-details')));
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, edit);
      expect(find.byKey(const Key('company-job-retry-details')), findsNothing);
      expect(
        find.text('Details resolution frontier changed. Reload alternatives.'),
        findsOneWidget,
      );
      final stale = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!.single.details;
      expect(stale.customer.candidates.map((c) => c.value).toSet(), {
        'A',
        'B',
        'Unseen',
      });
      expect(stale.notes.value, 'UI note');
      expect(
        (await tester.runAsync(
          () => f.db.select(f.db.companyJobDetails).get(),
        ))!.length,
        before,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'actual panel preserves uncertain details request across earlier Job insertion',
    (tester) async {
      final f = (await tester.runAsync(
        () => NameFixture.create(jobId: 'ffffffff-ffff-4fff-bfff-ffffffffffff'),
      ))!;
      addTearDown(f.close);
      var lost = false;
      final commands = CompanyJobCommands(
        enrollment: f.enrollment,
        afterCommit: () async {
          if (!lost) {
            lost = true;
            await f.security.reconcile(f.db);
            throw StateError('reply lost after reconciliation');
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
      final section = find.byKey(
        Key('company-job-details-${f.createCommand.jobId}'),
      );
      final edit = find.byKey(
        Key('company-job-edit-details-${f.createCommand.jobId}'),
      );
      await waitForWidget(tester, edit);
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pump();
      final notes = find.descendant(
        of: section,
        matching: find.byKey(const Key('company-job-details-notes')),
      );
      await tester.ensureVisible(notes);
      await tester.enterText(notes, 'Pending note');
      await tester.pump();
      final save = find.descendant(
        of: section,
        matching: find.byKey(const Key('company-job-save-details')),
      );
      await tester.ensureVisible(save);
      await tester.runAsync(() async {
        await tester.tap(save);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      final retry = find.descendant(
        of: section,
        matching: find.byKey(const Key('company-job-retry-details')),
      );
      await waitForWidget(tester, retry);
      final request = (await tester.runAsync(
        () => f.db.select(f.db.companyJobDetails).get(),
      ))!.single.requestId;
      expect(lost, isTrue);
      // The existing protected command reconciler has finished; UI retry still owns this request.
      final signedState = f.store.states[f.security.namespace]!;
      expect(
        jsonDecode(utf8.decode(signedState.bytes))['pendingCommand'],
        isNull,
      );
      final createName = find.byKey(const Key('company-job-name'));
      await tester.ensureVisible(createName);
      await tester.enterText(createName, 'Earlier Job');
      await tester.pump();
      final create = find.byKey(const Key('company-create-job'));
      await tester.ensureVisible(create);
      await tester.runAsync(() async {
        await tester.tap(create);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(
        tester,
        find.descendant(
          of: find.byKey(const Key('company-jobs-list')),
          matching: find.text('Earlier Job'),
        ),
      );
      await tester.pump();
      final views = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!;
      expect(views.length, 2);
      expect(views.first.baseJob.id, isNot(f.createCommand.jobId));
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.runAsync(() async {
        await tester.tap(retry);
        await Future<void>.delayed(const Duration(seconds: 1));
      });
      await waitForWidget(tester, edit);
      final history = (await tester.runAsync(
        () => f.db.select(f.db.companyJobDetails).get(),
      ))!;
      expect(history.length, 1);
      expect(history.single.requestId, request);
      expect(
        find.descendant(
          of: section,
          matching: find.text('Notes: Pending note'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
