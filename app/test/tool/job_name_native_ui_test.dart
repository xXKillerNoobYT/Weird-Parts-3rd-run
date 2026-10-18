import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../features/company/company_job_name_test.dart' show NameFixture;

Future<void> ready(WidgetTester tester, bool Function() predicate) async {
  for (var i = 0; i < 400 && !predicate(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(predicate(), isTrue);
}

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
}

Future<void> mount(WidgetTester tester, NameFixture fixture) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CompanyJobsPanel(
            commands: fixture.commands,
            owner: fixture.owner,
          ),
        ),
      ),
    ),
  );
  await ready(
    tester,
    () => find.byKey(const Key('company-job-name')).evaluate().length == 1,
  );
}

void main() {
  testWidgets(
    'native name helper saves through production editor and preserves creation',
    (tester) async {
      final fixture = (await tester.runAsync(NameFixture.create))!;
      addTearDown(fixture.close);
      final original = await tester.runAsync(
        () => fixture.db.select(fixture.db.companyJobs).get(),
      );
      await mount(tester, fixture);
      var effectChecks = 0;
      await adapter.saveJobNameThroughNativeUi(
        tester: tester,
        jobId: fixture.createCommand.jobId,
        name: 'Native edited name',
        tap: (target) => tap(tester, target),
        waitUntilReady: (predicate) => ready(tester, predicate),
        requireBeforeEffect: () {
          effectChecks++;
        },
      );
      final views = (await tester.runAsync(
        () => fixture.commands.listJobViews(ownerSession: fixture.owner),
      ))!;
      expect(views.single.resolvedName, 'Native edited name');
      expect(views.single.nameHeads, hasLength(1));
      adapter.assertJobNameNativeViewUi(tester, views);
      expect(
        await tester.runAsync(
          () => fixture.db.select(fixture.db.companyJobs).get(),
        ),
        original,
      );
      expect(effectChecks, 1);
    },
  );

  testWidgets(
    'native resolution selects an actual attributed alternative with both parents',
    (tester) async {
      final fixture = (await tester.runAsync(NameFixture.create))!;
      addTearDown(fixture.close);
      await tester.runAsync(() async {
        await fixture.commands.renameJob(
          fixture.rename('First candidate'),
          ownerSession: fixture.owner,
        );
        await fixture.commands.renameJob(
          fixture.rename('Second candidate'),
          ownerSession: fixture.owner,
        );
      });
      await mount(tester, fixture);
      final before = (await tester.runAsync(
        () => fixture.commands.listJobViews(ownerSession: fixture.owner),
      ))!;
      expect(before.single.hasConflict, isTrue);
      adapter.assertJobNameNativeViewUi(tester, before);
      final candidate = before.single.candidates.first;
      await adapter.saveJobNameThroughNativeUi(
        tester: tester,
        jobId: fixture.createCommand.jobId,
        name: candidate.name,
        candidateOperationId: candidate.operationId,
        tap: (target) => tap(tester, target),
        waitUntilReady: (predicate) => ready(tester, predicate),
        requireBeforeEffect: () {},
      );
      final after = (await tester.runAsync(
        () => fixture.commands.listJobViews(ownerSession: fixture.owner),
      ))!;
      expect(after.single.hasConflict, isFalse);
      expect(after.single.resolvedName, candidate.name);
      expect(after.single.nameHeads, hasLength(1));
      final history = (await tester.runAsync(
        () => fixture.db.select(fixture.db.companyJobNames).get(),
      ))!;
      expect(history, hasLength(3));
      final resolution = history.singleWhere(
        (row) => row.operationCommitment == after.single.nameHeads.single,
      );
      final body =
          (jsonDecode(resolution.operationBytes) as Map)['body'] as Map;
      expect(body['parents'], before.single.nameHeads);
      adapter.assertJobNameNativeViewUi(tester, after);
    },
  );
}
