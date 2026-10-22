import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/jobs_page.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late AppDatabase db;
  late String deviceId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deviceId = await db.settingsDao.ensureDeviceId();
  });

  tearDown(() => db.close());

  Future<void> pumpJobs(WidgetTester tester) async {
    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: deviceId,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: const MaterialApp(home: JobsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty shop distinguishes blank searches from no matches', (
    tester,
  ) async {
    await pumpJobs(tester);
    expect(find.text('No active jobs'), findsOneWidget);
    expect(find.text('No jobs match your search'), findsNothing);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(find.text('No active jobs'), findsOneWidget);
    expect(find.text('No jobs match your search'), findsNothing);

    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();
    expect(find.text('No jobs match your search'), findsOneWidget);
    expect(find.text('No active jobs'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('No active jobs'), findsOneWidget);
    expect(find.text('No jobs match your search'), findsNothing);
  });

  testWidgets('search finds names and numbers and clearing restores all jobs', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 21);
    await db.batch((batch) {
      batch.insertAll(db.jobs, [
        JobsCompanion.insert(
          id: 'riverside',
          name: 'Riverside Apartments',
          jobNumber: const Value('WP-Ab2048'),
          originDeviceId: deviceId,
          createdAt: now,
          modifiedAt: now,
        ),
        JobsCompanion.insert(
          id: 'mountain',
          name: 'Mountain Shop',
          jobNumber: const Value('WP-4096'),
          originDeviceId: deviceId,
          createdAt: now,
          modifiedAt: now,
        ),
        JobsCompanion.insert(
          id: 'legacy',
          name: 'Legacy Service',
          originDeviceId: deviceId,
          createdAt: now,
          modifiedAt: now,
        ),
      ]);
    });
    await pumpJobs(tester);
    expect(find.byType(ListTile), findsNWidgets(3));

    for (final query in ['  wP-aB2048  ', '  aB20  ', '  rIvErSiDe  ']) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.text('Riverside Apartments'), findsOneWidget);
      expect(find.text('Mountain Shop'), findsNothing);
      expect(find.text('Legacy Service'), findsNothing);
      expect(find.byType(ListTile), findsOneWidget);
    }

    await tester.enterText(find.byType(TextField), '  lEgAcY  ');
    await tester.pump();
    expect(find.text('Legacy Service'), findsOneWidget);
    expect(find.text('Riverside Apartments'), findsNothing);
    expect(find.text('Mountain Shop'), findsNothing);
    expect(find.byType(ListTile), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();
    expect(find.text('No jobs match your search'), findsOneWidget);
    expect(find.text('No active jobs'), findsNothing);
    expect(find.byType(ListTile), findsNothing);

    for (final query in ['', '   ']) {
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump();
      expect(find.text('No jobs match your search'), findsOneWidget);
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.text('Riverside Apartments'), findsOneWidget);
      expect(find.text('Mountain Shop'), findsOneWidget);
      expect(find.text('Legacy Service'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(3));
      expect(find.text('No jobs match your search'), findsNothing);
      expect(find.text('No active jobs'), findsNothing);
    }
  });
}
