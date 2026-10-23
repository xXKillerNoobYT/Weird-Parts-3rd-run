import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

class _PhotoPaths extends PathProviderPlatform {
  _PhotoPaths(this.support);

  final Directory support;

  @override
  Future<String?> getApplicationSupportPath() async => support.path;
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  for (final entry in ['Catalog', 'Maintenance']) {
    final recoveryEntry = entry == 'Catalog' ? 'Maintenance' : 'Catalog';
    testWidgets(
      '$entry focused variance resumes raw input through $recoveryEntry defaults after normal exit',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync(
          'variance-draft-',
        );
        final previousPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _PhotoPaths(directory);
        addTearDown(() => PathProviderPlatform.instance = previousPaths);
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
        EditDrafts drafts() => EditDrafts(db: db, pin: pin, deviceId: deviceId);

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

        final defaultBrand = await maintenance().createBrand('A default brand');
        final selectedBrand = await maintenance().createBrand('Z chosen brand');
        final originalMainId = await catalog().createBrandVersion(
          partId: fixture.partId,
          brandId: selectedBrand,
          mpn: 'ORIGINAL-MAIN',
          varianceName: 'Original main',
          isMain: true,
        );
        await catalog().createBrandVersion(
          partId: fixture.partId,
          brandId: selectedBrand,
          mpn: 'PRESERVED-OPTION',
          varianceName: 'Preserved option',
        );
        await catalog().createBrandVersion(
          partId: fixture.partId,
          brandId: defaultBrand,
          mpn: 'OTHER-BRAND-MAIN',
          varianceName: 'Other brand main',
          isMain: true,
        );
        final part = (await catalog().getPart(fixture.partId))!;
        final otherPartId = await catalog().createGeneralPart(
          name: 'Other preserved part',
          categoryId: part.categoryId!,
          styleId: part.styleId!,
          typeId: part.typeId!,
        );
        await catalog().createBrandVersion(
          partId: otherPartId,
          brandId: selectedBrand,
          mpn: 'OTHER-PART-MAIN',
          varianceName: 'Other part main',
          isMain: true,
        );
        final supplierId = await maintenance().createSupplier('Kept supplier');
        await catalog().createSupplierListing(
          brandVersionId: originalMainId,
          supplierId: supplierId,
          sku: 'PRESERVED-SKU',
        );
        await JobsRepository(db, deviceId).createJob('Preserved Job');
        await fixture.repo.recordCount(fixture.draft());
        final photos = Directory('${directory.path}/part_photos');
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
        final originalPhotoBytes = photo.readAsBytesSync();
        final originalVersions = await db.select(db.brandVersions).get();

        const pendingJobName = '  Unrelated pending Job  ';
        const pendingPartName = '  Unrelated pending New Part  ';
        final seedDrafts = drafts();
        final jobSession =
            (await seedDrafts.openNewJob() as FreshEdit<NewJobEditSession>)
                .session;
        jobSession.replace(const NewJobInput(nameText: pendingJobName));
        await jobSession.leave(LeaveIntent.back);
        final partSession =
            (await seedDrafts.openNewPart() as FreshEdit<NewPartEditSession>)
                .session;
        partSession.replace(
          NewPartInput(
            nameText: pendingPartName,
            categoryId: part.categoryId,
            styleId: part.styleId,
            typeId: part.typeId,
          ),
        );
        await partSession.leave(LeaveIntent.back);
        await seedDrafts.quiesce(StorageChange.exit);
        await pin.setPin('1234');
        final initialRecords = await businessRecords();
        final initialSettings = await db.select(db.appSettings).get();

        Future<void> checkOtherDrafts() async {
          final edits = drafts();
          final jobOpening = await edits.openNewJob();
          expect(jobOpening, isA<RecoverableEdit<NewJobEditSession>>());
          final job = await (jobOpening as RecoverableEdit<NewJobEditSession>)
              .resume();
          expect(job.initial.nameText, pendingJobName);
          await job.leave(LeaveIntent.back);
          final partOpening = await edits.openNewPart();
          expect(partOpening, isA<RecoverableEdit<NewPartEditSession>>());
          final pendingPart =
              await (partOpening as RecoverableEdit<NewPartEditSession>)
                  .resume();
          expect(pendingPart.initial.nameText, pendingPartName);
          expect(
            (
              pendingPart.initial.categoryId,
              pendingPart.initial.styleId,
              pendingPart.initial.typeId,
            ),
            (part.categoryId, part.styleId, part.typeId),
          );
          await pendingPart.leave(LeaveIntent.back);
          await edits.quiesce(StorageChange.exit);
        }

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

        Future<void> unlock({bool refuseWrongPin = false}) async {
          if (pin.isUnlocked) return;
          expect(find.text('Editor PIN'), findsOneWidget);
          expect(_field('Variance (color / option)'), findsNothing);
          if (refuseWrongPin) {
            await tester.enterText(_field('PIN'), '0000');
            await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
            await tester.pumpAndSettle();
            expect(find.text('Wrong PIN'), findsOneWidget);
            expect(pin.isUnlocked, isFalse);
            expect(_field('Variance (color / option)'), findsNothing);
            expect(await businessRecords(), initialRecords);
            expect(await db.select(db.appSettings).get(), initialSettings);
          }
          await tester.enterText(_field('PIN'), '1234');
          await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
          await tester.pump();
          expect(pin.isUnlocked, isTrue);
        }

        Future<void> waitForPhotoPart() async {
          await tester.runAsync(() async {
            final wait = Stopwatch()..start();
            while (_field('Name').evaluate().isEmpty &&
                wait.elapsed < const Duration(seconds: 3)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump(const Duration(milliseconds: 20));
            }
          });
          expect(_field('Name'), findsOneWidget);
          expect(
            tester
                .widgetList<Image>(find.byType(Image))
                .where(
                  (image) =>
                      image.image is FileImage &&
                      (image.image as FileImage).file.path == photo.path,
                ),
            hasLength(1),
          );
          await tester.pumpAndSettle();
        }

        Future<void> enterVariance(
          String surface, {
          bool focused = false,
          bool refuseWrongPin = false,
        }) async {
          if (surface == 'Catalog') {
            await tester.tap(find.text('Catalog'));
          } else {
            await tester.tap(find.text('More').last);
            await tester.pumpAndSettle();
            await tester.tap(find.text('Maintenance'));
          }
          await tester.pumpAndSettle();
          for (final path in [
            ('Synthetic category', 'Synthetic type'),
            ('Synthetic type', 'Synthetic variant'),
            ('Synthetic variant', 'Counted part'),
            if (focused) ('Counted part', 'Z chosen brand'),
          ]) {
            if (find.text(path.$2).evaluate().isEmpty) {
              await tester.ensureVisible(find.text(path.$1).first);
              await tester.tap(find.text(path.$1).first);
              await tester.pumpAndSettle();
            }
          }
          final tile = find
              .ancestor(
                of: find
                    .text(focused ? 'Z chosen brand' : 'Counted part')
                    .first,
                matching: find.byType(ExpansionTile),
              )
              .first;
          await tester.ensureVisible(tile);
          await tester.tap(
            find
                .descendant(
                  of: tile,
                  matching: find.byType(PopupMenuButton<String>),
                )
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(focused ? 'Add variance' : 'Edit part'));
          await tester.pump();
          if (!pin.isUnlocked) {
            await tester.pumpAndSettle();
            await unlock(refuseWrongPin: refuseWrongPin);
          }
          await waitForPhotoPart();
          expect(find.byType(PartDetailPage), findsOneWidget);
          if (!focused) {
            final add = find.widgetWithText(TextButton, 'Add variance').first;
            await tester.ensureVisible(add);
            await tester.tap(add);
            await tester.pumpAndSettle();
          }
        }

        Finder brandField() => find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.byType(DropdownButtonFormField<String>),
        );
        Finder mainSwitch() => find.widgetWithText(SwitchListTile, 'Main');
        String rawText(String label) =>
            tester.widget<TextField>(_field(label)).controller!.text;

        await pumpApp();
        await enterVariance(entry, focused: true, refuseWrongPin: true);
        expect(find.text('Resume'), findsNothing);
        expect(
          tester.state<FormFieldState<String>>(brandField()).value,
          selectedBrand,
        );
        expect(tester.widget<SwitchListTile>(mainSwitch()).value, isFalse);
        const rawVariance = '  White · pending / exact  ';
        const rawMpn = '  MPN · pending / exact  ';
        await tester.enterText(
          _field('Variance (color / option)'),
          rawVariance,
        );
        await tester.enterText(_field('Part number'), rawMpn);
        await tester.tap(mainSwitch());
        await tester.pumpAndSettle();
        expect(rawText('Variance (color / option)'), rawVariance);
        expect(rawText('Part number'), rawMpn);
        expect(tester.widget<SwitchListTile>(mainSwitch()).value, isTrue);
        expect(await businessRecords(), initialRecords);

        await reopenStore();
        expect(await businessRecords(), initialRecords);
        expect(photo.readAsBytesSync(), originalPhotoBytes);
        await enterVariance(recoveryEntry);
        await checkOtherDrafts();
        expect(
          find.text('Resume'),
          findsOneWidget,
          reason:
              'Variance input must offer explicit recovery after normal exit',
        );
        expect(_field('Variance (color / option)'), findsNothing);
        expect(await businessRecords(), initialRecords);
        await tester.tap(find.text('Resume'));
        await tester.pumpAndSettle();
        expect(rawText('Variance (color / option)'), rawVariance);
        expect(rawText('Part number'), rawMpn);
        expect(
          tester.state<FormFieldState<String>>(brandField()).value,
          selectedBrand,
        );
        expect(tester.widget<SwitchListTile>(mainSwitch()).value, isTrue);
        expect(await businessRecords(), initialRecords);

        await tester.tap(find.widgetWithText(FilledButton, 'Add').last);
        await tester.pumpAndSettle();
        final versions = await db.select(db.brandVersions).get();
        expect(versions, hasLength(originalVersions.length + 1));
        final created = versions.singleWhere(
          (row) => !originalVersions.any((old) => old.id == row.id),
        );
        expect(created.id, isNotEmpty);
        expect(created.partId, fixture.partId);
        expect(created.brandId, selectedBrand);
        expect(created.varianceName, rawVariance.trim());
        expect(created.mpn, rawMpn.trim());
        expect(created.isMain, isTrue);
        expect(created.originDeviceId, deviceId);
        expect(created.revision, 1);
        expect(created.deletedAt, isNull);
        for (final original in originalVersions) {
          final saved = versions.singleWhere((row) => row.id == original.id);
          expect(
            saved,
            original.id == originalMainId
                ? original.copyWith(
                    isMain: false,
                    revision: original.revision + 1,
                    modifiedAt: saved.modifiedAt,
                  )
                : original,
          );
        }
        final savedLabel = find.text(
          '${rawVariance.trim()} · ${rawMpn.trim()}',
        );
        await tester.ensureVisible(savedLabel);
        expect(savedLabel.hitTestable(), findsOneWidget);
        final savedRecords = await businessRecords();
        expect(
          Map.of(savedRecords)..remove(db.brandVersions.actualTableName),
          Map.of(initialRecords)..remove(db.brandVersions.actualTableName),
        );
        expect(photo.readAsBytesSync(), originalPhotoBytes);
        await checkOtherDrafts();

        await reopenStore();
        expect(await businessRecords(), savedRecords);
        expect(await db.select(db.brandVersions).get(), versions);
        await enterVariance(entry, focused: true);
        expect(find.text('Resume'), findsNothing);
        expect(rawText('Variance (color / option)'), isEmpty);
        expect(rawText('Part number'), isEmpty);
        expect(tester.widget<SwitchListTile>(mainSwitch()).value, isFalse);

        if (entry == 'Catalog') {
          await tester.enterText(
            _field('Variance (color / option)'),
            '  Outer variance to cancel  ',
          );
          await tester.enterText(_field('Part number'), '  CANCELLED-MPN  ');
          await tester.tap(find.widgetWithText(TextButton, 'Add brand'));
          await tester.pumpAndSettle();
          final name = find.descendant(
            of: find.byType(AlertDialog).last,
            matching: _field('Name'),
          );
          await tester.enterText(name, '  Independent inline brand  ');
          await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
          await tester.pumpAndSettle();
          final child = (await maintenance().listBrands()).singleWhere(
            (brand) => brand.name == 'Independent inline brand',
          );
          expect(
            tester.state<FormFieldState<String>>(brandField()).value,
            child.id,
          );
          expect(rawText('Part number'), '  CANCELLED-MPN  ');
          expect(await db.select(db.brandVersions).get(), versions);
        }
        final beforeCancel = await businessRecords();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
        await tester.pumpAndSettle();
        expect(await businessRecords(), beforeCancel);
        await reopenStore();
        expect(await businessRecords(), beforeCancel);
        expect(await db.select(db.brandVersions).get(), versions);
        expect(photo.readAsBytesSync(), originalPhotoBytes);
        await enterVariance(recoveryEntry);
        expect(find.text('Resume'), findsNothing);
        expect(rawText('Variance (color / option)'), isEmpty);
        expect(rawText('Part number'), isEmpty);
        await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
        await tester.pumpAndSettle();
        await checkOtherDrafts();
        expect(await businessRecords(), beforeCancel);
      },
    );
  }
}
