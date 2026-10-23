import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_crypto.dart';
import '../../tool/native_nearby_test_commands.dart';
import '../features/company/company_job_details_test.dart' show details;
import '../features/company/company_job_name_test.dart' show NameFixture;
import 'job_name_native_ui_test.dart' as native show mount, ready, tap;
import 'native_nearby_test_commands_test.dart' as command_test show Fixture;

void main() {
  testWidgets(
    'admitted details save returns once after verification crosses command deadline',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      await native.mount(tester, f);
      final original = await tester.runAsync(
        () => f.db.select(f.db.companyJobs).get(),
      );
      final cache = command_test.Fixture();
      final wire = NativeTestCommand.encodeRequest(
        session: cache.localSession,
        sequence: 1,
        action: NativeTestAction.jobDetailsUi,
        deadlineMillis: 15000,
        jobDetailsStep: NativeJobDetailsUiStep.editMixedOffline,
      );
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      await adapter.saveJobDetailsThroughNativeUi(
        tester: tester,
        jobId: f.createCommand.jobId,
        text: {JobDetailField.notes: 'Admitted offline save'},
        tap: (target) => native.tap(tester, target),
        waitUntilReady: (ready) => native.ready(tester, ready),
        requireBeforeEffect: () => adapter.validateJoinNativeDeadline(
          cache.now,
          command.deadlineMillis,
        ),
      );
      final views = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!;
      adapter.assertJobDetailsNativeViewUi(tester, views);
      final verified = (await tester.runAsync(
        () => f.commands.detailsSyncHoldings(ownerSession: f.owner),
      ))!;
      expect(verified, hasLength(1));
      expect(views.single.details.notes.value, 'Admitted offline save');
      cache.now = 20000;
      expect(
        cache.cache.submitJson(wire).state,
        NativeTestCommandState.unknown,
      );
      expect(cache.cache.takeNext(), isNull);
      var routePushes = 0;
      var controllerReady = false;
      var pumps = 0;
      State? captured;
      Future<void> wait(bool Function() ready) =>
          adapter.waitForJoinNativeCompletion(
            ready: ready,
            elapsedMillis: () => cache.now,
            commandDeadlineMillis: command.deadlineMillis,
            pump: () async {
              pumps++;
              cache.now += 50;
              await tester.pump(const Duration(milliseconds: 50));
              if (pumps > 1) controllerReady = true;
            },
          );
      await adapter.completeJobDetailsNativeUiReturn(
        isStillCurrent: () => true,
        waitForCompletion: wait,
        mountPage: (waitUntilReady) async {
          await tester.pumpWidget(
            const MaterialApp(key: Key('details-return-app'), home: Scaffold()),
          );
          final navigator = Navigator.of(tester.element(find.byType(Scaffold)));
          const key = Key('details-return-page');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            routePushes++;
            unawaited(
              navigator.push<void>(
                MaterialPageRoute(
                  builder: (_) => const Form(key: key, child: SizedBox()),
                ),
              ),
            );
          });
          await tester.pump();
          expect(find.byKey(key), findsNothing);
          captured = await adapter.captureJoinNativePageState(
            tester: tester,
            page: find.byKey(key),
            waitUntilReady: waitUntilReady,
          );
          await waitUntilReady(() => controllerReady);
        },
      );
      final reply = cache.cache.complete(
        command,
        const NativeTestCommandResult.effect(),
      );
      expect(reply.state, NativeTestCommandState.completed);
      expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
      expect(cache.cache.takeNext(), isNull);
      expect(routePushes, 1);
      expect(captured!.mounted, isTrue);
      expect(controllerReady, isTrue);
      expect(f.owner.isValid, isTrue);
      expect(
        await tester.runAsync(
          () => f.commands.detailsSyncHoldings(ownerSession: f.owner),
        ),
        verified,
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobs).get()),
        original,
      );
      expect(
        cache.cache.submitJson(cache.request(2, deadline: 15000)).error,
        NativeTestCommandError.deadlineExpired,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('deadline before details Save produces no signed mutation', (
    tester,
  ) async {
    final f = (await tester.runAsync(NameFixture.create))!;
    addTearDown(f.close);
    await native.mount(tester, f);
    var checks = 0;
    await expectLater(
      adapter.saveJobDetailsThroughNativeUi(
        tester: tester,
        jobId: f.createCommand.jobId,
        text: {JobDetailField.notes: 'Must not save'},
        tap: (target) => native.tap(tester, target),
        waitUntilReady: (ready) => native.ready(tester, ready),
        requireBeforeEffect: () {
          checks++;
          adapter.validateJoinNativeDeadline(checks < 4 ? 0 : 15000, 15000);
        },
      ),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(checks, 4);
    expect(
      await tester.runAsync(() => f.db.select(f.db.companyJobDetails).get()),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final lossBeforePush in [true, false]) {
    test(
      'details return refuses lifecycle loss ${lossBeforePush ? 'before push' : 'during completion'}',
      () async {
        var current = !lossBeforePush;
        var routePushes = 0;
        await expectLater(
          adapter.completeJobDetailsNativeUiReturn(
            isStillCurrent: () => current,
            waitForCompletion: (_) async {},
            mountPage: (_) async {
              routePushes++;
              current = false;
            },
          ),
          throwsA(isA<NativeTestFailure>()),
        );
        expect(routePushes, lossBeforePush ? 0 : 1);
      },
    );
  }

  test('details return preserves controller readiness failure', () async {
    var elapsed = 20000;
    var routePushes = 0;
    await expectLater(
      adapter.completeJobDetailsNativeUiReturn(
        isStillCurrent: () => true,
        waitForCompletion: (ready) => adapter.waitForJoinNativeCompletion(
          ready: ready,
          elapsedMillis: () => elapsed,
          commandDeadlineMillis: 15000,
          pump: () async => elapsed += 180000,
        ),
        mountPage: (waitUntilReady) async {
          routePushes++;
          await waitUntilReady(() => false);
        },
      ),
      throwsA(anything),
    );
    expect(routePushes, 1);
  });

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
        text: {JobDetailField.customer: 'Acme', JobDetailField.notes: null},
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
