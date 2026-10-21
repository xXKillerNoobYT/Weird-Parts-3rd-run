import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/warehouse/warehouse_repository.dart';

import 'warehouse_test_support.dart';

void main() {
  testWidgets(
    'unfinished warehouse name resumes exactly after normal close and reopen',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'warehouse-location-draft-',
      );
      final file = File('${directory.path}/synthetic.sqlite');
      final fixture = await WarehouseFixture.create(file: file);
      var db = fixture.db;
      var dbOpen = true;
      var pin = fixture.pin;
      final deviceId = fixture.device;

      addTearDown(
        () => tester.runAsync(() async {
          if (dbOpen) await db.close();
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        }),
      );

      Future<void> pumpApp() async {
        await tester.pumpWidget(
          WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
        );
        await tester.pumpAndSettle();
      }

      Future<void> openNewWarehouse() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Inventory / Warehouses'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New warehouse'));
        await tester.pumpAndSettle();
      }

      Finder nameField() => find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Name',
        ),
      );

      await pumpApp();
      await openNewWarehouse();

      const rawName = '  North bay · pending  ';
      await tester.enterText(nameField(), rawName);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(await fixture.repo.loadLocations(), hasLength(1));

      expect(
        await tester.runAsync(tester.binding.handleRequestAppExit),
        AppExitResponse.exit,
      );
      dbOpen = false;
      await tester.pumpWidget(const SizedBox.shrink());

      db = AppDatabase.forTesting(NativeDatabase(file));
      dbOpen = true;
      pin = PinService(db.settingsDao);
      await pumpApp();
      await openNewWarehouse();

      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(nameField(), findsOneWidget);
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(
        (await WarehouseRepository(
          db,
          pin,
          deviceId,
        ).loadLocations()).map((location) => location.name),
        ['Shop shelf'],
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Warehouse saved: North bay · pending'), findsOneWidget);
      final created =
          (await WarehouseRepository(
            db,
            pin,
            deviceId,
          ).loadLocations()).singleWhere(
            (location) => location.name == 'North bay · pending',
          );
      expect(
        await WarehouseRepository(db, pin, deviceId).loadLocations(),
        hasLength(2),
      );

      expect(
        await tester.runAsync(tester.binding.handleRequestAppExit),
        AppExitResponse.exit,
      );
      dbOpen = false;
      await tester.pumpWidget(const SizedBox.shrink());
      db = AppDatabase.forTesting(NativeDatabase(file));
      dbOpen = true;
      pin = PinService(db.settingsDao);
      await pumpApp();
      await openNewWarehouse();
      expect(find.text('Resume'), findsNothing);
      expect(
        (await WarehouseRepository(db, pin, deviceId).loadLocations()).where(
          (location) => location.name == 'North bay · pending',
        ),
        hasLength(1),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        await WarehouseRepository(db, pin, deviceId).loadLocations(),
        hasLength(2),
      );
      expect(created.id, isNotEmpty);
    },
  );

  testWidgets(
    'unfinished rename resumes after normal close and saves the same location',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'warehouse-location-rename-draft-',
      );
      final file = File('${directory.path}/synthetic.sqlite');
      final fixture = await WarehouseFixture.create(file: file);
      var db = fixture.db;
      var dbOpen = true;
      var pin = fixture.pin;
      final deviceId = fixture.device;
      final locationId = fixture.locationId;
      final count = await fixture.repo.recordCount(
        fixture.draft(quantity: 6.25, note: 'Preserve count history'),
      );

      addTearDown(
        () => tester.runAsync(() async {
          if (dbOpen) await db.close();
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        }),
      );

      Future<void> pumpApp() async {
        await tester.pumpWidget(
          WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
        );
        await tester.pumpAndSettle();
      }

      Future<void> openRename() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Inventory / Warehouses'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Shop shelf'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Rename warehouse'));
        await tester.pumpAndSettle();
      }

      Finder nameField() => find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Name',
        ),
      );

      await pumpApp();
      await openRename();
      const rawName = '  North bay · rename pending  ';
      await tester.enterText(nameField(), rawName);
      await tester.pumpAndSettle();
      expect(
        (await WarehouseRepository(
          db,
          pin,
          deviceId,
        ).loadLocations()).single.name,
        'Shop shelf',
      );

      expect(
        await tester.runAsync(tester.binding.handleRequestAppExit),
        AppExitResponse.exit,
      );
      dbOpen = false;
      await tester.pumpWidget(const SizedBox.shrink());
      db = AppDatabase.forTesting(NativeDatabase(file));
      dbOpen = true;
      pin = PinService(db.settingsDao);
      await pumpApp();
      await openRename();

      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(
        (await WarehouseRepository(
          db,
          pin,
          deviceId,
        ).loadLocations()).single.name,
        'Shop shelf',
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        find.text('Warehouse saved: North bay · rename pending'),
        findsOneWidget,
      );
      final locations = await WarehouseRepository(
        db,
        pin,
        deviceId,
      ).loadLocations();
      expect(locations, hasLength(1));
      expect(locations.single.id, locationId);
      expect(locations.single.name, 'North bay · rename pending');
      expect(locations.single.revision, 2);
      final history = await WarehouseRepository(
        db,
        pin,
        deviceId,
      ).loadCountHistory(locationId, fixture.partId);
      expect(history, hasLength(1));
      expect(history.single.id, count.id);
      expect(history.single.quantity, 6.25);
      await tester.tap(find.byTooltip('Reload counts'));
      await tester.pumpAndSettle();
      expect(find.text('6.25 ea'), findsOneWidget);
    },
  );

  testWidgets(
    'saved receipt Close keeps it pending and Done acknowledges without a duplicate',
    (tester) async {
      final fixture = await WarehouseFixture.create();
      addTearDown(fixture.db.close);
      final edits = EditDrafts(
        db: fixture.db,
        pin: fixture.pin,
        deviceId: fixture.device,
      );
      final session =
          (await edits.openNewWarehouseLocation()
                  as FreshEdit<WarehouseLocationEditSession>)
              .session;
      session.replace(
        const WarehouseLocationNameInput(nameText: 'Saved receipt location'),
      );
      await session.flush();
      final saved = await session.save();
      final controlKey = 'local_edit_v1/warehouse-location-new/control';
      final receipt = await fixture.db.settingsDao.getSetting(controlKey);
      expect(receipt, isNotNull);

      await tester.pumpWidget(
        WiredPartsApp(
          db: fixture.db,
          pin: fixture.pin,
          deviceId: fixture.device,
        ),
      );
      await tester.pumpAndSettle();

      Future<void> openReceipt() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Inventory / Warehouses'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New warehouse'));
        await tester.pumpAndSettle();
      }

      await openReceipt();
      expect(find.text('Warehouse saved'), findsOneWidget);
      expect(find.text('Saved Saved receipt location'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(await fixture.db.settingsDao.getSetting(controlKey), receipt);
      expect(
        (await fixture.repo.loadLocations()).where(
          (row) => row.id == saved.location.id,
        ),
        hasLength(1),
      );

      await tester.tap(find.text('New warehouse'));
      await tester.pumpAndSettle();
      expect(find.text('Warehouse saved'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();
      expect(
        find.text('Warehouse saved: Saved receipt location'),
        findsOneWidget,
      );
      expect(await fixture.db.settingsDao.getSetting(controlKey), isNull);
      expect(
        (await fixture.repo.loadLocations()).where(
          (row) => row.id == saved.location.id,
        ),
        hasLength(1),
      );
    },
  );
}
