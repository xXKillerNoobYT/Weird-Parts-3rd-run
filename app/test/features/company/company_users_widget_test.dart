import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/company/company_gate.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:uuid/uuid.dart';

import 'company_join_test.dart' show JoinFixture;

Future<void> _wait(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(
    finder,
    findsOneWidget,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' | '),
  );
}

Future<void> _manageUser(
  WidgetTester tester,
  String name, {
  String? userId,
}) async {
  final selector = find.byKey(const Key('company-managed-user-selector'));
  await tester.scrollUntilVisible(
    selector,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(selector);
  await tester.pumpAndSettle();
  await tester.tap(
    find
        .text('$name — ${userId == null ? '' : '$userId — '}Create Job only')
        .last,
  );
  await tester.pumpAndSettle();
  await _wait(tester, find.byKey(const Key('company-reset-user')));
}

void main() {
  testWidgets(
    'second-user ambiguous reset freezes target and PIN while first user stays unchanged',
    (tester) async {
      late JoinFixture f;
      late String userId;
      late String firstUserId;
      await tester.runAsync(() async {
        f = await JoinFixture.create();
        firstUserId = (await f.aEnrollment.createRestrictedUser(
          owner: f.owner,
          requestId: const Uuid().v4(),
          name: 'Casey retry',
          pin: '7890',
        )).userId;
        userId = (await f.aEnrollment.createRestrictedUser(
          owner: f.owner,
          requestId: const Uuid().v4(),
          name: 'Casey retry',
          pin: '0123',
        )).userId;
        await f.aEnrollment.signOut();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CompanyBootstrapGate(db: f.aDb, installation: f.a),
        ),
      );
      await _wait(tester, find.byKey(const Key('company-signin')));
      final signInChoices = tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: find.byKey(const Key('company-user-selector')),
              matching: find.byWidgetPredicate(
                (widget) => widget is DropdownButton<String>,
              ),
            ),
          )
          .items!;
      for (final id in [firstUserId, userId]) {
        final item = signInChoices.singleWhere((item) => item.value == id);
        expect((item.child as Text).data, contains(id));
      }
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '1234',
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-signin'))),
      );
      await _wait(tester, find.textContaining('Company ID:'));
      expect(find.byKey(const Key('company-reset-user')), findsNothing);
      await _manageUser(tester, 'Casey retry', userId: userId);
      final selectorCallback = tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('company-managed-user-selector')),
          )
          .onChanged!;
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-reset-user')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _wait(tester, find.byKey(const Key('company-reset-user')));
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-reset-pin')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('company-reset-pin')),
        '4567',
      );
      await tester.runAsync(
        () => f.aDb.customStatement(
          "CREATE TRIGGER widget_projection_fault BEFORE INSERT ON company_user_events BEGIN SELECT RAISE(ABORT, 'synthetic projection fault'); END",
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('company-reset-user')));
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-reset-user'))),
      );
      await tester.pump();
      await _wait(
        tester,
        find.byWidgetPredicate(
          (widget) =>
              widget is OutlinedButton &&
              widget.key == const Key('company-reset-user') &&
              widget.onPressed != null,
        ),
      );
      expect(
        find.textContaining('This PIN replacement request is pending.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const Key('company-managed-user-selector')),
            )
            .onChanged,
        isNull,
      );
      selectorCallback(firstUserId);
      await tester.pump();
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byKey(const Key('company-managed-user-selector')),
            )
            .value,
        userId,
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('company-reset-pin')),
      );
      expect(field.enabled, isFalse);
      // Even programmatic controller edits cannot change an existing intent.
      field.controller!.text = '6789';
      await tester.runAsync(
        () => f.aDb.customStatement('DROP TRIGGER widget_projection_fault'),
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-reset-user'))),
      );
      await _wait(
        tester,
        find.textContaining('Additional-user PIN replaced here.'),
      );
      await tester.runAsync(() async {
        expect((await f.aDb.select(f.aDb.companyUserEvents).get()).length, 3);
        final first = await f.aEnrollment.userLifecycleStatus(
          userId: firstUserId,
        );
        expect(first!.credentialVersion, 1);
        expect(first.attemptsRemaining, 8);
        expect(first.disabled, isFalse);
        await f.aEnrollment.signInUser(firstUserId, '7890');
        await expectLater(
          f.aEnrollment.signInUser(userId, '6789'),
          throwsA(isA<CompanyBootstrapRefusal>()),
        );
        await f.aEnrollment.signInUser(userId, '4567');
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Owner replaces a forgotten PIN through Gate and user signs in with replacement offline',
    (tester) async {
      late JoinFixture f;
      await tester.runAsync(() async {
        f = await JoinFixture.create(allowOwnerAdditions: true);
        await f.aEnrollment.createRestrictedUser(
          owner: f.owner,
          requestId: const Uuid().v4(),
          name: 'Casey UI',
          pin: '0123',
        );
        await f.aEnrollment.signOut();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CompanyBootstrapGate(db: f.aDb, installation: f.a),
        ),
      );
      await _wait(tester, find.byKey(const Key('company-signin')));
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '1234',
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-signin'))),
      );
      await _wait(tester, find.textContaining('Company ID:'));
      await _manageUser(tester, 'Casey UI');
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-reset-user')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _wait(tester, find.byKey(const Key('company-reset-user')));
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-reset-pin')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('company-reset-pin')),
        '4567',
      );
      await tester.ensureVisible(find.byKey(const Key('company-reset-user')));
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-reset-user'))),
      );
      await _wait(
        tester,
        find.textContaining('Additional-user PIN replaced here.'),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-switch-user')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-switch-user'))),
      );
      await _wait(tester, find.byKey(const Key('company-user-selector')));
      await tester.tap(find.byKey(const Key('company-user-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Casey UI').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '0123',
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-signin'))),
      );
      await _wait(tester, find.textContaining('User PIN refused'));
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '4567',
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-signin'))),
      );
      await _wait(tester, find.textContaining('Company ID:'));
      expect(find.byKey(const Key('company-reset-user')), findsNothing);
      expect(find.byKey(const Key('company-disable-user')), findsNothing);
      expect(find.byKey(const Key('company-enroll-open')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'damaged additional-user policy does not lock the owner Job list',
    (tester) async {
      late JoinFixture f;
      late String name;
      late String userId;
      await tester.runAsync(() async {
        f = await JoinFixture.create();
        userId = (await f.aEnrollment.createRestrictedUser(
          owner: f.owner,
          requestId: const Uuid().v4(),
          name: 'Casey',
          pin: '0123',
        )).userId;
        name = (await f.aDb.select(f.aDb.jobs).get()).single.name;
        f.aStore.states[companyUserNamespace(
          f.a.namespace,
        )] = ProtectedInstallationState(
          const Uuid().v4(),
          Uint8List.fromList(utf8.encode('{"v":77}')),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(
                commands: CompanyJobCommands(enrollment: f.aEnrollment),
                owner: f.owner,
              ),
            ),
          ),
        ),
      );
      await _wait(tester, find.byKey(const Key('company-create-job')));
      expect(find.text(name), findsOneWidget);
      expect(
        find.textContaining('Additional-user policy is unavailable'),
        findsOneWidget,
      );
      await tester.runAsync(
        () => expectLater(
          f.aEnrollment.signInUser(userId, '0123'),
          throwsA(isA<CompanyBootstrapRefusal>()),
        ),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'owner sees the exact retained additional-user Job as held without an applied confirmation',
    (tester) async {
      late JoinFixture f;
      late OwnerSession owner;
      late String id;
      late String resetJobId;
      await tester.runAsync(() async {
        f = await JoinFixture.create(allowOwnerAdditions: true);
        final user = await f.aEnrollment.createRestrictedUser(
          owner: f.owner,
          requestId: const Uuid().v4(),
          name: 'Casey',
          pin: '0123',
        );
        final selected = await f.aEnrollment.signInUser(user.userId, '0123');
        id = const Uuid().v4();
        await CompanyJobCommands(enrollment: f.aEnrollment).createJob(
          CreateJob(
            companyId: selected.identity.companyId,
            shopId: selected.identity.shopId,
            jobId: id,
            requestId: const Uuid().v4(),
            name: 'Offline retained work',
          ),
          ownerSession: selected,
        );
        owner = await f.aEnrollment.signIn('1234');
        final other = await f.aEnrollment.createRestrictedUser(
          owner: owner,
          requestId: const Uuid().v4(),
          name: 'Reset user',
          pin: '4567',
        );
        final otherSession = await f.aEnrollment.signInUser(
          other.userId,
          '4567',
        );
        resetJobId = const Uuid().v4();
        await CompanyJobCommands(enrollment: f.aEnrollment).createJob(
          CreateJob(
            companyId: otherSession.identity.companyId,
            shopId: otherSession.identity.shopId,
            jobId: resetJobId,
            requestId: const Uuid().v4(),
            name: 'Superseded retained work',
          ),
          ownerSession: otherSession,
        );
        owner = await f.aEnrollment.signIn('1234');
        await f.aEnrollment.resetRestrictedUserPin(
          owner: owner,
          userId: other.userId,
          requestId: const Uuid().v4(),
          expectedCredentialVersion: 1,
          pin: '6789',
        );
        await f.aEnrollment.disableRestrictedUser(
          owner: owner,
          userId: user.userId,
          requestId: const Uuid().v4(),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(
                commands: CompanyJobCommands(enrollment: f.aEnrollment),
                owner: owner,
              ),
            ),
          ),
        ),
      );
      await _wait(tester, find.byKey(Key('company-job-held-$id')));
      expect(
        find.textContaining(
          'Disabled-user work has no applied peer confirmation',
        ),
        findsOneWidget,
      );
      expect(find.text('Offline retained work'), findsOneWidget);
      expect(find.byKey(Key('company-job-held-$resetJobId')), findsOneWidget);
      expect(
        find.textContaining(
          'Superseded-credential work has no applied peer confirmation',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'owner disables selected second user and preserves first-user access',
    (tester) async {
      late JoinFixture f;
      late String firstUserId;
      await tester.runAsync(() async {
        f = await JoinFixture.create();
        firstUserId = (await f.aEnrollment.createRestrictedUser(
          owner: f.owner,
          requestId: const Uuid().v4(),
          name: 'Alex first',
          pin: '7890',
        )).userId;
        await f.aEnrollment.createRestrictedUser(
          owner: f.owner,
          requestId: '11111111-1111-4111-8111-111111111111',
          name: 'Casey Work',
          pin: '0123',
        );
        await f.aEnrollment.signOut();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CompanyBootstrapGate(db: f.aDb, installation: f.a),
        ),
      );
      await _wait(tester, find.byKey(const Key('company-signin')));
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '1234',
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-signin'))),
      );
      await _wait(tester, find.textContaining('Company ID:'));
      await _manageUser(tester, 'Casey Work');
      await tester.scrollUntilVisible(
        find.textContaining('Additional user capacity reached'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final disable = find.byKey(const Key('company-disable-user'));
      expect(disable, findsOneWidget);
      await tester.ensureVisible(disable);
      await tester.runAsync(() => tester.tap(disable));
      await _wait(tester, find.text('Casey Work (disabled)'));
      expect(find.byKey(const Key('company-disable-user')), findsNothing);
      await tester.runAsync(() async {
        final first = await f.aEnrollment.userLifecycleStatus(
          userId: firstUserId,
        );
        expect(first!.disabled, isFalse);
        expect(first.credentialVersion, 1);
        expect(first.attemptsRemaining, 8);
        await f.aEnrollment.signInUser(firstUserId, '7890');
      });
      await tester.scrollUntilVisible(
        find.textContaining('Company ID:'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Company ID:'), findsOneWidget);
      expect(
        await tester.runAsync(() => f.aEnrollment.readStatus()),
        CompanyBootstrapStatus.active,
      );
      final record = jsonDecode(
        utf8.decode(
          f.aStore.states[companyUserNamespace(f.a.namespace, slot: 2)]!.bytes,
        ),
      ) as Map;
      expect(record['v'], 2);
      expect(record['p'], isNull);
      expect(record['d'], hasLength(5));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('company lock screen offers a stable company user selector', (
    tester,
  ) async {
    late JoinFixture f;
    await tester.runAsync(() async {
      f = await JoinFixture.create();
      await f.aEnrollment.signOut();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CompanyBootstrapGate(db: f.aDb, installation: f.a),
      ),
    );
    for (
      var i = 0;
      i < 80 && find.byKey(const Key('company-signin')).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.byKey(const Key('company-signin')), findsOneWidget);
    expect(find.byKey(const Key('company-user-selector')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'owner creates named user and switches to restricted offline Job through production gate',
    (tester) async {
      late JoinFixture f;
      await tester.runAsync(() async {
        f = await JoinFixture.create(allowOwnerAdditions: true);
        await f.aEnrollment.signOut();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CompanyBootstrapGate(db: f.aDb, installation: f.a),
        ),
      );
      await _wait(tester, find.byKey(const Key('company-signin')));
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '1234',
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-signin'))),
      );
      await _wait(tester, find.textContaining('Company ID:'));
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-create-user')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('company-user-name')),
        'Sam UI',
      );
      await tester.enterText(find.byKey(const Key('company-user-pin')), '0123');
      await tester.ensureVisible(find.byKey(const Key('company-create-user')));
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-create-user'))),
      );
      await _wait(tester, find.text('Sam UI'));
      expect(find.byKey(const Key('company-create-user')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('company-user-name')),
        'Alex second',
      );
      await tester.enterText(find.byKey(const Key('company-user-pin')), '7890');
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-create-user'))),
      );
      await _wait(
        tester,
        find.textContaining('Additional user capacity reached'),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-switch-user')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-switch-user'))),
      );
      await _wait(tester, find.byKey(const Key('company-user-selector')));
      await tester.tap(find.byKey(const Key('company-user-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sam UI').last);
      await tester.pumpAndSettle();
      final directory = await tester.runAsync(
        () => f.aEnrollment.listCompanyUsers(),
      );
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byKey(const Key('company-user-selector')),
            )
            .value,
        directory!.singleWhere((user) => user.name == 'Sam UI').userId,
      );
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '0123',
      );
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-signin'))),
      );
      await _wait(tester, find.textContaining('Company ID:'));
      expect(find.byKey(const Key('company-enroll-open')), findsNothing);
      expect(find.byKey(const Key('company-peer-open')), findsNothing);
      expect(find.byKey(const Key('company-join-open')), findsNothing);
      expect(find.byKey(const Key('company-join-resume')), findsNothing);
      expect(find.byKey(const Key('company-create-user')), findsNothing);
      await tester.scrollUntilVisible(
        find.textContaining('Create Job permission only. Sign in as the owner'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        find.byType(CompanyJobsPanel),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _wait(tester, find.byKey(const Key('company-job-name')));
      await tester.enterText(
        find.byKey(const Key('company-job-name')),
        'Sam UI Job',
      );
      await tester.ensureVisible(find.byKey(const Key('company-create-job')));
      await tester.runAsync(
        () async => tester.tap(find.byKey(const Key('company-create-job'))),
      );
      await _wait(
        tester,
        find.descendant(
          of: find.byKey(const Key('company-jobs-list')),
          matching: find.text('Sam UI Job'),
        ),
      );
      final users = await tester.runAsync(
        () => f.aEnrollment.listCompanyUsers(),
      );
      final rows = await tester.runAsync(
        () => f.aDb.select(f.aDb.companyJobs).get(),
      );
      final authored = rows!.singleWhere(
        (r) =>
            (jsonDecode(r.operationBytes)['body'] as Map)['name'] ==
            'Sam UI Job',
      );
      expect(
        jsonDecode(authored.operationBytes)['body']['user'],
        users!.last.userId,
      );
      expect(
        jsonDecode(authored.operationBytes)['body']['device'],
        f.owner.identity.deviceId,
      );
      expect(find.byKey(const Key('company-disable-user')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
