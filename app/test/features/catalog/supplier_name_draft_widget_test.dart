import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/jobs/job_line_editor.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _fieldText(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

Future<void> _mountConsumer(
  WidgetTester tester, {
  required AppDatabase db,
  required PinService pin,
  required String device,
  required Widget editor,
}) async {
  tester.view.physicalSize = const Size(1100, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      db: db,
      pin: pin,
      deviceId: device,
      edits: EditDrafts(db: db, pin: pin, deviceId: device),
      wipeLocalData: () async {},
      restoreFromBackup: (_, _) async {},
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => editor)),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
}

Future<void> _saveSupplierName(WidgetTester tester, String raw) async {
  final name = find.descendant(
    of: find.byType(AlertDialog).last,
    matching: _field('Name'),
  );
  await tester.enterText(name, raw);
  await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'unfinished supplier name resumes exactly after normal close and reopen',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'supplier-name-draft-',
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

      Future<void> openSupplierPrompt() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Maintenance'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Suppliers'));
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
      await openSupplierPrompt();
      expect(find.text('Add supplier'), findsOneWidget);
      expect(await db.select(db.suppliers).get(), isEmpty);
      final initialRecords = await businessRecords();

      const rawName = '  Supplier · pending  ';
      await tester.enterText(nameField(), rawName);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(await db.select(db.suppliers).get(), isEmpty);
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
      await openSupplierPrompt();

      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(find.text('Add supplier'), findsOneWidget);
      expect(nameField(), findsOneWidget);
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      expect(await db.select(db.suppliers).get(), isEmpty);
      expect(await businessRecords(), initialRecords);

      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();
      final savedSuppliers = await db.select(db.suppliers).get();
      expect(savedSuppliers, hasLength(1));
      final savedSupplier = savedSuppliers.single;
      expect(savedSupplier.name, 'Supplier · pending');
      expect(savedSupplier.id, isNotEmpty);
      final listedSuppliers = await MaintenanceRepository(
        db,
        pin,
        deviceId,
      ).listSuppliers();
      expect(listedSuppliers, hasLength(1));
      expect(listedSuppliers.single.id, savedSupplier.id);
      expect(listedSuppliers.single.name, 'Supplier · pending');
      expect(
        await db.settingsDao.getSetting(
          'local_edit_v1/catalog-name-new/supplier/input',
        ),
        isNull,
      );
      expect(
        await db.settingsDao.getSetting(
          'local_edit_v1/catalog-name-new/supplier/control',
        ),
        isNull,
      );
      final remainingRecords = await businessRecords();
      remainingRecords.remove(db.suppliers.actualTableName);
      final initialOtherRecords = Map.of(initialRecords)
        ..remove(db.suppliers.actualTableName);
      expect(remainingRecords, initialOtherRecords);
    },
  );

  for (final failParentFlush in [false, true]) {
    testWidgets(
      failParentFlush
          ? 'failed Part adoption flush retains Supplier receipt until actual retry'
          : 'Part default Supplier is durably adopted before its receipt retires',
      (tester) async {
        final fixture = await WarehouseFixture.create();
        addTearDown(fixture.db.close);
        final db = fixture.db;
        final originalPart = (await fixture.catalog.getPart(fixture.partId))!;
        final partKey =
            'local_edit_v1/part/${Uri.encodeComponent(fixture.partId)}/input';
        const controlKey = 'local_edit_v1/catalog-name-new/supplier/control';
        await _mountConsumer(
          tester,
          db: db,
          pin: fixture.pin,
          device: fixture.device,
          editor: PartDetailPage(partId: fixture.partId),
        );
        const rawPart = '  Part before Supplier · exact  ';
        const rawDescription = '  Description before Supplier  ';
        await tester.enterText(_field('Name'), rawPart);
        await tester.enterText(_field('Description'), rawDescription);
        await tester.pumpAndSettle();
        await db.customStatement(
          'CREATE TRIGGER require_durable_supplier_adoption '
          'BEFORE DELETE ON app_settings '
          "WHEN OLD.key = '$controlKey' AND NOT EXISTS ("
          'SELECT 1 FROM app_settings p JOIN suppliers s '
          "ON s.id = json_extract(p.value, '\$.input.supplier') "
          "WHERE p.key = '$partKey' AND s.name = 'Default child supplier') "
          "BEGIN SELECT RAISE(ABORT, 'supplier adoption was not durable'); END",
        );
        if (failParentFlush) {
          await db.customStatement(
            'CREATE TRIGGER reject_supplier_parent_flush '
            'BEFORE UPDATE ON app_settings '
            "WHEN NEW.key = '$partKey' "
            "AND json_extract(NEW.value, '\$.input.supplier') IS NOT NULL "
            "BEGIN SELECT RAISE(ABORT, 'synthetic supplier parent flush failure'); END",
          );
        }
        await tester.ensureVisible(find.text('Add supplier'));
        await tester.tap(find.text('Add supplier'));
        await tester.pumpAndSettle();
        await _saveSupplierName(tester, '  Default child supplier  ');
        final supplier = (await db.select(db.suppliers).get()).single;
        expect(supplier.name, 'Default child supplier');
        expect(await fixture.catalog.getPart(fixture.partId), originalPart);
        if (failParentFlush) {
          final pendingReceipt = await db.settingsDao.getSetting(controlKey);
          expect(pendingReceipt, isNotNull);
          expect((jsonDecode(pendingReceipt!) as Map)['phase'], 'committed');
          expect(
            find.textContaining('Refresh pending:').hitTestable(),
            findsOneWidget,
          );
          final staleParent =
              jsonDecode((await db.settingsDao.getSetting(partKey))!) as Map;
          final staleInput = staleParent['input'] as Map;
          expect(staleInput['name'], rawPart);
          expect(staleInput['description'], rawDescription);
          expect(staleInput['supplier'], isNull);
          await tester.scrollUntilVisible(
            find.text('Default supplier'),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(PartDetailPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
        }
        expect(
          tester
              .state<FormFieldState<String?>>(
                find.byType(DropdownButtonFormField<String?>),
              )
              .value,
          supplier.id,
        );
        if (failParentFlush) {
          await tester.scrollUntilVisible(
            _field('Name'),
            -200,
            scrollable: find
                .descendant(
                  of: find.byType(PartDetailPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
        }
        expect(_fieldText(tester, 'Name'), rawPart);
        expect(_fieldText(tester, 'Description'), rawDescription);
        if (failParentFlush) {
          await db.customStatement('DROP TRIGGER reject_supplier_parent_flush');
          await tester.scrollUntilVisible(
            find.text('Add supplier'),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(PartDetailPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(find.text('Add supplier').hitTestable(), findsOneWidget);
          await tester.tap(find.text('Add supplier'));
          await tester.pumpAndSettle();
          expect(find.text('Name saved'), findsOneWidget);
          await tester.tap(find.widgetWithText(TextButton, 'Done'));
          await tester.pumpAndSettle();
          expect(await db.select(db.suppliers).get(), [supplier]);
        }
        expect(
          find.text('Supplier saved: Default child supplier').hitTestable(),
          findsOneWidget,
        );
        final parent =
            jsonDecode((await db.settingsDao.getSetting(partKey))!) as Map;
        final input = parent['input'] as Map;
        expect(input['name'], rawPart);
        expect(input['description'], rawDescription);
        expect(input['supplier'], supplier.id);
        expect(await db.settingsDao.getSetting(controlKey), isNull);
        expect(
          await db.settingsDao.getSetting(
            'local_edit_v1/catalog-name-new/supplier/input',
          ),
          isNull,
        );
        await db.customStatement(
          'DROP TRIGGER require_durable_supplier_adoption',
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        expect(find.text('Resume'), findsOneWidget);
        await tester.tap(find.text('Resume'));
        await tester.pumpAndSettle();
        expect(_fieldText(tester, 'Name'), rawPart);
        expect(
          tester
              .state<FormFieldState<String?>>(
                find.byType(DropdownButtonFormField<String?>),
              )
              .value,
          supplier.id,
        );
        await tester.tap(find.widgetWithText(TextButton, 'Discard'));
        await tester.pumpAndSettle();
        expect(await fixture.catalog.getPart(fixture.partId), originalPart);
        expect(await db.select(db.suppliers).get(), [supplier]);
      },
    );
  }

  testWidgets(
    'nested listing Supplier preserves live SKU and creates no listing before outer Add',
    (tester) async {
      final fixture = await WarehouseFixture.create();
      addTearDown(fixture.db.close);
      final maintenance = MaintenanceRepository(
        fixture.db,
        fixture.pin,
        fixture.device,
      );
      await maintenance.createSupplier('Existing supplier');
      final brand = await maintenance.createBrand('Listing brand');
      final version = await fixture.catalog.createBrandVersion(
        partId: fixture.partId,
        brandId: brand,
        mpn: 'LISTING-MPN',
      );
      final originalPart = (await fixture.catalog.getPart(fixture.partId))!;
      await _mountConsumer(
        tester,
        db: fixture.db,
        pin: fixture.pin,
        device: fixture.device,
        editor: PartDetailPage(partId: fixture.partId),
      );
      const rawPart = '  Part during nested listing  ';
      const rawSku = '  SKU · live pending  ';
      await tester.enterText(_field('Name'), rawPart);
      expect(find.text('Add listing'), findsOneWidget);
      await tester.ensureVisible(find.text('Add listing'));
      await tester.tap(find.text('Add listing'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('SKU (optional)'), rawSku);
      await tester.tap(find.widgetWithText(TextButton, 'Add supplier').last);
      await tester.pumpAndSettle();
      await _saveSupplierName(tester, '  Nested listing supplier  ');
      final supplier = (await maintenance.listSuppliers()).singleWhere(
        (row) => row.name == 'Nested listing supplier',
      );
      final dropdown = find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(DropdownButtonFormField<String>),
      );
      expect(tester.state<FormFieldState<String>>(dropdown).value, supplier.id);
      expect(_fieldText(tester, 'SKU (optional)'), rawSku);
      expect(
        find.text('Supplier saved: Nested listing supplier').hitTestable(),
        findsOneWidget,
      );
      expect(
        await fixture.db.select(fixture.db.supplierListings).get(),
        isEmpty,
      );
      expect(await fixture.catalog.getPart(fixture.partId), originalPart);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      final listing =
          (await fixture.db.select(fixture.db.supplierListings).get()).single;
      expect(listing.supplierId, supplier.id);
      expect(listing.brandVersionId, version);
      expect(listing.sku, rawSku.trim());
      expect(_fieldText(tester, 'Name'), rawPart);
      expect(await fixture.catalog.getPart(fixture.partId), originalPart);
    },
  );

  testWidgets(
    'live-version split Supplier creates one empty listing and survives parent cold reopen',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('supplier-split-');
      final file = File('${directory.path}/synthetic.sqlite');
      final fixture = await WarehouseFixture.create(file: file);
      var db = fixture.db;
      var pin = fixture.pin;
      var dbOpen = true;
      addTearDown(
        () => tester.runAsync(() async {
          if (dbOpen) await db.close();
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        }),
      );
      final maintenance = MaintenanceRepository(db, pin, fixture.device);
      final brand = await maintenance.createBrand('Split brand');
      final version = await fixture.catalog.createBrandVersion(
        partId: fixture.partId,
        brandId: brand,
        mpn: 'SPLIT-MPN',
      );
      var jobs = JobsRepository(db, fixture.device);
      final job = await jobs.createJob('Supplier split recovery');
      final line = await jobs.addLine(
        jobId: job,
        partId: fixture.partId,
        brandVersionId: version,
        neededQty: 3,
      );
      final originalLine = await jobs.getJobLine(line);
      final originalSplits = await jobs.orderSplitsForLine(line);
      await _mountConsumer(
        tester,
        db: db,
        pin: pin,
        device: fixture.device,
        editor: JobLineEditor(jobId: job, lineId: line),
      );
      const rawRequested = '7.50';
      const rawShop = '1.25';
      const rawQuantity = '6.25';
      await tester.enterText(_field('Requested'), rawRequested);
      await tester.enterText(_field('Shop'), rawShop);
      await tester.enterText(_field('Qty'), rawQuantity);
      await tester.ensureVisible(find.text('Add supplier'));
      await tester.tap(find.text('Add supplier'));
      await tester.pumpAndSettle();
      await _saveSupplierName(tester, '  Split child supplier  ');
      final supplier = (await db.select(db.suppliers).get()).single;
      final listing = (await db.select(db.supplierListings).get()).single;
      expect(supplier.name, 'Split child supplier');
      expect(listing.supplierId, supplier.id);
      expect(listing.brandVersionId, version);
      expect(listing.sku, '');
      expect(
        tester
            .state<FormFieldState<String?>>(
              find.byType(DropdownButtonFormField<String?>),
            )
            .value,
        supplier.id,
      );
      expect(_fieldText(tester, 'Requested'), rawRequested);
      expect(_fieldText(tester, 'Shop'), rawShop);
      expect(_fieldText(tester, 'Qty'), rawQuantity);
      expect(await jobs.getJobLine(line), originalLine);
      expect(await jobs.orderSplitsForLine(line), originalSplits);
      final parentKey =
          'local_edit_v1/job-line/${Uri.encodeComponent(job)}/${Uri.encodeComponent(line)}/input';
      final draftInput =
          (jsonDecode((await db.settingsDao.getSetting(parentKey))!)
                  as Map)['input']
              as Map;
      final input = draftInput['line'] as Map;
      expect(
        ((input['splits'] as List).single as Map)['supplier'],
        supplier.id,
      );
      final supplierSlot =
          'local_edit_v1/catalog-name-new/supplier/version/${Uri.encodeComponent(version)}';
      expect(await db.settingsDao.getSetting('$supplierSlot/control'), isNull);
      expect(await db.settingsDao.getSetting('$supplierSlot/input'), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(db.close);
      dbOpen = false;
      db = AppDatabase.forTesting(NativeDatabase(file));
      dbOpen = true;
      pin = PinService(db.settingsDao);
      jobs = JobsRepository(db, fixture.device);
      await _mountConsumer(
        tester,
        db: db,
        pin: pin,
        device: fixture.device,
        editor: JobLineEditor(jobId: job, lineId: line),
      );
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(_fieldText(tester, 'Requested'), rawRequested);
      expect(_fieldText(tester, 'Shop'), rawShop);
      expect(_fieldText(tester, 'Qty'), rawQuantity);
      expect(
        tester
            .state<FormFieldState<String?>>(
              find.byType(DropdownButtonFormField<String?>),
            )
            .value,
        supplier.id,
      );
      expect(await db.select(db.suppliers).get(), [supplier]);
      expect(await db.select(db.supplierListings).get(), [listing]);
      expect(await jobs.getJobLine(line), originalLine);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      final savedLine = (await jobs.getJobLine(line))!;
      expect(savedLine.id, line);
      expect(savedLine.partId, fixture.partId);
      expect(savedLine.brandVersionId, version);
      expect(savedLine.neededQty, 7.5);
      expect(savedLine.shopPullQty, 1.25);
      final savedSplit = (await jobs.orderSplitsForLine(line)).single;
      expect(savedSplit.supplierId, supplier.id);
      expect(savedSplit.quantity, 6.25);
      expect(await db.select(db.supplierListings).get(), [listing]);
      expect(await db.select(db.suppliers).get(), [supplier]);
    },
  );

  for (final mode in ['custom', 'general', 'deleted Part']) {
    testWidgets('$mode split adopts a Supplier without creating any listing', (
      tester,
    ) async {
      final fixture = await WarehouseFixture.create();
      addTearDown(fixture.db.close);
      final db = fixture.db;
      final jobs = JobsRepository(db, fixture.device);
      final job = await jobs.createJob('Independent Supplier $mode');
      String? version;
      if (mode == 'deleted Part') {
        final brand = await MaintenanceRepository(
          db,
          fixture.pin,
          fixture.device,
        ).createBrand('Deleted Part brand');
        version = await fixture.catalog.createBrandVersion(
          partId: fixture.partId,
          brandId: brand,
          mpn: 'HISTORICAL-MPN',
        );
      }
      final line = await jobs.addLine(
        jobId: job,
        partId: mode == 'custom' ? null : fixture.partId,
        brandVersionId: version,
        customName: mode == 'custom' ? 'Original custom line' : null,
        neededQty: 5,
      );
      if (mode == 'deleted Part') {
        await db.partsDao.softDeletePart(fixture.partId);
      }
      final originalLine = await jobs.getJobLine(line);
      final originalSplits = await jobs.orderSplitsForLine(line);
      await _mountConsumer(
        tester,
        db: db,
        pin: fixture.pin,
        device: fixture.device,
        editor: JobLineEditor(jobId: job, lineId: line),
      );
      const rawRequested = '5.00';
      await tester.enterText(_field('Requested'), rawRequested);
      await tester.ensureVisible(find.text('Add supplier'));
      await tester.tap(find.text('Add supplier'));
      await tester.pumpAndSettle();
      await _saveSupplierName(tester, '  Independent supplier  ');
      final supplier = (await db.select(db.suppliers).get()).single;
      expect(supplier.name, 'Independent supplier');
      expect(
        tester
            .state<FormFieldState<String?>>(
              find.byType(DropdownButtonFormField<String?>),
            )
            .value,
        supplier.id,
      );
      expect(_fieldText(tester, 'Requested'), rawRequested);
      expect(await db.select(db.supplierListings).get(), isEmpty);
      expect(await jobs.getJobLine(line), originalLine);
      expect(await jobs.orderSplitsForLine(line), originalSplits);
      final parentKey =
          'local_edit_v1/job-line/${Uri.encodeComponent(job)}/${Uri.encodeComponent(line)}/input';
      final draftInput =
          (jsonDecode((await db.settingsDao.getSetting(parentKey))!)
                  as Map)['input']
              as Map;
      final input = draftInput['line'] as Map;
      expect(
        ((input['splits'] as List).single as Map)['supplier'],
        supplier.id,
      );
      expect(
        await db.settingsDao.getSetting(
          'local_edit_v1/catalog-name-new/supplier/control',
        ),
        isNull,
      );
    });
  }
}
