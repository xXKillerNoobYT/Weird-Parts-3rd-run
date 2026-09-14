import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
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

Future<void> typeDialogName(WidgetTester tester, String name) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    name,
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
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

  testWidgets('empty shop can create nested taxonomy on the first part',
      (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('Catalog'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No folders or parts yet'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'Decora GFI');

    expect(find.text('Part'), findsWidgets);

    await tester.ensureVisible(find.byTooltip('Add Category'));
    await tester.tap(find.byTooltip('Add Category'));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'Outlet');

    await tester.tap(find.byTooltip('Add Type'));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'Decora');

    await tester.tap(find.byTooltip('Add Variant'));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'GFI');

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Outlet'), findsOneWidget);
    expect(find.text('Decora'), findsOneWidget);
    expect(find.text('GFI'), findsWidgets);
  });

  testWidgets('part save without taxonomy is rejected', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('Catalog'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'Unfiled');

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Category, Type, and Variant are required'), findsOneWidget);
  });

  testWidgets('cannot add variant before type', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('Catalog'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'Skip type');

    await tester.ensureVisible(find.byTooltip('Add Variant'));
    await tester.tap(find.byTooltip('Add Variant'));
    await tester.pumpAndSettle();
    expect(find.text('Set Type first'), findsOneWidget);
  });
}
