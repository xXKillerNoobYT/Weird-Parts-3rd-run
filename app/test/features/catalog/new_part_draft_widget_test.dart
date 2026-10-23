import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/catalog/part_details_dialog.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  for (final entry in ['Catalog', 'Maintenance']) {
    final recoveryEntry = entry == 'Catalog' ? 'Maintenance' : 'Catalog';
    testWidgets(
      '$entry New part resumes raw name and hierarchy through $recoveryEntry after normal close',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('new-part-draft-');
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
        MaintenanceRepository maintenance() =>
            MaintenanceRepository(db, pin, deviceId);

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

        final categoryId = await maintenance().createCategory('Draft category');
        final styleId = await maintenance().createStyle(
          categoryId: categoryId,
          name: 'Draft type',
        );
        final typeId = await maintenance().createType(
          styleId: styleId,
          name: 'Draft variant',
        );
        final supplierId = await maintenance().createSupplier(
          'Preserved supplier',
        );
        final brandId = await maintenance().createBrand('Preserved brand');
        final brandVersionId = await catalog().createBrandVersion(
          partId: fixture.partId,
          brandId: brandId,
          mpn: 'PRESERVED-MPN',
          varianceName: 'Preserved variance',
        );
        await catalog().createSupplierListing(
          brandVersionId: brandVersionId,
          supplierId: supplierId,
          sku: 'PRESERVED-SKU',
        );
        final photos = Directory('${directory.path}/photos');
        final image = img.Image(width: 8, height: 8);
        img.fill(image, color: img.ColorRgb8(20, 80, 140));
        final photoPath = (await tester.runAsync(
          () => catalog().attachPhoto(
            partId: fixture.partId,
            bytes: Uint8List.fromList(img.encodePng(image)),
            root: photos,
          ),
        ))!;
        final photo = File('${photos.path}/$photoPath');
        final initialPhotoBytes = photo.readAsBytesSync();
        await pin.setPin('1234');

        Future<void> pumpApp() async {
          await tester.pumpWidget(
            WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
          );
          await tester.pumpAndSettle();
        }

        Future<void> reopenStore() async {
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
          await pumpApp();
        }

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

        Future<void> expandToVariant(
          String category,
          String type,
          String variant,
        ) async {
          for (final path in [(category, type), (type, variant)]) {
            if (find.text(path.$2).evaluate().isEmpty) {
              await tester.ensureVisible(find.text(path.$1).first);
              await tester.tap(find.text(path.$1).first);
              await tester.pumpAndSettle();
            }
          }
        }

        Future<void> openNewPart(
          String surface, {
          bool refuseWrongPin = false,
        }) async {
          if (surface == 'Catalog') {
            await tester.tap(find.byTooltip('New part'));
          } else {
            await expandToVariant(
              'Synthetic category',
              'Synthetic type',
              'Synthetic variant',
            );
            final variant = find
                .ancestor(
                  of: find.text('Synthetic variant').first,
                  matching: find.byType(ExpansionTile),
                )
                .first;
            await tester.ensureVisible(variant);
            await tester.tap(
              find
                  .descendant(
                    of: variant,
                    matching: find.byType(PopupMenuButton<String>),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('Add part'));
          }
          await tester.pumpAndSettle();
          if (!pin.isUnlocked) {
            expect(find.text('Editor PIN'), findsOneWidget);
            expect(find.byType(PartDetailsDialog), findsNothing);
            if (refuseWrongPin) {
              final before = await businessRecords();
              await tester.enterText(_field('PIN'), '0000');
              await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
              await tester.pumpAndSettle();
              expect(find.text('Wrong PIN'), findsOneWidget);
              expect(pin.isUnlocked, isFalse);
              expect(find.byType(PartDetailsDialog), findsNothing);
              expect(await businessRecords(), before);
            }
            await tester.enterText(_field('PIN'), '1234');
            await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
            await tester.pumpAndSettle();
            expect(pin.isUnlocked, isTrue);
          }
        }

        Finder hierarchyField(int index) => find
            .descendant(
              of: find.byType(PartDetailsDialog),
              matching: find.byType(DropdownButtonFormField<String>),
            )
            .at(index);

        List<String?> selectedHierarchy() => [
          for (var index = 0; index < 3; index++)
            tester.state<FormFieldState<String>>(hierarchyField(index)).value,
        ];

        String rawName() =>
            tester.widget<TextField>(_field('Part name')).controller!.text;

        await pumpApp();
        await tester.tap(find.byTooltip('New job'));
        await tester.pumpAndSettle();
        await tester.enterText(_field('Name'), '  Unrelated pending Job  ');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        const unrelatedKey = 'local_edit_v1/job-new/input';
        final unrelatedDraft = await db.settingsDao.getSetting(unrelatedKey);
        expect(unrelatedDraft, isNotNull);
        expect(await db.select(db.jobs).get(), isEmpty);
        await openTree(entry);
        final initialRecords = await businessRecords();
        final initialParts = await db.select(db.parts).get();
        expect(initialParts, hasLength(1));
        await openNewPart(entry, refuseWrongPin: true);
        expect(find.byType(PartDetailsDialog), findsOneWidget);
        expect(find.text('Resume'), findsNothing);

        const pendingName = '  New Part · pending / exact  ';
        await tester.enterText(_field('Part name'), pendingName);
        for (final choice in [
          (0, 'Draft category'),
          (1, 'Draft type'),
          (2, 'Draft variant'),
        ]) {
          await tester.tap(hierarchyField(choice.$1));
          await tester.pumpAndSettle();
          await tester.tap(find.text(choice.$2).last);
          await tester.pumpAndSettle();
        }
        expect(rawName(), pendingName);
        expect(selectedHierarchy(), [categoryId, styleId, typeId]);
        expect(await businessRecords(), initialRecords);

        await reopenStore();
        expect(await businessRecords(), initialRecords);
        expect(photo.readAsBytesSync(), initialPhotoBytes);
        expect(await db.settingsDao.getSetting(unrelatedKey), unrelatedDraft);
        await openTree(recoveryEntry);
        await openNewPart(recoveryEntry);
        expect(
          find.text('Resume'),
          findsOneWidget,
          reason:
              'New Part input must offer explicit recovery across tree entry points',
        );
        expect(_field('Part name'), findsNothing);
        expect(await businessRecords(), initialRecords);
        await tester.tap(find.text('Resume'));
        await tester.pumpAndSettle();
        expect(rawName(), pendingName);
        expect(selectedHierarchy(), [categoryId, styleId, typeId]);
        expect(await businessRecords(), initialRecords);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        final parts = await db.select(db.parts).get();
        expect(parts, hasLength(2));
        final created = parts.singleWhere((part) => part.id != fixture.partId);
        expect(created.name, pendingName.trim());
        expect(
          (created.categoryId, created.styleId, created.typeId),
          (categoryId, styleId, typeId),
        );
        expect(created.originDeviceId, deviceId);
        expect(created.revision, 1);
        expect(created.deletedAt, isNull);
        expect(
          parts.singleWhere((part) => part.id == fixture.partId),
          initialParts.single,
        );
        final initialOthers = Map.of(initialRecords)
          ..remove(db.parts.actualTableName);
        final savedRecords = await businessRecords();
        final savedOthers = Map.of(savedRecords)
          ..remove(db.parts.actualTableName);
        expect(savedOthers, initialOthers);
        expect(photo.readAsBytesSync(), initialPhotoBytes);
        expect(await db.settingsDao.getSetting(unrelatedKey), unrelatedDraft);

        if (recoveryEntry == 'Maintenance') {
          expect(find.byType(PartDetailPage), findsNothing);
          await expandToVariant('Draft category', 'Draft type', 'Draft variant');
          await tester.tap(find.text('Draft variant').first);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(created.name).first);
          await tester.tap(find.text(created.name).first);
          await tester.pumpAndSettle();
        }
        expect(find.byType(PartDetailPage), findsOneWidget);
        expect(
          tester.widget<TextField>(_field('Name')).controller!.text,
          created.name,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        await openNewPart(recoveryEntry);
        expect(find.text('Resume'), findsNothing);
        expect(rawName(), isEmpty);

        if (entry == 'Catalog') {
          const laterName = '  Later unfinished New Part  ';
          await tester.enterText(_field('Part name'), laterName);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await openNewPart(recoveryEntry);
          expect(find.text('Resume'), findsOneWidget);
          await tester.tap(find.text('Resume'));
          await tester.pumpAndSettle();
          expect(rawName(), laterName);
          await tester.tap(find.text('Add Category'));
          await tester.pumpAndSettle();
          await tester.enterText(
            _field('Name'),
            '  Independently saved category  ',
          );
          await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
          await tester.pumpAndSettle();
          expect(rawName(), laterName);
          expect(
            (await maintenance().listCategories()).where(
              (category) => category.name == 'Independently saved category',
            ),
            hasLength(1),
          );
        }
        final beforeCancel = await businessRecords();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(await businessRecords(), beforeCancel);
        expect(await db.settingsDao.getSetting(unrelatedKey), unrelatedDraft);
        await reopenStore();
        expect(await businessRecords(), beforeCancel);
        expect(await db.select(db.parts).get(), parts);
        expect(photo.readAsBytesSync(), initialPhotoBytes);
        expect(await db.settingsDao.getSetting(unrelatedKey), unrelatedDraft);
        await openTree(entry);
        await openNewPart(entry);
        expect(find.text('Resume'), findsNothing);
        expect(rawName(), isEmpty);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(await businessRecords(), beforeCancel);
      },
    );
  }
}
