import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_crypto.dart';
import '../features/company/company_job_details_test.dart' show details;
import '../features/company/company_job_name_test.dart' show NameFixture;
import 'job_name_native_ui_test.dart' as native show mount, ready, tap;

void main() {
  testWidgets(
    'native details helper edits only target section and keeps creation/name bytes',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      await tester.runAsync(
        () => f.commands.createJob(
          CreateJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: const Uuid().v4(),
            requestId: const Uuid().v4(),
            name: 'Other Job',
          ),
          ownerSession: f.owner,
        ),
      );
      final creation = await tester.runAsync(
        () => f.db.select(f.db.companyJobs).get(),
      );
      final names = await tester.runAsync(
        () => f.db.select(f.db.companyJobNames).get(),
      );
      await native.mount(tester, f);
      var effectChecks = 0;
      await adapter.saveJobDetailsThroughNativeUi(
        tester: tester,
        jobId: f.createCommand.jobId,
        text: {
          JobDetailField.customer: 'Acme',
          JobDetailField.notes: null,
        },
        status: CompanyJobStatus.archived,
        tap: (target) => native.tap(tester, target),
        waitUntilReady: (predicate) => native.ready(tester, predicate),
        requireBeforeEffect: () => effectChecks++,
      );
      var views = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!;
      final mixed = views.singleWhere(
        (v) => v.baseJob.id == f.createCommand.jobId,
      );
      expect(mixed.details.jobNumber.value, isNull);
      final initial = (await tester.runAsync(
        () => f.db.select(f.db.companyJobDetails).get(),
      ))!.single;
      final initialUnits =
          ((jsonDecode(initial.operationBytes) as Map)['body'] as Map)['units']
              as Map;
      expect(initialUnits.keys.toSet(), {'customer', 'notes', 'status'});
      expect((initialUnits['notes'] as Map)['value'], isNull);
      var previousHeads = mixed.details.jobNumber.heads;
      for (final value in ['JP-17', '']) {
        await adapter.saveJobDetailsThroughNativeUi(
          tester: tester,
          jobId: f.createCommand.jobId,
          text: {JobDetailField.jobNumber: value},
          tap: (target) => native.tap(tester, target),
          waitUntilReady: (predicate) => native.ready(tester, predicate),
          requireBeforeEffect: () => effectChecks++,
        );
        views = (await tester.runAsync(
          () => f.commands.listJobViews(ownerSession: f.owner),
        ))!;
        final current = views.singleWhere(
          (v) => v.baseJob.id == f.createCommand.jobId,
        );
        expect(current.details.jobNumber.value, value);
        final history = (await tester.runAsync(
          () => f.db.select(f.db.companyJobDetails).get(),
        ))!;
        final saved = history.singleWhere(
          (row) =>
              row.operationCommitment == current.details.jobNumber.heads.single,
        );
        final units =
            ((jsonDecode(saved.operationBytes) as Map)['body'] as Map)['units']
                as Map;
        expect(units.keys.toSet(), {'jobNumber'});
        expect((units['jobNumber'] as Map)['value'], value);
        expect((units['jobNumber'] as Map)['parents'], previousHeads);
        previousHeads = current.details.jobNumber.heads;
      }
      final edited = views.singleWhere(
        (v) => v.baseJob.id == f.createCommand.jobId,
      );
      expect(edited.details.customer.value, 'Acme');
      expect(edited.details.status.value, CompanyJobStatus.archived);
      expect(edited.details.notes.value, isNull);
      expect(edited.details.jobNumber.value, '');
      final other = views.singleWhere(
        (v) => v.baseJob.id != f.createCommand.jobId,
      );
      expect(other.details.customer.heads, isEmpty);
      expect(other.details.notes.heads, isEmpty);
      expect(other.details.location.heads, isEmpty);
      expect(other.details.jobNumber.heads, isEmpty);
      expect(other.details.status.heads, isEmpty);
      expect(edited.details.customer.heads, mixed.details.customer.heads);
      expect(edited.details.notes.heads, mixed.details.notes.heads);
      expect(edited.details.status.heads, mixed.details.status.heads);
      adapter.assertJobDetailsNativeViewUi(tester, views);
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobs).get()),
        creation,
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobNames).get()),
        names,
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobDetails).get()),
        hasLength(3),
      );
      expect(effectChecks, greaterThan(4));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'native details candidate proves attribution and resolves only notes',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      await tester.runAsync(() async {
        await f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(
              customer: SetField('A'),
              notes: SetField('First note'),
            ),
          ),
          ownerSession: f.owner,
        );
        await f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(
              customer: SetField('B'),
              notes: SetField('Other note'),
            ),
          ),
          ownerSession: f.owner,
        );
      });
      await native.mount(tester, f);
      final before = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!;
      adapter.assertJobDetailsNativeViewUi(tester, before);
      final candidate = before.single.details.notes.candidates.first;
      await adapter.saveJobDetailsThroughNativeUi(
        tester: tester,
        jobId: f.createCommand.jobId,
        notesCandidateOperationId: candidate.operationId,
        tap: (target) => native.tap(tester, target),
        waitUntilReady: (predicate) => native.ready(tester, predicate),
        requireBeforeEffect: () {},
      );
      final after = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!;
      expect(after.single.details.notes.hasConflict, isFalse);
      expect(after.single.details.notes.value, candidate.value);
      expect(after.single.details.customer.hasConflict, isTrue);
      expect(
        after.single.details.customer.heads,
        before.single.details.customer.heads,
      );
      final history = (await tester.runAsync(
        () => f.db.select(f.db.companyJobDetails).get(),
      ))!;
      expect(history, hasLength(3));
      final saved = history.singleWhere(
        (r) => r.operationCommitment == after.single.details.notes.heads.single,
      );
      final body = (jsonDecode(saved.operationBytes) as Map)['body'] as Map;
      expect(body['resolve'], ['notes']);
      expect((body['units'] as Map).keys, ['notes']);
      expect(
        ((body['units'] as Map)['notes'] as Map)['parents'],
        before.single.details.notes.heads,
      );
      adapter.assertJobDetailsNativeViewUi(tester, after);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('uncertain details save refuses without automatic retry', (
    tester,
  ) async {
    final f = (await tester.runAsync(NameFixture.create))!;
    addTearDown(f.close);
    var commits = 0;
    final commands = CompanyJobCommands(
      enrollment: f.enrollment,
      afterCommit: () async {
        commits++;
        throw StateError('lost reply');
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
    await native.ready(
      tester,
      () =>
          find
              .byKey(Key('company-job-edit-details-${f.createCommand.jobId}'))
              .evaluate()
              .length ==
          1,
    );
    await expectLater(
      adapter.saveJobDetailsThroughNativeUi(
        tester: tester,
        jobId: f.createCommand.jobId,
        text: {JobDetailField.notes: 'Pending result'},
        tap: (target) => native.tap(tester, target),
        waitUntilReady: (predicate) => native.ready(tester, predicate),
        requireBeforeEffect: () {},
      ),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(commits, 1);
    expect(find.byKey(const Key('company-job-retry-details')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('company-job-details-notes')))
          .enabled,
      isFalse,
    );
    expect(
      await tester.runAsync(() => f.db.select(f.db.companyJobDetails).get()),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
