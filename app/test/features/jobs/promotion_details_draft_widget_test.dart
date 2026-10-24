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
import 'package:wired_parts/features/catalog/part_details_dialog.dart';
import 'package:wired_parts/features/catalog/tree_edit_prompts.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/jobs/job_line_editor.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

enum _Entry { savedCustomLine, freshAddLine }

enum _Outcome { recoverAndPromote, cancelNested }

class _PhotoPaths extends PathProviderPlatform {
  _PhotoPaths(this.support);

  final Directory support;

  @override
  Future<String?> getApplicationSupportPath() async => support.path;
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder _picker(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is TaxonomyPickField && widget.label == label,
  ),
  matching: find.byType(DropdownButtonFormField<String>),
);

void main() {
  for (final entry in _Entry.values) {
    for (final outcome in _Outcome.values) {
      final entryName = entry == _Entry.savedCustomLine
          ? 'saved custom line'
          : 'fresh Add line';
      final behavior = outcome == _Outcome.recoverAndPromote
          ? 'recovers exact nested promotion input after parent Resume and promotes once'
          : 'nested Cancel preserves parent input and independently saved taxonomy';
      testWidgets('$entryName $behavior', (tester) async {
        tester.view.physicalSize = const Size(1100, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync(
          'promotion-details-draft-',
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
        JobsRepository jobs() => JobsRepository(db, deviceId);
        EditDrafts edits() => EditDrafts(db: db, pin: pin, deviceId: deviceId);

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

        Future<List<AppSetting>> stableSettings() async =>
            (await db.select(db.appSettings).get())
                .where((row) => !row.key.startsWith(editDraftPrefix))
                .toList();

        final categoryId = await maintenance().createCategory(
          'Chosen category',
        );
        final styleId = await maintenance().createStyle(
          categoryId: categoryId,
          name: 'Chosen type',
        );
        final typeId = await maintenance().createType(
          styleId: styleId,
          name: 'Chosen variant',
        );
        final supplierId = await maintenance().createSupplier('Kept supplier');
        final brandId = await maintenance().createBrand('Kept brand');
        final versionId = await catalog().createBrandVersion(
          partId: fixture.partId,
          brandId: brandId,
          mpn: 'KEPT-MPN',
        );
        await catalog().createSupplierListing(
          brandVersionId: versionId,
          supplierId: supplierId,
          sku: 'KEPT-SKU',
        );
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
        const jobName = 'Nested promotion recovery Job';
        const savedCustomName = 'Original saved custom line';
        final jobId = await jobs().createJob(jobName);
        final String? originalLineId;
        if (entry == _Entry.savedCustomLine) {
          originalLineId = await jobs().addLine(
            jobId: jobId,
            customName: savedCustomName,
            customNotes: 'Kept custom notes',
            uom: 'ea',
            notes: 'Kept line notes',
            neededQty: 3,
            shopPullQty: 1,
            splits: [(supplierId: supplierId, qty: 2)],
          );
        } else {
          originalLineId = null;
        }
        final unrelatedJobId = await jobs().createJob('Kept unrelated Job');
        await jobs().addLine(
          jobId: unrelatedJobId,
          partId: fixture.partId,
          brandVersionId: versionId,
          neededQty: 4,
          splits: [(supplierId: supplierId, qty: 2)],
        );
        final originalParts = await db.select(db.parts).get();
        final unrelatedLines = (await db.select(db.jobLines).get())
            .where((row) => row.id != originalLineId)
            .toList();
        final unrelatedSplits = (await db.select(db.orderSplits).get())
            .where((row) => row.jobLineId != originalLineId)
            .toList();
        const unrelatedJobName = '  Other unfinished Job · exact  ';
        const unrelatedPartName = '  Other unfinished Part · exact  ';
        final pending = edits();
        final pendingJob =
            (await pending.openNewJob() as FreshEdit<NewJobEditSession>)
                .session;
        pendingJob.replace(const NewJobInput(nameText: unrelatedJobName));
        await pendingJob.leave(LeaveIntent.back);
        final pendingPart =
            (await pending.openNewPart() as FreshEdit<NewPartEditSession>)
                .session;
        pendingPart.replace(
          NewPartInput(
            nameText: unrelatedPartName,
            categoryId: categoryId,
            styleId: styleId,
            typeId: typeId,
          ),
        );
        await pendingPart.leave(LeaveIntent.back);
        await pending.quiesce(StorageChange.exit);
        await pin.setPin('1234');
        var initialRecords = await businessRecords();
        final initialSettings = await stableSettings();
        const rawCustomName = '  Parent custom · different name  ';
        const rawPartName = '  Nested catalog Part · exact / raw  ';
        const rawNeeded = '09.50';
        const rawShop = '02.0';
        const rawSplit = '07.50';

        String rawText(String label) =>
            tester.widget<TextField>(_field(label)).controller!.text;

        Future<void> checkUnrelatedDrafts() async {
          final other = edits();
          final jobOpening = await other.openNewJob();
          expect(jobOpening, isA<RecoverableEdit<NewJobEditSession>>());
          final job = await (jobOpening as RecoverableEdit<NewJobEditSession>)
              .resume();
          expect(job.initial.nameText, unrelatedJobName);
          await job.leave(LeaveIntent.back);
          final partOpening = await other.openNewPart();
          expect(partOpening, isA<RecoverableEdit<NewPartEditSession>>());
          final part =
              await (partOpening as RecoverableEdit<NewPartEditSession>)
                  .resume();
          expect(part.initial.nameText, unrelatedPartName);
          expect(
            (
              part.initial.categoryId,
              part.initial.styleId,
              part.initial.typeId,
            ),
            (categoryId, styleId, typeId),
          );
          await part.leave(LeaveIntent.back);
          await other.quiesce(StorageChange.exit);
        }

        Future<void> checkNoBusinessWrites() async {
          expect(await businessRecords(), initialRecords);
          expect(await stableSettings(), initialSettings);
          expect(photo.readAsBytesSync(), originalPhotoBytes);
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

        Future<void> openParent({
          bool resume = false,
          String? savedName,
        }) async {
          await tester.tap(find.text(jobName));
          await tester.pumpAndSettle();
          if (savedName != null) {
            await tester.tap(find.text(savedName));
          } else if (entry == _Entry.savedCustomLine) {
            await tester.tap(find.text(savedCustomName));
          } else {
            await tester.tap(find.byTooltip('Add line'));
          }
          await tester.pumpAndSettle();
          expect(find.byType(JobLineEditor), findsOneWidget);
          if (resume) {
            expect(find.text('Resume'), findsOneWidget);
            expect(_field('Requested'), findsNothing);
            await tester.tap(find.text('Resume'));
            await tester.pumpAndSettle();
          }
        }

        void checkParentRaw() {
          expect(rawText('Custom name'), rawCustomName);
          expect(rawText('Requested'), rawNeeded);
          expect(rawText('Shop'), rawShop);
          expect(rawText('Qty'), rawSplit);
          expect(
            tester
                .state<FormFieldState<String?>>(
                  find.byType(DropdownButtonFormField<String?>),
                )
                .value,
            supplierId,
          );
        }

        Future<void> openNested({bool refuseWrongPin = false}) async {
          await tester.ensureVisible(find.text('Promote to catalog'));
          await tester.tap(find.text('Promote to catalog'));
          await tester.pumpAndSettle();
          if (!pin.isUnlocked) {
            expect(find.text('Editor PIN'), findsOneWidget);
            expect(_field('Part name'), findsNothing);
            if (refuseWrongPin) {
              final settingsBeforeRefusal = await db
                  .select(db.appSettings)
                  .get();
              await tester.enterText(_field('PIN'), '0000');
              await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
              await tester.pumpAndSettle();
              expect(find.text('Wrong PIN'), findsOneWidget);
              expect(pin.isUnlocked, isFalse);
              expect(_field('Part name'), findsNothing);
              expect(
                await db.select(db.appSettings).get(),
                settingsBeforeRefusal,
              );
              await checkNoBusinessWrites();
            }
            await tester.enterText(_field('PIN'), '1234');
            await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
            await tester.pumpAndSettle();
            expect(pin.isUnlocked, isTrue);
          }
          expect(find.byType(PartDetailsDialog), findsOneWidget);
        }

        Future<void> choose(String label, String name) async {
          await tester.ensureVisible(_picker(label));
          await tester.tap(_picker(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text(name).last);
          await tester.pumpAndSettle();
        }

        await pumpApp();
        await openParent();
        if (entry == _Entry.freshAddLine) {
          await tester.tap(find.text('Custom'));
          await tester.pumpAndSettle();
        }
        await tester.enterText(_field('Custom name'), rawCustomName);
        await tester.enterText(_field('Requested'), rawNeeded);
        await tester.enterText(_field('Shop'), rawShop);
        final supplier = find.byType(DropdownButtonFormField<String?>);
        await tester.ensureVisible(supplier);
        await tester.tap(supplier);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Kept supplier').last);
        await tester.pumpAndSettle();
        await tester.enterText(_field('Qty'), rawSplit);
        await tester.pumpAndSettle();
        checkParentRaw();
        await checkNoBusinessWrites();
        await openNested(refuseWrongPin: true);
        expect(find.text('Resume'), findsNothing);
        expect(rawText('Part name'), rawCustomName.trim());
        await tester.enterText(_field('Part name'), rawPartName);
        await choose('Category', 'Chosen category');
        await choose('Type', 'Chosen type');
        await choose('Variant', 'Chosen variant');
        expect(rawText('Part name'), rawPartName);
        expect(
          tester.state<FormFieldState<String>>(_picker('Category')).value,
          categoryId,
        );
        expect(
          tester.state<FormFieldState<String>>(_picker('Type')).value,
          styleId,
        );
        expect(
          tester.state<FormFieldState<String>>(_picker('Variant')).value,
          typeId,
        );
        await checkNoBusinessWrites();

        if (outcome == _Outcome.cancelNested) {
          await tester.tap(find.widgetWithText(TextButton, 'Add Variant'));
          await tester.pumpAndSettle();
          await tester.enterText(
            _field('Name'),
            '  Independently saved variant  ',
          );
          await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
          await tester.pumpAndSettle();
          final variant = (await maintenance().listTypes()).singleWhere(
            (row) => row.name == 'Independently saved variant',
          );
          expect(variant.styleId, styleId);
          expect(
            tester.state<FormFieldState<String>>(_picker('Variant')).value,
            variant.id,
          );
          expect(rawText('Part name'), rawPartName);
          final afterTaxonomy = await businessRecords();
          expect(
            Map.of(afterTaxonomy)..remove(db.types.actualTableName),
            Map.of(initialRecords)..remove(db.types.actualTableName),
          );
          initialRecords = afterTaxonomy;
          await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
          await tester.pumpAndSettle();
          checkParentRaw();
          await checkNoBusinessWrites();
        }

        await reopenStore();
        await checkNoBusinessWrites();
        await checkUnrelatedDrafts();
        await openParent(resume: true);
        checkParentRaw();
        await checkNoBusinessWrites();
        await openNested(refuseWrongPin: true);
        if (outcome == _Outcome.cancelNested) {
          expect(find.text('Resume'), findsNothing);
          expect(rawText('Part name'), rawCustomName.trim());
          expect(
            (await maintenance().listTypes()).where(
              (row) => row.name == 'Independently saved variant',
            ),
            hasLength(1),
          );
          await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
          await tester.pumpAndSettle();
          checkParentRaw();
          await checkNoBusinessWrites();
          await checkUnrelatedDrafts();
          return;
        }

        if (find.text('Resume').evaluate().isNotEmpty) {
          await tester.tap(find.text('Resume'));
          await tester.pumpAndSettle();
        }
        expect(
          rawText('Part name'),
          rawPartName,
          reason: 'Nested promotion raw Part name must survive normal exit and parent Resume',
        );
        expect(
          tester.state<FormFieldState<String>>(_picker('Category')).value,
          categoryId,
        );
        expect(
          tester.state<FormFieldState<String>>(_picker('Type')).value,
          styleId,
        );
        expect(
          tester.state<FormFieldState<String>>(_picker('Variant')).value,
          typeId,
        );
        await checkNoBusinessWrites();

        await tester.tap(find.widgetWithText(FilledButton, 'Promote'));
        await tester.pumpAndSettle();
        expect(find.byType(PartDetailsDialog), findsNothing);
        expect(find.text('Promote to catalog'), findsNothing);
        expect(rawText('Requested'), rawNeeded);
        expect(rawText('Shop'), rawShop);
        expect(rawText('Qty'), rawSplit);
        final created = (await db.select(db.parts).get()).singleWhere(
          (row) => row.name == rawPartName.trim(),
        );
        expect(
          (created.categoryId, created.styleId, created.typeId),
          (categoryId, styleId, typeId),
        );
        expect(created.originDeviceId, deviceId);
        expect(created.revision, 1);
        final savedLine = (await jobs().listLinesForJob(jobId)).single;
        if (originalLineId != null) expect(savedLine.id, originalLineId);
        expect(savedLine.partId, created.id);
        expect(savedLine.customName, isNull);
        expect(savedLine.neededQty, 9.5);
        expect(savedLine.shopPullQty, 2);
        if (entry == _Entry.savedCustomLine) {
          expect(savedLine.customNotes, 'Kept custom notes');
          expect(savedLine.notes, 'Kept line notes');
          expect(savedLine.uom, 'ea');
        }
        final savedSplit = (await jobs().orderSplitsForLine(savedLine.id))
            .single;
        expect(savedSplit.supplierId, supplierId);
        expect(savedSplit.quantity, 7.5);
        final savedRecords = await businessRecords();
        expect(
          Map.of(savedRecords)
            ..remove(db.parts.actualTableName)
            ..remove(db.jobLines.actualTableName)
            ..remove(db.orderSplits.actualTableName),
          Map.of(initialRecords)
            ..remove(db.parts.actualTableName)
            ..remove(db.jobLines.actualTableName)
            ..remove(db.orderSplits.actualTableName),
        );
        expect(
          (await db.select(db.parts).get()).where(
            (row) => row.id != created.id,
          ),
          originalParts,
        );
        expect(
          (await db.select(db.jobLines).get()).where(
            (row) => row.id != savedLine.id,
          ),
          unrelatedLines,
        );
        expect(
          (await db.select(db.orderSplits).get()).where(
            (row) => row.jobLineId != savedLine.id,
          ),
          unrelatedSplits,
        );
        await checkUnrelatedDrafts();
        await reopenStore();
        expect(await businessRecords(), savedRecords);
        expect(photo.readAsBytesSync(), originalPhotoBytes);
        expect(await stableSettings(), initialSettings);
        expect(await jobs().getJobLine(savedLine.id), savedLine);
        expect(await jobs().orderSplitsForLine(savedLine.id), [savedSplit]);
        await openParent(savedName: rawPartName.trim());
        if (find.text('Resume').evaluate().isNotEmpty) {
          await tester.tap(find.text('Resume'));
          await tester.pumpAndSettle();
        }
        expect(find.text('Promote to catalog'), findsNothing);
        expect(find.text(rawPartName.trim()), findsOneWidget);
        expect(rawText('Requested'), rawNeeded);
        expect(rawText('Shop'), rawShop);
        expect(rawText('Qty'), rawSplit);
        expect(await businessRecords(), savedRecords);
        await checkUnrelatedDrafts();
      });
    }
  }
}
