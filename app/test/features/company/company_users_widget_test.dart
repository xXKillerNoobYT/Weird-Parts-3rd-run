import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/company/company_gate.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

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
      await tester.pumpWidget(const SizedBox());
    },
  );
}
