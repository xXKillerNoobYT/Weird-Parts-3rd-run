import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

void main() {
  testWidgets(
    'unfinished brand name resumes exactly after normal close and reopen',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'brand-name-draft-',
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

      Future<Map<String, List<Map<String, Object?>>>>
      businessRecords() async => {
        for (final table in db.allTables)
          if (table.actualTableName != db.appSettings.actualTableName)
            table.actualTableName:
                (await db
                        .customSelect(
                          'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
                        )
                        .get())
                    .map((row) => row.data)
                    .toList(),
      };

      Future<void> pumpApp() async {
        await tester.pumpWidget(
          WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
        );
        await tester.pumpAndSettle();
      }

      Future<void> openBrandPrompt() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Maintenance'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Brands'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add'));
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
      await openBrandPrompt();
      expect(find.text('Add brand'), findsOneWidget);
      expect(await db.select(db.brands).get(), isEmpty);
      final initialRecords = await businessRecords();

      const rawName = '  Brand · pending  ';
      await tester.enterText(nameField(), rawName);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(await db.select(db.brands).get(), isEmpty);
      expect(await businessRecords(), initialRecords);

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
      await openBrandPrompt();

      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(find.text('Add brand'), findsOneWidget);
      expect(nameField(), findsOneWidget);
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(await db.select(db.brands).get(), isEmpty);
      expect(await businessRecords(), initialRecords);

      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      final savedBrands = await db.select(db.brands).get();
      expect(savedBrands, hasLength(1));
      final savedBrand = savedBrands.single;
      expect(savedBrand.name, 'Brand · pending');
      expect(savedBrand.id, isNotEmpty);
      final listedBrands = await MaintenanceRepository(
        db,
        pin,
        deviceId,
      ).listBrands();
      expect(listedBrands, hasLength(1));
      expect(listedBrands.single.id, savedBrand.id);
      expect(listedBrands.single.name, 'Brand · pending');
      final remainingRecords = await businessRecords();
      remainingRecords.remove(db.brands.actualTableName);
      final initialOtherRecords = Map.of(initialRecords)
        ..remove(db.brands.actualTableName);
      expect(remainingRecords, initialOtherRecords);
    },
  );

  for (final surface in ['Catalog', 'Maintenance']) {
    testWidgets(
      '$surface tree renames the real brand identity under its composite node',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await WarehouseFixture.create();
        addTearDown(fixture.db.close);
        final maintenance = MaintenanceRepository(
          fixture.db,
          fixture.pin,
          fixture.device,
        );
        final brandId = await maintenance.createBrand('Tree brand');
        await fixture.catalog.createBrandVersion(
          partId: fixture.partId,
          brandId: brandId,
          mpn: 'TREE-1',
          varianceName: 'Original variance',
        );
        final initialBrand =
            (await fixture.db.select(fixture.db.brands).get()).single;
        final initialVersions = await fixture.catalog.listBrandVersionsForPart(
          fixture.partId,
        );
        await tester.pumpWidget(
          WiredPartsApp(
            db: fixture.db,
            pin: fixture.pin,
            deviceId: fixture.device,
          ),
        );
        await tester.pumpAndSettle();
        if (surface == 'Catalog') {
          await tester.tap(find.text('Catalog'));
        } else {
          await tester.tap(find.text('More').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Maintenance'));
        }
        await tester.pumpAndSettle();
        for (final parent in [
          'Synthetic category',
          'Synthetic type',
          'Synthetic variant',
          'Counted part',
        ]) {
          await tester.ensureVisible(find.text(parent).first);
          await tester.tap(find.text(parent).first);
          await tester.pumpAndSettle();
        }
        final brandTile = find
            .ancestor(
              of: find.text('Tree brand').first,
              matching: find.byType(ExpansionTile),
            )
            .first;
        await tester.ensureVisible(brandTile);
        await tester.tap(
          find
              .descendant(
                of: brandTile,
                matching: find.byType(PopupMenuButton<String>),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        final field = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Name',
        );
        expect(tester.widget<TextField>(field).controller!.text, 'Tree brand');
        await tester.enterText(field, '  Renamed tree brand  ');
        await tester.pumpAndSettle();
        final slot =
            'local_edit_v1/catalog-name-rename/brand/${Uri.encodeComponent(brandId)}';
        expect(
          await fixture.db.settingsDao.getSetting('$slot/input'),
          isNotNull,
        );
        expect(
          (await fixture.db.select(fixture.db.brands).get()).single,
          initialBrand,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
        await tester.pumpAndSettle();
        expect(
          find.text('Brand saved: Renamed tree brand').hitTestable(),
          findsOneWidget,
        );
        final renamed =
            (await fixture.db.select(fixture.db.brands).get()).single;
        expect(renamed.id, brandId);
        expect(renamed.name, 'Renamed tree brand');
        expect(renamed.revision, initialBrand.revision + 1);
        expect(renamed.originDeviceId, initialBrand.originDeviceId);
        expect(renamed.createdAt, initialBrand.createdAt);
        expect(
          await fixture.catalog.listBrandVersionsForPart(fixture.partId),
          initialVersions,
        );
        expect(await fixture.db.settingsDao.getSetting('$slot/input'), isNull);
        expect(
          await fixture.db.settingsDao.getSetting('$slot/control'),
          isNull,
        );
      },
    );
  }

  for (final cancelVariance in [false, true]) {
    testWidgets(
      'nested Add Brand preserves variance and Part input before ${cancelVariance ? 'Cancel' : 'Add'}',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await WarehouseFixture.create();
        addTearDown(fixture.db.close);
        final maintenance = MaintenanceRepository(
          fixture.db,
          fixture.pin,
          fixture.device,
        );
        await maintenance.createBrand('Existing brand');
        final originalPart = (await fixture.catalog.getPart(fixture.partId))!;
        final edits = EditDrafts(
          db: fixture.db,
          pin: fixture.pin,
          deviceId: fixture.device,
        );
        await tester.pumpWidget(
          AppScope(
            db: fixture.db,
            pin: fixture.pin,
            deviceId: fixture.device,
            edits: edits,
            wipeLocalData: () async {},
            restoreFromBackup: (_, _) async {},
            child: MaterialApp(home: PartDetailPage(partId: fixture.partId)),
          ),
        );
        await tester.pumpAndSettle();
        Finder field(String label) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
        );
        const rawPartName = '  Part text before nested brand  ';
        const rawDescription = '  Description before nested brand  ';
        const rawVariance = '  White · pending variance  ';
        const rawMpn = '  MPN · pending  ';
        await tester.enterText(field('Name'), rawPartName);
        await tester.enterText(field('Description'), rawDescription);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Add variance'));
        await tester.tap(find.text('Add variance'));
        await tester.pumpAndSettle();
        await tester.enterText(field('Variance (color / option)'), rawVariance);
        await tester.enterText(field('Part number'), rawMpn);
        await tester.tap(find.widgetWithText(TextButton, 'Add brand'));
        await tester.pumpAndSettle();
        final brandName = find.descendant(
          of: find.byType(AlertDialog).last,
          matching: field('Name'),
        );
        await tester.enterText(brandName, '  Nested brand  ');
        await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
        await tester.pumpAndSettle();

        final savedBrand = (await maintenance.listBrands()).singleWhere(
          (brand) => brand.name == 'Nested brand',
        );
        final selectedBrandField = find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.byType(DropdownButtonFormField<String>),
        );
        expect(selectedBrandField, findsOneWidget);
        expect(
          tester
              .state<FormFieldState<String>>(
                selectedBrandField,
              )
              .value,
          savedBrand.id,
        );
        expect(
          find.text('Brand saved: Nested brand').hitTestable(),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextField>(field('Variance (color / option)'))
              .controller!
              .text,
          rawVariance,
        );
        expect(
          tester.widget<TextField>(field('Part number')).controller!.text,
          rawMpn,
        );
        expect(
          await fixture.catalog.listBrandVersionsForPart(fixture.partId),
          isEmpty,
        );
        expect(
          await fixture.db.settingsDao.getSetting(
            'local_edit_v1/catalog-name-new/brand/input',
          ),
          isNull,
        );
        expect(
          await fixture.db.settingsDao.getSetting(
            'local_edit_v1/catalog-name-new/brand/control',
          ),
          isNull,
        );
        if (cancelVariance) {
          await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        } else {
          await tester.tap(find.widgetWithText(FilledButton, 'Add'));
        }
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field('Name')).controller!.text,
          rawPartName,
        );
        expect(
          tester.widget<TextField>(field('Description')).controller!.text,
          rawDescription,
        );
        expect(await fixture.catalog.getPart(fixture.partId), originalPart);
        expect(
          (await maintenance.listBrands()).where(
            (brand) => brand.id == savedBrand.id,
          ),
          hasLength(1),
        );
        final versions = await fixture.catalog.listBrandVersionsForPart(
          fixture.partId,
        );
        if (cancelVariance) {
          expect(versions, isEmpty);
        } else {
          expect(versions, hasLength(1));
          expect(versions.single.brandId, savedBrand.id);
          expect(versions.single.partId, fixture.partId);
          expect(versions.single.mpn, rawMpn.trim());
          expect(versions.single.varianceName, rawVariance.trim());
        }
      },
    );
  }
}
