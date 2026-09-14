import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

const _uiProofDir =
    '/cursor/stores/bc-82e549ff-8c25-41db-9ad2-2135db82353f/media/catalog-empty-bootstrap';

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
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    AppScope(
      db: db,
      pin: pin,
      deviceId: deviceId,
      wipeLocalData: wipeLocalData ?? () async {},
      child: const RepaintBoundary(
        child: MaterialApp(home: HomeShell()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _dumpUi(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final dir = Directory(_uiProofDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final found = find.byType(RepaintBoundary);
    expect(found, findsWidgets);
    final boundary = tester.renderObject(found.first) as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.25);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _openCatalogNewPart(WidgetTester tester, String name) async {
  await tester.tap(_navLabel('Catalog'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
  await typeDialogName(tester, name);
  expect(find.text('Part'), findsWidgets);
}

Future<void> _expandFolder(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).first);
  await tester.tap(find.text(label).first);
  await tester.pumpAndSettle();
}

Future<void> _addNamedFolder(
  WidgetTester tester, {
  required String tooltip,
  required String name,
}) async {
  await tester.ensureVisible(find.byTooltip(tooltip));
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
  await typeDialogName(tester, name);
}

Future<void> _fileEmptyShopTree(WidgetTester tester) async {
  await _openCatalogNewPart(tester, 'Decora GFI');
  await _addNamedFolder(tester, tooltip: 'Add Category', name: 'Outlet');
  await _addNamedFolder(tester, tooltip: 'Add Type', name: 'Decora');
  await _addNamedFolder(tester, tooltip: 'Add Variant', name: 'GFI');
  await tester.tap(find.widgetWithText(TextButton, 'Save'));
  await tester.pumpAndSettle();
  expect(find.text('Saved'), findsOneWidget);
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
    await _dumpUi(tester, '00-empty-catalog');

    await tester.tap(find.byTooltip('New part'));
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
    await _expandFolder(tester, 'Outlet');
    expect(find.text('Decora'), findsOneWidget);
    await _expandFolder(tester, 'Decora');
    expect(find.text('GFI'), findsWidgets);
    await _expandFolder(tester, 'GFI');
    expect(find.text('Decora GFI'), findsOneWidget);
    await _dumpUi(tester, '00b-catalog-tree-expanded');
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

  testWidgets('cannot add type before category', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await _openCatalogNewPart(tester, 'Skip category');

    await tester.ensureVisible(find.byTooltip('Add Type'));
    await tester.tap(find.byTooltip('Add Type'));
    await tester.pumpAndSettle();
    expect(find.text('Set Category first'), findsOneWidget);
  });

  testWidgets('category alone is not enough to save', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await _openCatalogNewPart(tester, 'Outlet only');
    await _addNamedFolder(tester, tooltip: 'Add Category', name: 'Outlet');

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Category, Type, and Variant are required'), findsOneWidget);
  });

  testWidgets('PIN still gates in-place folder create', (WidgetTester tester) async {
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
    await _openPinAndType1234(tester);
    await typeDialogName(tester, 'Gated');

    await tester.ensureVisible(find.byTooltip('Add Category'));
    await tester.tap(find.byTooltip('Add Category'));
    await tester.pumpAndSettle();
    expect(find.text('Editor PIN'), findsNothing);
    await typeDialogName(tester, 'Outlet');
    expect(find.text('Outlet'), findsWidgets);
  });

  testWidgets('in-place brand variance and supplier listing on empty shop',
      (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await _fileEmptyShopTree(tester);
    await _dumpUi(tester, '01-empty-shop-tree-filed');

    expect(find.text('Add variance'), findsWidgets);
    await tester.tap(find.text('Add variance').first);
    await tester.pumpAndSettle();
    expect(find.text('Add brand'), findsOneWidget);
    await typeDialogName(tester, 'Leviton');

    expect(find.text('Add variance'), findsWidgets);
    final varianceFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(varianceFields.at(0), 'White');
    await tester.enterText(varianceFields.at(1), 'R50-W');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Leviton'), findsWidgets);
    expect(find.text('White · R50-W'), findsOneWidget);

    expect(find.text('Add listing'), findsWidgets);
    await tester.tap(find.text('Add listing').first);
    await tester.pumpAndSettle();
    expect(find.text('Add supplier'), findsOneWidget);
    await typeDialogName(tester, 'SupplyHouse');

    expect(find.text('Add supplier listing'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'SH-100',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('SupplyHouse'), findsWidgets);
    expect(find.text('SKU SH-100'), findsOneWidget);

    await tester.ensureVisible(find.text('Default supplier'));
    expect(find.text('None'), findsWidgets);
    await _dumpUi(tester, '02-brand-supplier-in-place');
  });

  testWidgets('maintenance category is selectable on the part editor',
      (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await tester.tap(_navLabel('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maintenance'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add category'));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'Switch');
    expect(find.text('Switch'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await _openCatalogNewPart(tester, 'Toggle');
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Switch').hitTestable(), findsWidgets);
  });

  testWidgets('job picker can take a part filed from an empty shop',
      (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await db.jobsDao.insertJob(
      id: newId(),
      name: 'Shop job',
      deviceId: deviceId,
    );
    await _pumpShell(tester, db: db, pin: pin, deviceId: deviceId);
    await _fileEmptyShopTree(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Outlet'), findsOneWidget);
    await _dumpUi(tester, '03-catalog-tree-after-first-part');

    await tester.tap(_navLabel('Jobs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shop job'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add line'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pick from catalog tree'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a part'), findsOneWidget);

    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.decoration?.hintText == 'Search the tree'),
      ),
      'Decora GFI',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decora GFI').last);
    await tester.pumpAndSettle();

    expect(find.text('Decora GFI'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Decora GFI'), findsOneWidget);
    await _dumpUi(tester, '05-job-line-picked');
  });

  testWidgets('wiped empty shop can still bootstrap the tree',
      (WidgetTester tester) async {
    final first = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(first.close);
    final deviceId = await first.settingsDao.ensureDeviceId();
    final pin = PinService(first.settingsDao);

    await _pumpShell(tester, db: first, pin: pin, deviceId: deviceId);
    await _fileEmptyShopTree(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Outlet'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    final wiped = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(wiped.close);
    final wipedId = await wiped.settingsDao.ensureDeviceId();
    final wipedPin = PinService(wiped.settingsDao);
    await _pumpShell(tester, db: wiped, pin: wipedPin, deviceId: wipedId);
    await tester.tap(_navLabel('Catalog'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No folders or parts yet'), findsOneWidget);
    await _dumpUi(tester, '04-wiped-empty-shop');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await typeDialogName(tester, 'Decora GFI');
    await _addNamedFolder(tester, tooltip: 'Add Category', name: 'Outlet');
    await _addNamedFolder(tester, tooltip: 'Add Type', name: 'Decora');
    await _addNamedFolder(tester, tooltip: 'Add Variant', name: 'GFI');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
  });
}
