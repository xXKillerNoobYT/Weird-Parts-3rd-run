import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_page.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/catalog_tree.dart';
import 'package:wired_parts/features/catalog/part_details_dialog.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/jobs/job_line_editor.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

void main() {
  late AppDatabase db;
  late PinService pin;
  late String device;
  late CatalogRepository catalog;
  late MaintenanceRepository maintenance;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    device = await db.settingsDao.ensureDeviceId();
    pin = PinService(db.settingsDao);
    catalog = CatalogRepository(db, pin, device);
    maintenance = MaintenanceRepository(db, pin, device);
  });
  tearDown(() async => db.close());

  Future<({String category, String style, String variant})> hierarchy() async {
    final category = await maintenance.createCategory('Synthetic category');
    final style = await maintenance.createStyle(
      categoryId: category,
      name: 'Synthetic type',
    );
    final variant = await maintenance.createType(
      styleId: style,
      name: 'Synthetic variant',
    );
    return (category: category, style: style, variant: variant);
  }

  Future<void> mount(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: device,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await mount(tester, const CatalogPage());
    await tester.tap(find.byTooltip('New part'));
    await tester.pumpAndSettle();
  }

  Future<void> selectHierarchy(WidgetTester tester) async {
    for (final entry in [
      (0, 'Synthetic category'),
      (1, 'Synthetic type'),
      (2, 'Synthetic variant'),
    ]) {
      await tester.tap(
        find.byType(DropdownButtonFormField<String>).at(entry.$1),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.$2).last);
      await tester.pumpAndSettle();
    }
  }

  test(
    'public create rejects name-only and incomplete hierarchy without writes',
    () async {
      await expectLater(
        catalog.createGeneralPart(name: 'Unfiled'),
        throwsStateError,
      );
      final h = await hierarchy();
      for (final args in [
        (category: h.category, style: null, variant: null),
        (category: h.category, style: h.style, variant: null),
        (category: null, style: h.style, variant: h.variant),
      ]) {
        await expectLater(
          catalog.createGeneralPart(
            name: 'Incomplete',
            categoryId: args.category,
            styleId: args.style,
            typeId: args.variant,
          ),
          throwsStateError,
        );
      }
      expect(await catalog.listParts(), isEmpty);
    },
  );

  test(
    'public create rejects crossed, nonexistent and deleted hierarchy',
    () async {
      final a = await hierarchy();
      final b = await hierarchy();
      for (final args in [
        (category: a.category, style: b.style, variant: b.variant),
        (category: a.category, style: a.style, variant: b.variant),
        (category: 'missing', style: a.style, variant: a.variant),
      ]) {
        await expectLater(
          catalog.createGeneralPart(
            name: 'Crossed',
            categoryId: args.category,
            styleId: args.style,
            typeId: args.variant,
          ),
          throwsStateError,
        );
      }
      for (final table in ['categories', 'styles', 'types']) {
        final id = table == 'categories'
            ? a.category
            : table == 'styles'
            ? a.style
            : a.variant;
        await db.customStatement(
          'UPDATE $table SET deleted_at = ? WHERE id = ?',
          [1, id],
        );
        await expectLater(
          catalog.createGeneralPart(
            name: 'Deleted parent',
            categoryId: a.category,
            styleId: a.style,
            typeId: a.variant,
          ),
          throwsStateError,
        );
        await db.customStatement(
          'UPDATE $table SET deleted_at = NULL WHERE id = ?',
          [id],
        );
      }
      await expectLater(
        catalog.createGeneralPart(
          name: '   ',
          categoryId: a.category,
          styleId: a.style,
          typeId: a.variant,
        ),
        throwsStateError,
      );
      expect(await catalog.listParts(), isEmpty);
    },
  );

  test(
    'locked PIN refuses valid part and every inline maintenance write',
    () async {
      final h = await hierarchy();
      await pin.setPin('2468');
      await expectLater(
        catalog.createGeneralPart(
          name: 'Locked',
          categoryId: h.category,
          styleId: h.style,
          typeId: h.variant,
        ),
        throwsStateError,
      );
      await expectLater(
        maintenance.createCategory('Blocked'),
        throwsStateError,
      );
      await expectLater(
        maintenance.createStyle(categoryId: h.category, name: 'Blocked'),
        throwsStateError,
      );
      await expectLater(
        maintenance.createType(styleId: h.style, name: 'Blocked'),
        throwsStateError,
      );
      expect(await catalog.listParts(), isEmpty);
      expect(await maintenance.listCategories(), hasLength(1));
      expect(await maintenance.listStyles(), hasLength(1));
      expect(await maintenance.listTypes(), hasLength(1));
    },
  );

  testWidgets('cancel and name-only New part leave no placeholder', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).last, 'Synthetic part');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await catalog.listParts(), isEmpty);
    expect(
      find.text('Category, Type, and Variant are required'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await catalog.listParts(), isEmpty);
  });

  testWidgets('existing hierarchy can be selected before saving first part', (
    tester,
  ) async {
    final h = await hierarchy();
    await open(tester);
    await tester.enterText(field('Part name'), 'Selected first part');
    await selectHierarchy(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final part = (await catalog.listParts()).single;
    expect(part.name, 'Selected first part');
    expect(
      (part.categoryId, part.styleId, part.typeId),
      (h.category, h.style, h.variant),
    );
  });

  testWidgets(
    'locking PIN while the form is open prevents the final part write',
    (tester) async {
      await hierarchy();
      await pin.setPin('2468');
      await pin.unlock('2468');
      await open(tester);
      await tester.enterText(field('Part name'), 'Expired permission');
      await selectHierarchy(tester);
      pin.lock();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await catalog.listParts(), isEmpty);
      expect(find.text('Catalog editor PIN required'), findsOneWidget);
    },
  );

  testWidgets('cancel after inline folders leaves no part', (tester) async {
    await open(tester);
    await tester.enterText(field('Part name'), 'Cancelled part');
    await tester.tap(find.text('Add Category'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Reusable folder');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await catalog.listParts(), isEmpty);
    expect((await maintenance.listCategories()).single.name, 'Reusable folder');
  });

  testWidgets('stale initial hierarchy clears dependent choices', (
    tester,
  ) async {
    final h = await hierarchy();
    await mount(
      tester,
      PartDetailsDialog(
        maintenance: maintenance,
        initialCategoryId: 'missing-category',
        initialStyleId: h.style,
        initialTypeId: h.variant,
      ),
    );
    final picks = tester.widgetList<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(picks.map((p) => p.initialValue), [null, null, null]);
    await selectHierarchy(tester);
    expect(tester.takeException(), isNull);
    expect(await catalog.listParts(), isEmpty);
  });

  testWidgets(
    'locking PIN while an inline name prompt is open blocks folder creation',
    (tester) async {
      await pin.setPin('2468');
      await pin.unlock('2468');
      await open(tester);
      await tester.tap(find.text('Add Category'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Name'), 'Blocked folder');
      pin.lock();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(await maintenance.listCategories(), isEmpty);
      expect(await catalog.listParts(), isEmpty);
      expect(find.text('Catalog editor PIN required'), findsOneWidget);
    },
  );

  testWidgets(
    'promotion uses the shared complete form and preserves the job quantity',
    (tester) async {
      final h = await hierarchy();
      final jobs = JobsRepository(db, device);
      final job = await jobs.createJob('Synthetic job');
      await mount(tester, JobLineEditor(jobId: job));
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Custom name'), 'Promoted first part');
      await tester.enterText(field('Requested'), '7');
      await tester.tap(find.text('Promote to catalog'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Promote'));
      await tester.pumpAndSettle();
      expect(await catalog.listParts(), isEmpty);
      await selectHierarchy(tester);
      await tester.tap(find.text('Promote'));
      await tester.pumpAndSettle();
      final part = (await catalog.listParts()).single;
      expect(part.name, 'Promoted first part');
      expect(
        (part.categoryId, part.styleId, part.typeId),
        (h.category, h.style, h.variant),
      );
      final line = (await jobs.listLinesForJob(job)).single;
      expect(line.partId, part.id);
      expect(line.neededQty, 7);
    },
  );

  test(
    'company markers refuse otherwise valid catalog and maintenance writes',
    () async {
      final h = await hierarchy();
      await db.customStatement(
        'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
        ['synthetic-blocker', 1, 'blocked', 'synthetic-refusal-marker'],
      );
      await expectLater(
        catalog.createGeneralPart(
          name: 'Denied',
          categoryId: h.category,
          styleId: h.style,
          typeId: h.variant,
        ),
        throwsStateError,
      );
      await expectLater(maintenance.createCategory('Denied'), throwsStateError);
      expect(await catalog.listParts(), isEmpty);
      expect(await maintenance.listCategories(), hasLength(1));
    },
  );

  test(
    'part creation and variant deletion serialize without an orphan',
    () async {
      for (final deleteFirst in [false, true]) {
        final h = await hierarchy();
        Future<bool> create() async {
          try {
            await catalog.createGeneralPart(
              name: 'Concurrent part',
              categoryId: h.category,
              styleId: h.style,
              typeId: h.variant,
            );
            return true;
          } on StateError {
            return false;
          }
        }

        Future<bool> remove() async {
          try {
            await catalog.deleteEmptyFolder(
              kind: CatalogTreeKind.variant,
              id: h.variant,
            );
            return true;
          } on StateError {
            return false;
          }
        }

        final results = await Future.wait(
          deleteFirst ? [remove(), create()] : [create(), remove()],
        );
        expect(results.where((result) => result), hasLength(1));
        final matching = (await catalog.listParts()).where(
          (p) => p.typeId == h.variant,
        );
        final variants = await maintenance.listTypes(styleId: h.style);
        expect(matching.length, variants.length);
      }
    },
  );

  testWidgets(
    'empty catalog creates hierarchy inline then exactly one valid first part',
    (tester) async {
      await open(tester);
      await tester.enterText(field('Part name'), 'Synthetic first part');
      for (final pair in [
        ('Category', 'Electrical'),
        ('Type', 'Outlet'),
        ('Variant', 'GFI'),
      ]) {
        await tester.tap(find.text('Add ${pair.$1}'));
        await tester.pumpAndSettle();
        await tester.enterText(field('Name'), pair.$2);
        await tester.tap(find.text('Save').last);
        await tester.pumpAndSettle();
        expect(await catalog.listParts(), isEmpty);
      }
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final parts = await catalog.listParts();
      expect(parts, hasLength(1));
      final part = parts.single;
      expect(part.name, 'Synthetic first part');
      expect(part.categoryId, (await maintenance.listCategories()).single.id);
      expect(part.styleId, (await maintenance.listStyles()).single.id);
      expect(part.typeId, (await maintenance.listTypes()).single.id);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'valid first part and hierarchy IDs survive file-backed close and reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('issue19-first-part-');
      final file = File('${dir.path}/synthetic.sqlite');
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      final first = db;
      final firstDevice = await first.settingsDao.ensureDeviceId();
      final firstPin = PinService(first.settingsDao);
      final folders = MaintenanceRepository(first, firstPin, firstDevice);
      final category = await folders.createCategory('Electrical');
      final style = await folders.createStyle(
        categoryId: category,
        name: 'Outlet',
      );
      final variant = await folders.createType(styleId: style, name: 'GFI');
      final supplier = await folders.createSupplier('Synthetic supply');
      final id = await CatalogRepository(first, firstPin, firstDevice)
          .createGeneralPart(
            name: 'Persistent first part',
            defaultSupplierId: supplier,
            categoryId: category,
            styleId: style,
            typeId: variant,
          );
      await first.partsDao.setPhotoPath(id, 'synthetic-photo.jpg');
      await CatalogRepository(first, firstPin, firstDevice).updatePart(
        partId: id,
        name: 'Persistent first part',
        description: '',
        uom: 'ea',
        defaultSupplierId: supplier,
        active: true,
        categoryId: category,
        styleId: style,
        typeId: variant,
        specs: 'Voltage: 120 V\nCurrent: 20 A',
      );
      await first.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      final reopened = db;
      try {
        final parts = await reopened.partsDao.listParts();
        expect(parts, hasLength(1));
        expect(parts.single.id, id);
        expect(parts.single.categoryId, category);
        expect(parts.single.styleId, style);
        expect(parts.single.typeId, variant);
        expect(parts.single.specs, 'Voltage: 120 V\nCurrent: 20 A');
        expect(parts.single.photoPath, 'synthetic-photo.jpg');
        expect(parts.single.defaultSupplierId, supplier);
        await CatalogRepository(
          reopened,
          PinService(reopened.settingsDao),
          firstDevice,
        ).updatePart(
          partId: id,
          name: parts.single.name,
          description: parts.single.description,
          uom: parts.single.uom,
          defaultSupplierId: supplier,
          active: parts.single.active,
          categoryId: category,
          styleId: style,
          typeId: variant,
        );
        expect(
          (await reopened.partsDao.getPart(id))!.specs,
          'Voltage: 120 V\nCurrent: 20 A',
        );
        expect(
          (await reopened.taxonomyDao.listStyles(categoryId: category))
              .single
              .id,
          style,
        );
        expect(
          (await reopened.taxonomyDao.listTypes(styleId: style)).single.id,
          variant,
        );
        expect(await reopened.settingsDao.ensureDeviceId(), firstDevice);
      } finally {
        await reopened.close();
        await dir.delete(recursive: true);
        db = AppDatabase.forTesting(NativeDatabase.memory());
      }
    },
  );

  testWidgets('Part detail can edit and clear Specifications offline', (
    WidgetTester tester,
  ) async {
    final h = await hierarchy();
    final supplierId = await maintenance.createSupplier('Synthetic supply');
    final id = await catalog.createGeneralPart(
      name: 'Offline part',
      defaultSupplierId: supplierId,
      categoryId: h.category,
      styleId: h.style,
      typeId: h.variant,
    );
    await catalog.updatePart(
      partId: id,
      name: 'Offline part',
      description: 'Known description',
      uom: 'box',
      defaultSupplierId: supplierId,
      active: true,
      categoryId: h.category,
      styleId: h.style,
      typeId: h.variant,
    );

    await mount(tester, PartDetailPage(partId: id));
    final specs = field('Specifications');
    expect(specs, findsOneWidget);
    await tester.enterText(specs, '120 V\n20 A');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    var saved = await catalog.getPart(id);
    expect(saved!.specs, '120 V\n20 A');
    expect(saved.id, id);
    expect(saved.name, 'Offline part');
    expect(saved.description, 'Known description');
    expect(saved.uom, 'box');
    expect(saved.defaultSupplierId, supplierId);
    expect(saved.categoryId, h.category);
    expect(saved.styleId, h.style);
    expect(saved.typeId, h.variant);

    await tester.enterText(specs, '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    saved = await catalog.getPart(id);
    expect(saved!.specs, isEmpty);
    expect(saved.categoryId, h.category);
    expect(saved.styleId, h.style);
    expect(saved.typeId, h.variant);
  });
}
