import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

void main() {
  for (final entry in ['Catalog', 'Maintenance']) {
    final recoveryEntry = entry == 'Catalog' ? 'Maintenance' : 'Catalog';
    testWidgets(
      '$entry Edit part resumes every raw field through $recoveryEntry after normal close',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync(
          'tree-part-editor-',
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

        CatalogRepository catalog() => CatalogRepository(db, pin, deviceId);

        Future<void> openTree(String surface) async {
          if (surface == 'Catalog') {
            await tester.tap(find.text('Catalog'));
          } else {
            await tester.tap(find.text('More').last);
            await tester.pumpAndSettle();
            await tester.tap(find.text('Maintenance'));
          }
          await tester.pumpAndSettle();
        }

        Future<void> openPartEditor(String partName) async {
          for (final path in [
            ('Synthetic category', 'Synthetic type'),
            ('Synthetic type', 'Synthetic variant'),
            ('Synthetic variant', partName),
          ]) {
            if (find.text(path.$2).evaluate().isEmpty) {
              await tester.ensureVisible(find.text(path.$1).first);
              await tester.tap(find.text(path.$1).first);
              await tester.pumpAndSettle();
            }
          }
          final partTile = find
              .ancestor(
                of: find.text(partName).first,
                matching: find.byType(ListTile),
              )
              .first;
          await tester.ensureVisible(partTile);
          await tester.tap(
            find.descendant(
              of: partTile,
              matching: find.byType(PopupMenuButton<String>),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Edit part'));
          await tester.pumpAndSettle();
        }

        Finder field(String label) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
        );

        String fieldText(String label) =>
            tester.widget<TextField>(field(label)).controller!.text;

        final maintenance = MaintenanceRepository(db, pin, deviceId);
        final supplierId = await maintenance.createSupplier('Linked supplier');
        final brandId = await maintenance.createBrand('Linked brand');
        final versionId = await catalog().createBrandVersion(
          partId: fixture.partId,
          brandId: brandId,
          mpn: 'PRESERVED-MPN',
          varianceName: 'Preserved variance',
        );
        await catalog().createSupplierListing(
          brandVersionId: versionId,
          supplierId: supplierId,
          sku: 'PRESERVED-SKU',
        );
        final fixturePart = (await catalog().getPart(fixture.partId))!;
        const rawDescription = '  Stored description · pending  ';
        const rawUom = '  box  ';
        await catalog().updatePart(
          partId: fixturePart.id,
          name: fixturePart.name,
          description: rawDescription,
          specs: 'Stored specifications',
          uom: rawUom,
          defaultSupplierId: supplierId,
          active: fixturePart.active,
          categoryId: fixturePart.categoryId,
          styleId: fixturePart.styleId,
          typeId: fixturePart.typeId,
        );
        final originalPart = (await catalog().getPart(fixture.partId))!;
        await pumpApp();
        await openTree(entry);
        final initialRecords = await businessRecords();
        await openPartEditor(originalPart.name);
        expect(find.text('Resume'), findsNothing);
        expect(fieldText('Description'), rawDescription);
        expect(fieldText('Unit of measure'), rawUom);
        const rawName = '  Part · pending  ';
        const rawSpecs = '  Specs · pending\nexact  ';
        await tester.enterText(field('Name'), rawName);
        await tester.enterText(field('Description'), rawDescription);
        await tester.enterText(field('Specifications'), rawSpecs);
        await tester.enterText(field('Unit of measure'), rawUom);
        await tester.pumpAndSettle();
        expect(fieldText('Name'), rawName);
        expect(fieldText('Description'), rawDescription);
        expect(fieldText('Specifications'), rawSpecs);
        expect(fieldText('Unit of measure'), rawUom);
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
        await openTree(recoveryEntry);
        await openPartEditor(originalPart.name);

        expect(find.text('Resume'), findsOneWidget);
        expect(field('Name'), findsNothing);
        expect(await businessRecords(), initialRecords);
        await tester.tap(find.text('Resume'));
        await tester.pumpAndSettle();
        expect(fieldText('Name'), rawName);
        expect(fieldText('Description'), rawDescription);
        expect(fieldText('Specifications'), rawSpecs);
        expect(fieldText('Unit of measure'), rawUom);
        expect(await businessRecords(), initialRecords);

        await tester.tap(find.widgetWithText(TextButton, 'Save'));
        await tester.pumpAndSettle();
        final savedPart = (await catalog().getPart(fixture.partId))!;
        expect(
          savedPart,
          originalPart.copyWith(
            name: rawName.trim(),
            description: rawDescription.trim(),
            specs: rawSpecs,
            uom: rawUom.trim(),
            revision: originalPart.revision + 1,
            modifiedAt: savedPart.modifiedAt,
          ),
        );
        final initialOtherRecords = Map.of(initialRecords)
          ..remove(db.parts.actualTableName);
        final savedRecords = await businessRecords();
        final savedOtherRecords = Map.of(savedRecords)
          ..remove(db.parts.actualTableName);
        expect(savedOtherRecords, initialOtherRecords);
        expect(await db.select(db.parts).get(), hasLength(1));
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text(rawName.trim()).hitTestable(), findsOneWidget);
        expect(find.text(originalPart.name), findsNothing);
        await openPartEditor(rawName.trim());
        expect(find.text('Resume'), findsNothing);
        expect(fieldText('Name'), rawName.trim());
        expect(fieldText('Description'), rawDescription.trim());
        expect(fieldText('Specifications'), rawSpecs);
        expect(fieldText('Unit of measure'), rawUom.trim());

        if (entry == 'Catalog') {
          const nextRawName = '  Later unfinished Part name  ';
          await tester.enterText(field('Name'), nextRawName);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(await businessRecords(), savedRecords);
          await openPartEditor(rawName.trim());
          expect(find.text('Resume'), findsOneWidget);
          await tester.tap(find.text('Resume'));
          await tester.pumpAndSettle();
          expect(fieldText('Name'), nextRawName);
          await tester.tap(find.widgetWithText(TextButton, 'Discard'));
          await tester.pumpAndSettle();
          expect(await businessRecords(), savedRecords);
          await openPartEditor(rawName.trim());
          expect(find.text('Resume'), findsNothing);
          expect(fieldText('Name'), rawName.trim());
        }
      },
    );
  }
}
