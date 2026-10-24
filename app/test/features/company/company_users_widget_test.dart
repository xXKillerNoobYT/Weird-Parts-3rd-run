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

void main() {
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
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'owner disables the additional user through the production gate and keeps owner access',
    (tester) async {
      late JoinFixture f;
      await tester.runAsync(() async {
        f = await JoinFixture.create();
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
      await tester.scrollUntilVisible(
        find.textContaining('Additional user capacity reached'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final disable = find.byKey(const Key('company-disable-user'));
      expect(disable, findsOneWidget);
      await tester.runAsync(() => tester.tap(disable));
      await _wait(tester, find.text('Casey Work (disabled)'));
      expect(find.byKey(const Key('company-disable-user')), findsNothing);
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
          f.aStore.states[companyUserNamespace(f.a.namespace)]!.bytes,
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
        directory!.last.userId,
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
