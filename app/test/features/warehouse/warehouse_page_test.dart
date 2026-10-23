import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/shell/home_shell.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/warehouse/warehouse_page.dart';

import 'warehouse_test_support.dart';

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

void main() {
  late WarehouseFixture f;
  setUp(() async => f = await WarehouseFixture.create());
  tearDown(() => f.db.close());

  Future<void> mount(WidgetTester tester, {bool shell = false}) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppScope(
        db: f.db,
        pin: f.pin,
        deviceId: f.device,
        edits: EditDrafts(db: f.db, pin: f.pin, deviceId: f.device),
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: MaterialApp(
          home: shell ? const HomeShell() : const WarehousePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> location(WidgetTester tester) async {
    await mount(tester);
    await tester.tap(find.text('Shop shelf'));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester) async {
    await tester.tap(find.text('Count a part'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search the tree'),
      'Counted part',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Counted part').last);
    await tester.pumpAndSettle();
    expect(find.text('Count Counted part'), findsOneWidget);
  }

  testWidgets(
    'More opens Inventory; reset disclosure names inventory and history',
    (tester) async {
      await mount(tester, shell: true);
      await tester.tap(find.text('More').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inventory / Warehouses'));
      await tester.pumpAndSettle();
      expect(find.text('Shop shelf'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reset / wipe all data'));
      await tester.tap(find.text('Reset / wipe all data'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('warehouse inventory and count history'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'committed count acknowledges Save even when the following SQLite reload fails',
    (tester) async {
      await f.db.close();
      f = await WarehouseFixture.create(
        executor: NativeDatabase.memory(
          setup: (raw) {
            raw.createFunction(
              functionName: 'fail_inventory_reload',
              argumentCount: const sqlite.AllowedArgumentCount(0),
              directOnly: false,
              function: (_) =>
                  throw StateError('synthetic inventory reload failure'),
            );
          },
        ),
      );
      await f.db.customStatement(
        'ALTER TABLE parts RENAME TO reload_test_parts',
      );
      await f.db.customStatement('''
      CREATE VIEW parts AS SELECT * FROM reload_test_parts
      WHERE CASE WHEN EXISTS (SELECT 1 FROM warehouse_counts)
        THEN fail_inventory_reload() ELSE 1 END
    ''');
      await location(tester);
      await pick(tester);
      await tester.enterText(field('Count quantity'), '4');
      await tester.tap(find.text('Save count'));
      await tester.pumpAndSettle();
      final counts = await f.repo.loadCountHistory(f.locationId, f.partId);
      expect(counts, hasLength(1));
      expect(counts.single.quantity, 4);
      expect(find.text('Count saved'), findsOneWidget);
      expect(
        find.text('Unable to load inventory. Retry to refresh.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Saved counts have not been changed'),
        findsNothing,
      );
      expect(find.text('Save count'), findsNothing);
      await f.db.customStatement('DROP VIEW parts');
      await f.db.customStatement(
        'ALTER TABLE reload_test_parts RENAME TO parts',
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('4 ea'), findsOneWidget);
      expect(
        (await f.repo.loadCountHistory(f.locationId, f.partId)).single.id,
        counts.single.id,
      );
    },
  );

  testWidgets('empty warehouse list can create and rename a stable location', (
    tester,
  ) async {
    await f.db.delete(f.db.warehouseLocations).go();
    await mount(tester);
    expect(find.textContaining('No warehouses yet'), findsOneWidget);
    await tester.tap(find.text('New warehouse'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), '  Bin A  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = (await f.repo.loadLocations()).single;
    expect(saved.name, 'Bin A');
    await tester.tap(find.text('Bin A'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not counted.'), findsOneWidget);
    await tester.tap(find.byTooltip('Rename warehouse'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Rack A');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final renamed = (await f.repo.loadLocations()).single;
    expect(renamed.id, saved.id);
    expect(renamed.name, 'Rack A');
  });

  testWidgets(
    'catalog count, absolute zero recount and history preserve note and provenance',
    (tester) async {
      await location(tester);
      await pick(tester);
      await tester.enterText(field('Count quantity'), '12.5');
      await tester.enterText(field('Count note'), 'Top shelf\nSecond check');
      await tester.tap(find.text('Save count'));
      await tester.pumpAndSettle();
      expect(find.text('12.5 ea'), findsOneWidget);
      expect(find.text('Device ${f.device}'), findsOneWidget);
      await tester.tap(find.text('Recount'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Count quantity'), '0');
      await tester.tap(find.text('Save count'));
      await tester.pumpAndSettle();
      expect(find.text('0 ea'), findsOneWidget);
      final history = await f.repo.loadCountHistory(f.locationId, f.partId);
      expect(history.map((r) => r.quantity), [0, 12.5]);
      expect(history.first.priorCountId, history.last.id);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Top shelf\nSecond check'), findsOneWidget);
      expect(find.textContaining('Recorded '), findsNWidgets(2));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'invalid and very large nonfinite input never writes or crashes; cancel stays empty',
    (tester) async {
      await location(tester);
      final before = await f.snapshot();
      await pick(tester);
      for (final value in ['', '-1', 'NaN', 'Infinity', '1e999']) {
        await tester.enterText(field('Count quantity'), value);
        await tester.tap(find.text('Save count'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Enter a finite, nonnegative'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await f.snapshot(), before);
    },
  );

  testWidgets(
    'locked or relocked editor PIN refuses without changing draft or store',
    (tester) async {
      await f.pin.setPin('1234');
      await location(tester);
      await tester.tap(find.text('Count a part'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search the tree'),
        'Counted part',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Counted part').last);
      await tester.pumpAndSettle();
      expect(find.text('Editor PIN'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await f.repo.loadCountHistory(f.locationId, f.partId), isEmpty);
      await f.pin.unlock('1234');
      await pick(tester);
      await tester.enterText(field('Count quantity'), '4');
      f.pin.lock();
      final before = await f.snapshot();
      await tester.tap(find.text('Save count'));
      await tester.pumpAndSettle();
      expect(
        find.text('Bad state: Catalog editor PIN required'),
        findsOneWidget,
      );
      expect(find.text('4'), findsOneWidget);
      expect(await f.snapshot(), before);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('stale open count cannot overwrite a committed observation', (
    tester,
  ) async {
    await location(tester);
    await pick(tester);
    final concurrent = await f.repo.recordCount(f.draft(quantity: 7));
    await tester.enterText(field('Count quantity'), '99');
    await tester.pumpAndSettle();
    final before = await f.snapshot();
    await tester.tap(find.text('Save count'));
    await tester.pumpAndSettle();
    expect(
      find.text('Bad state: Count changed. Cancel and reload before recounting.'),
      findsOneWidget,
    );
    expect(await f.snapshot(), before);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Reload counts'));
    await tester.pumpAndSettle();
    expect(find.text('7 ea'), findsOneWidget);
    expect(
      (await f.repo.latestCount(f.locationId, f.partId))!.id,
      concurrent.id,
    );
  });

  testWidgets('failed count Save keeps one request ID for retry', (
    tester,
  ) async {
    await location(tester);
    await pick(tester);
    await tester.enterText(field('Count quantity'), '8');
    await f.db.customStatement(
      "CREATE TRIGGER fail_count BEFORE INSERT ON warehouse_counts BEGIN SELECT RAISE(ABORT, 'synthetic count failure'); END",
    );
    final before = await f.snapshot();
    await tester.tap(find.text('Save count'));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic count failure'), findsOneWidget);
    expect(await f.snapshot(), before);
    await f.db.customStatement('DROP TRIGGER fail_count');
    await tester.tap(find.text('Save count'));
    await tester.pumpAndSettle();
    final saved = (await f.repo.loadCountHistory(
      f.locationId,
      f.partId,
    )).single;
    expect(saved.quantity, 8);
    expect(saved.ordinal, 1);
  });

  testWidgets(
    'unit change requires recount without conversion; deleted Part stays visible read only',
    (tester) async {
      final first = await f.repo.recordCount(f.draft(quantity: 12));
      await (f.db.update(f.db.parts)..where((t) => t.id.equals(f.partId)))
          .write(const PartsCompanion(uom: Value('box')));
      await location(tester);
      expect(find.text('12 ea'), findsOneWidget);
      expect(
        find.textContaining('Recount required; no conversion applied.'),
        findsOneWidget,
      );
      await (f.db.update(f.db.parts)..where((t) => t.id.equals(f.partId)))
          .write(PartsCompanion(deletedAt: Value(DateTime.now().toUtc())));
      await tester.tap(find.byTooltip('Reload counts'));
      await tester.pumpAndSettle();
      expect(find.textContaining('(removed from catalog)'), findsOneWidget);
      expect(find.text('Recount'), findsNothing);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.textContaining('12 ea'), findsNWidgets(2));
      expect(
        (await f.repo.loadCountHistory(f.locationId, f.partId)).single.id,
        first.id,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );
}
