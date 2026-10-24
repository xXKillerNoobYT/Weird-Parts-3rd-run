import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets(
    'existing variance listing resumes nondefault Supplier and raw SKU after normal close',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'supplier-listing-draft-',
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

      CatalogRepository catalog() => CatalogRepository(db, pin, deviceId);

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

      final maintenance = MaintenanceRepository(db, pin, deviceId);
      final defaultSupplier = await maintenance.createSupplier(
        'Default supplier',
      );
      final selectedSupplier = await maintenance.createSupplier(
        'Alternate supplier',
      );
      expect(selectedSupplier, isNot(defaultSupplier));
      final brand = await maintenance.createBrand('Listing brand');
      final version = await catalog().createBrandVersion(
        partId: fixture.partId,
        brandId: brand,
        mpn: 'LISTING-MPN',
        varianceName: 'Existing variance',
        isMain: true,
      );
      final part = (await catalog().getPart(fixture.partId))!;
      await catalog().updatePart(
        partId: part.id,
        name: part.name,
        description: part.description,
        specs: part.specs,
        uom: part.uom,
        defaultSupplierId: defaultSupplier,
        active: part.active,
        categoryId: part.categoryId,
        styleId: part.styleId,
        typeId: part.typeId,
      );
      await pin.setPin('1234');
      final initialRecords = await businessRecords();

      Future<void> pumpApp() async {
        await tester.pumpWidget(
          WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
        );
        await tester.pumpAndSettle();
      }

      Future<void> openPartEditor() async {
        await tester.tap(find.text('Catalog'));
        await tester.pumpAndSettle();
        for (final path in [
          ('Synthetic category', 'Synthetic type'),
          ('Synthetic type', 'Synthetic variant'),
          ('Synthetic variant', part.name),
        ]) {
          if (find.text(path.$2).evaluate().isEmpty) {
            await tester.ensureVisible(find.text(path.$1).first);
            await tester.tap(find.text(path.$1).first);
            await tester.pumpAndSettle();
          }
        }
        final tile = find
            .ancestor(
              of: find.text(part.name).first,
              matching: find.byType(ListTile),
            )
            .first;
        await tester.ensureVisible(tile);
        await tester.tap(
          find.descendant(
            of: tile,
            matching: find.byType(PopupMenuButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit part'));
        await tester.pumpAndSettle();
        expect(pin.isUnlocked, isFalse);
        expect(find.text('Editor PIN'), findsOneWidget);
        await tester.enterText(_field('PIN'), '1234');
        await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
        await tester.pumpAndSettle();
        expect(find.byType(PartDetailPage), findsOneWidget);
        expect(find.text('Resume'), findsNothing);
        expect(find.text('Existing variance · LISTING-MPN'), findsOneWidget);
      }

      Future<void> openListing() async {
        final add = find.widgetWithText(TextButton, 'Add listing');
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        expect(add.hitTestable(), findsOneWidget);
        await tester.tap(add);
        await tester.pumpAndSettle();
      }

      Finder supplierField() => find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(DropdownButtonFormField<String>),
      );

      String? selectedSupplierId() =>
          tester.state<FormFieldState<String>>(supplierField()).value;

      String rawSku() =>
          tester.widget<TextField>(_field('SKU (optional)')).controller!.text;

      await pumpApp();
      await openPartEditor();
      await openListing();
      expect(find.text('Add supplier listing'), findsOneWidget);
      expect(selectedSupplierId(), defaultSupplier);
      expect(await db.select(db.supplierListings).get(), isEmpty);
      await tester.tap(supplierField());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alternate supplier').last);
      await tester.pumpAndSettle();
      const pendingSku = '  Listing · SKU-42 / pending  ';
      await tester.enterText(_field('SKU (optional)'), pendingSku);
      await tester.pumpAndSettle();
      expect(selectedSupplierId(), selectedSupplier);
      expect(rawSku(), pendingSku);
      expect(await db.select(db.supplierListings).get(), isEmpty);
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
      expect(pin.isUnlocked, isFalse);
      expect(await db.select(db.supplierListings).get(), isEmpty);
      expect(await businessRecords(), initialRecords);
      await pumpApp();
      await openPartEditor();
      await openListing();

      expect(
        find.text('Resume'),
        findsOneWidget,
        reason: 'An unfinished existing-variance listing needs explicit Resume',
      );
      expect(_field('SKU (optional)'), findsNothing);
      expect(await db.select(db.supplierListings).get(), isEmpty);
      expect(await businessRecords(), initialRecords);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(find.text('Add supplier listing'), findsOneWidget);
      expect(selectedSupplierId(), selectedSupplier);
      expect(rawSku(), pendingSku);
      expect(await db.select(db.supplierListings).get(), isEmpty);
      expect(await businessRecords(), initialRecords);

      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      final listing = (await db.select(db.supplierListings).get()).single;
      expect(listing.id, isNotEmpty);
      expect(listing.brandVersionId, version);
      expect(listing.supplierId, selectedSupplier);
      expect(listing.sku, pendingSku.trim());
      expect(listing.revision, 1);
      final otherInitial = Map.of(initialRecords)
        ..remove(db.supplierListings.actualTableName);
      final otherSaved = (await businessRecords())
        ..remove(db.supplierListings.actualTableName);
      expect(otherSaved, otherInitial);
    },
  );
}
