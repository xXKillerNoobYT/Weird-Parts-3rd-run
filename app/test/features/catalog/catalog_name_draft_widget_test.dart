import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/catalog/part_details_dialog.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

void main() {
  testWidgets(
    'unfinished category name resumes exactly after normal close and reopen',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'catalog-name-draft-',
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

      Future<void> openCategoryPrompt() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Maintenance'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add category'));
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
      await openCategoryPrompt();

      const rawName = '  Category · pending  ';
      await tester.enterText(nameField(), rawName);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      final initialCategories = await MaintenanceRepository(
        db,
        pin,
        deviceId,
      ).listCategories();
      expect(initialCategories, hasLength(1));

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
      await openCategoryPrompt();

      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(nameField(), findsOneWidget);
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(
        (await MaintenanceRepository(
          db,
          pin,
          deviceId,
        ).listCategories()).map((category) => category.name),
        initialCategories.map((category) => category.name),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      expect(
        (await MaintenanceRepository(db, pin, deviceId).listCategories()).where(
          (category) => category.name == 'Category · pending',
        ),
        hasLength(1),
      );
      expect(await db.select(db.categories).get(), hasLength(2));
    },
  );

  testWidgets(
    'Maintenance creates a Type and Variant and renames all three under their saved parents',
    (tester) async {
      final fixture = await WarehouseFixture.create();
      final categoryId =
          (await fixture.db.select(fixture.db.categories).get()).single.id;
      addTearDown(fixture.db.close);
      await tester.pumpWidget(
        WiredPartsApp(
          db: fixture.db,
          pin: fixture.pin,
          deviceId: fixture.device,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('More').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maintenance'));
      await tester.pumpAndSettle();

      Finder nameField() => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Name',
      );

      Future<void> openNodeMenu(
        String label, {
        String? parent,
        String? rootParent,
      }) async {
        if (find.text(label).hitTestable().evaluate().isEmpty &&
            parent != null) {
          if (rootParent != null &&
              find.text(parent).hitTestable().evaluate().isEmpty) {
            await tester.tap(find.text(rootParent).first);
            await tester.pumpAndSettle();
          }
          if (find.text(label).hitTestable().evaluate().isEmpty) {
            await tester.tap(find.text(parent).first);
            await tester.pumpAndSettle();
          }
        }
        final tile = find
            .ancestor(
              of: find.text(label).first,
              matching: find.byType(ExpansionTile),
            )
            .first;
        await tester.tap(
          find
              .descendant(
                of: tile,
                matching: find.byType(PopupMenuButton<String>),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Synthetic category').first);
      await tester.pumpAndSettle();
      await openNodeMenu('Synthetic category');
      await tester.tap(find.text('Add type'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Added type  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      expect(find.text('Type saved: Added type').hitTestable(), findsOneWidget);
      expect(
        (await fixture.db.taxonomyDao.listStyles(categoryId: categoryId))
            .where((type) => type.name == 'Added type'),
        hasLength(1),
      );

      await openNodeMenu('Added type', parent: 'Synthetic category');
      await tester.tap(find.text('Add variant'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Added variant  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      await openNodeMenu('Added type', parent: 'Synthetic category');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Renamed type  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      await openNodeMenu(
        'Added variant',
        parent: 'Renamed type',
        rootParent: 'Synthetic category',
      );
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Renamed variant  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      await openNodeMenu('Synthetic category');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Renamed category  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      expect(
        (await fixture.db.taxonomyDao.listStyles()).map((row) => row.name),
        contains('Renamed type'),
      );
      expect(
        (await fixture.db.taxonomyDao.listCategories()).map((row) => row.name),
        contains('Renamed category'),
      );
      expect(
        (await fixture.db.taxonomyDao.listTypes()).map((row) => row.name),
        contains('Renamed variant'),
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Catalog'));
      await tester.pumpAndSettle();
      await openNodeMenu('Renamed category');
      await tester.tap(find.text('Add type'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Catalog type  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      await openNodeMenu('Catalog type', parent: 'Renamed category');
      await tester.tap(find.text('Add variant'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Catalog variant  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      await openNodeMenu(
        'Catalog variant',
        parent: 'Catalog type',
        rootParent: 'Renamed category',
      );
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), '  Renamed in Catalog  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Variant saved: Renamed in Catalog').hitTestable(),
        findsOneWidget,
      );
      expect(
        (await fixture.db.taxonomyDao.listTypes()).map((row) => row.name),
        contains('Renamed in Catalog'),
      );
    },
  );

  testWidgets(
    'PartDetailPage keeps raw Part fields while taxonomy children commit independently',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await WarehouseFixture.create();
      final edits = EditDrafts(
        db: fixture.db,
        pin: fixture.pin,
        deviceId: fixture.device,
      );
      addTearDown(fixture.db.close);
      final original = (await fixture.catalog.getPart(fixture.partId))!;

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
      Finder nameField(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      Finder taxonomyNameField() => find
          .byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == 'Name',
          )
          .last;

      const rawPartName = '  Unfinished Part name  ';
      const rawDescription = '  preserve this description  ';
      await tester.enterText(nameField('Name'), rawPartName);
      await tester.enterText(nameField('Description'), rawDescription);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add Category'));
      await tester.tap(find.text('Add Category'));
      await tester.pumpAndSettle();
      await tester.enterText(taxonomyNameField(), '  Inline category  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Add Type'));
      await tester.tap(find.text('Add Type'));
      await tester.pumpAndSettle();
      await tester.enterText(taxonomyNameField(), '  Inline type  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Add Variant'));
      await tester.tap(find.text('Add Variant'));
      await tester.pumpAndSettle();
      await tester.enterText(taxonomyNameField(), '  Inline variant  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Variant saved: Inline variant').hitTestable(),
        findsOneWidget,
      );

      expect(
        tester.widget<TextField>(nameField('Name').first).controller!.text,
        rawPartName,
      );
      expect(
        tester.widget<TextField>(nameField('Description')).controller!.text,
        rawDescription,
      );
      final partDraft = await fixture.db.settingsDao.getSetting(
        'local_edit_v1/part/${Uri.encodeComponent(fixture.partId)}/input',
      );
      final input =
          (jsonDecode(partDraft!) as Map<String, Object?>)['input']
              as Map<String, Object?>;
      expect(input['name'], rawPartName);
      expect(input['description'], rawDescription);
      final category = (await fixture.db.taxonomyDao.listCategories())
          .singleWhere((row) => row.name == 'Inline category');
      final type = (await fixture.db.taxonomyDao.listStyles()).singleWhere(
        (row) => row.name == 'Inline type',
      );
      final variant = (await fixture.db.taxonomyDao.listTypes()).singleWhere(
        (row) => row.name == 'Inline variant',
      );
      expect(input['category'], category.id);
      expect(input['style'], type.id);
      expect(input['type'], variant.id);
      expect(type.categoryId, category.id);
      expect(variant.styleId, type.id);
      expect(
        await fixture.db
            .customSelect(
              "SELECT key FROM app_settings "
              "WHERE key LIKE 'local_edit_v1/catalog-name-%'",
            )
            .get(),
        isEmpty,
      );
      final storedPart = await fixture.catalog.getPart(fixture.partId);
      expect(
        (storedPart!.name, storedPart.description),
        (original.name, original.description),
      );
      expect(
        (await fixture.db.taxonomyDao.listCategories()).where(
          (row) => row.name == 'Inline category',
        ),
        hasLength(1),
      );
      expect(
        (await fixture.db.taxonomyDao.listStyles()).where(
          (row) => row.name == 'Inline type',
        ),
        hasLength(1),
      );
      expect(
        (await fixture.db.taxonomyDao.listTypes()).where(
          (row) => row.name == 'Inline variant',
        ),
        hasLength(1),
      );
      expect(await fixture.catalog.listParts(), hasLength(1));
    },
  );

  testWidgets(
    'PartDetailsDialog retains its parent fields while inline Category, Type, and Variant save',
    (tester) async {
      final fixture = await WarehouseFixture.create();
      final edits = EditDrafts(
        db: fixture.db,
        pin: fixture.pin,
        deviceId: fixture.device,
      );
      addTearDown(fixture.db.close);
      final job = await JobsRepository(
        fixture.db,
        fixture.device,
      ).createJob('Taxonomy promotion');
      final parent = (await edits.openJobLine(
        job,
      ) as FreshEdit<JobLineEditSession>).session;
      parent.replace(
        JobLineInput(
          useCustom: true,
          partId: null,
          brandVersionId: null,
          customNameText: 'Parent',
          neededText: '09.50',
          pullText: '02.0',
          customNotes: null,
          uom: null,
          notes: null,
          splits: const [],
        ),
      );
      final promotion = await parent.openPromotion();
      await tester.pumpWidget(
        AppScope(
          db: fixture.db,
          pin: fixture.pin,
          deviceId: fixture.device,
          edits: edits,
          wipeLocalData: () async {},
          restoreFromBackup: (_, _) async {},
          child: MaterialApp(
            home: PartDetailsDialog.promotion(
              promotion: promotion,
              maintenance: MaintenanceRepository(
                fixture.db,
                fixture.pin,
                fixture.device,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder taxonomyNameField() => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Name',
      );

      const rawPartName = '  New Part parent text  ';
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'Part name',
        ),
        rawPartName,
      );
      for (final operation in [
        ('Add Category', 'Part dialog category'),
        ('Add Type', 'Part dialog type'),
        ('Add Variant', 'Part dialog variant'),
      ]) {
        await tester.ensureVisible(find.text(operation.$1));
        await tester.tap(find.text(operation.$1));
        await tester.pumpAndSettle();
        await tester.enterText(taxonomyNameField(), '  ${operation.$2}  ');
        await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is TextField &&
                      widget.decoration?.labelText == 'Part name',
                ),
              )
              .controller!
              .text,
          rawPartName,
        );
      }
      expect(promotion.initial.nameText, rawPartName);
      expect(parent.initial.neededText, '09.50');
      await promotion.flush();
      final parentRows = await fixture.db
          .customSelect(
            "SELECT value FROM app_settings WHERE key LIKE 'local_edit_v1/job-line-new/%/input'",
          )
          .get();
      final persisted =
          jsonDecode(parentRows.single.read<String>('value')) as Map;
      final nested = (persisted['input'] as Map)['promotion'] as Map;
      expect((nested['details'] as Map)['name'], rawPartName);
      expect((nested['details'] as Map)['type'], promotion.initial.typeId);
      expect(
        find.text('Variant saved: Part dialog variant').hitTestable(),
        findsOneWidget,
      );
      expect(await fixture.catalog.listParts(), hasLength(1));
      expect(
        (await fixture.db.taxonomyDao.listCategories()).where(
          (row) => row.name == 'Part dialog category',
        ),
        hasLength(1),
      );
      expect(
        (await fixture.db.taxonomyDao.listStyles()).where(
          (row) => row.name == 'Part dialog type',
        ),
        hasLength(1),
      );
      expect(
        (await fixture.db.taxonomyDao.listTypes()).where(
          (row) => row.name == 'Part dialog variant',
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'saved Category receipt survives Close and Done acknowledges only the exact saved row',
    (tester) async {
      final fixture = await WarehouseFixture.create();
      addTearDown(fixture.db.close);
      final edits = EditDrafts(
        db: fixture.db,
        pin: fixture.pin,
        deviceId: fixture.device,
      );
      const target = CatalogNameTarget.newCategory();
      final session = (await edits.openCatalogName(
        target,
      ) as FreshEdit<CatalogNameEditSession>).session;
      session.replace(const CatalogNameInput(nameText: 'Receipt category'));
      await session.flush();
      final saved = await session.save();
      final receiptKey = 'local_edit_v1/catalog-name-new/category/control';
      expect(
        (await fixture.db.select(fixture.db.categories).get()).where(
          (row) => row.id == saved.id,
        ),
        hasLength(1),
      );

      await tester.pumpWidget(
        WiredPartsApp(
          db: fixture.db,
          pin: fixture.pin,
          deviceId: fixture.device,
        ),
      );
      await tester.pumpAndSettle();
      Future<void> openCategoryPrompt() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Maintenance'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add category'));
        await tester.pumpAndSettle();
      }

      await openCategoryPrompt();
      expect(find.text('Name saved'), findsOneWidget);
      expect(find.text('Saved Receipt category'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(await fixture.db.settingsDao.getSetting(receiptKey), isNotNull);

      await tester.tap(find.byTooltip('Add category'));
      await tester.pumpAndSettle();
      expect(find.text('Name saved'), findsOneWidget);
      expect(find.text('Saved Receipt category'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();
      expect(await fixture.db.settingsDao.getSetting(receiptKey), isNull);
      expect(
        (await fixture.db.select(fixture.db.categories).get()).where(
          (row) => row.id == saved.id,
        ),
        hasLength(1),
      );
    },
  );
  testWidgets(
    'failed promotion taxonomy adoption preserves its independent completion until durable retry',
    (tester) async {
      final fixture = await WarehouseFixture.create();
      addTearDown(fixture.db.close);
      final edits = EditDrafts(
        db: fixture.db,
        pin: fixture.pin,
        deviceId: fixture.device,
      );
      final job = await JobsRepository(
        fixture.db,
        fixture.device,
      ).createJob('Taxonomy retry');
      final parent = (await edits.openJobLine(
        job,
      ) as FreshEdit<JobLineEditSession>).session;
      parent.replace(
        JobLineInput(
          useCustom: true,
          partId: null,
          brandVersionId: null,
          customNameText: 'Parent',
          neededText: '09.50',
          pullText: '02.0',
          customNotes: null,
          uom: null,
          notes: null,
          splits: const [],
        ),
      );
      final promotion = await parent.openPromotion();
      await tester.pumpWidget(
        AppScope(
          db: fixture.db,
          pin: fixture.pin,
          deviceId: fixture.device,
          edits: edits,
          wipeLocalData: () async {},
          restoreFromBackup: (_, _) async {},
          child: MaterialApp(
            home: PartDetailsDialog.promotion(
              promotion: promotion,
              maintenance: MaintenanceRepository(
                fixture.db,
                fixture.pin,
                fixture.device,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Category'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Name',
        ),
        'Independent saved category',
      );
      await fixture.db.customStatement(
        "CREATE TRIGGER reject_adoption BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/job-line%/input' BEGIN SELECT RAISE(ABORT, 'adoption failure'); END",
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      final saved = (await fixture.db.taxonomyDao.listCategories()).singleWhere(
        (row) => row.name == 'Independent saved category',
      );
      const key = 'local_edit_v1/catalog-name-new/category/control';
      final receipt = await fixture.db.settingsDao.getSetting(key);
      expect(receipt, isNotNull);
      expect((jsonDecode(receipt!) as Map)['phase'], 'committed');
      expect(find.textContaining('Refresh pending'), findsOneWidget);
      expect(parent.initial.neededText, '09.50');
      await fixture.db.customStatement('DROP TRIGGER reject_adoption');
      await tester.ensureVisible(find.text('Add Category'));
      await tester.tap(find.text('Add Category'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await tester.pumpAndSettle();
      expect(promotion.initial.categoryId, saved.id);
      expect(await fixture.db.settingsDao.getSetting(key), isNull);
      final parentRows = await fixture.db
          .customSelect(
            "SELECT value FROM app_settings WHERE key LIKE 'local_edit_v1/job-line-new/%/input'",
          )
          .get();
      final raw = jsonDecode(parentRows.single.read<String>('value')) as Map;
      final nested = (raw['input'] as Map)['promotion'] as Map;
      expect((nested['details'] as Map)['category'], saved.id);
      await promotion.cancel();
      expect(
        (await fixture.db.taxonomyDao.listCategories()).any(
          (row) => row.id == saved.id,
        ),
        true,
      );
      expect(parent.initial.neededText, '09.50');
      expect(tester.takeException(), isNull);
    },
  );
}
