import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

Finder _navLabel(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

Finder _pinField() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );

Future<void> _pumpShell(
  WidgetTester tester, {
  required AppDatabase db,
  required PinService pin,
  required String deviceId,
  Future<void> Function()? wipeLocalData,
}) async {
  await tester.pumpWidget(
    AppScope(
      db: db,
      pin: pin,
      deviceId: deviceId,
      wipeLocalData: wipeLocalData ?? () async {},
      restoreFromBackup: (_, _) async {},
      child: const MaterialApp(home: HomeShell()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPinAndType1234(WidgetTester tester) async {
  expect(find.text('Editor PIN'), findsOneWidget);
  tester.view.viewInsets = const FakeViewPadding(bottom: 320);
  addTearDown(tester.view.resetViewInsets);
  await tester.pump();
  await tester.enterText(_pinField(), '1234');
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('HomeShell shows navigation destinations', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Jobs'), findsWidgets);
    expect(find.text('Catalog'), findsWidgets);
    expect(find.text('More'), findsWidgets);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('PIN unlock from catalog edit does not crash with folders',
      (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    await db.taxonomyDao.insertCategory(
      id: 'cat-filters',
      name: 'Filters',
      deviceId: deviceId,
    );
    final pin = PinService(db.settingsDao);
    await pin.setPin('1234');

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('Catalog'));
    await tester.pumpAndSettle();
    expect(find.text('Filters'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await _openPinAndType1234(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Editor PIN'), findsNothing);
    expect(find.text('New part'), findsOneWidget);
    expect(find.text('Filters'), findsOneWidget);
  });

  testWidgets('PIN unlock from More tab does not crash with folders',
      (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    await db.taxonomyDao.insertCategory(
      id: 'cat-filters',
      name: 'Filters',
      deviceId: deviceId,
    );
    final pin = PinService(db.settingsDao);
    await pin.setPin('1234');

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('Catalog'));
    await tester.pumpAndSettle();
    expect(find.text('Filters'), findsOneWidget);

    await tester.tap(_navLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change PIN'));
    await tester.pumpAndSettle();
    await _openPinAndType1234(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Editor PIN'), findsNothing);
    expect(find.text('New PIN'), findsOneWidget);
    expect(find.text('Confirm PIN'), findsOneWidget);
  });

  testWidgets('wrong PIN stays on the unlock dialog', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);
    await pin.setPin('1234');

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('Catalog'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Editor PIN'), findsOneWidget);
    await tester.enterText(_pinField(), '0000');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('Wrong PIN'), findsOneWidget);
    expect(find.text('Editor PIN'), findsOneWidget);
    expect(pin.isUnlocked, isFalse);
  });

  testWidgets('Reset cancel does not wipe local data', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);
    var wiped = false;

    await _pumpShell(
      tester,
      db: db,
      pin: pin,
      deviceId: deviceId,
      wipeLocalData: () async => wiped = true,
    );
    await tester.tap(_navLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset / wipe all data'));
    await tester.pumpAndSettle();

    expect(find.text('Wipe all local data?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(wiped, isFalse);
    expect(find.text('Wipe all local data?'), findsNothing);
  });

  testWidgets('Reset confirm wipes local data', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);
    var wiped = false;

    await _pumpShell(
      tester,
      db: db,
      pin: pin,
      deviceId: deviceId,
      wipeLocalData: () async => wiped = true,
    );
    await tester.tap(_navLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset / wipe all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Wipe everything'));
    await tester.pumpAndSettle();
    expect(wiped, isTrue);
  });

  testWidgets('More shows backup date and source device', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    await db.settingsDao.setSetting(
      kLastBackupAtKey,
      '2026-09-13T20:15:00.000Z',
    );
    await db.settingsDao.setSetting(kLastBackupSourceKey, 'dev-source-1');
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('More'));
    await tester.pumpAndSettle();

    expect(find.text('Backup & restore'), findsOneWidget);
    expect(find.textContaining('dev-source-1'), findsOneWidget);
    expect(find.textContaining('2026-09-13'), findsOneWidget);

    await tester.tap(find.text('Backup & restore'));
    await tester.pumpAndSettle();
    expect(find.text('Last backup'), findsOneWidget);
    expect(find.text('Export encrypted backup'), findsOneWidget);
    expect(find.text('Restore encrypted backup'), findsOneWidget);
  });
}
