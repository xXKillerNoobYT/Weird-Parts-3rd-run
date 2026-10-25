import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/features/jobs/job_line_editor.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import '../../tool/mock_shop/adapter.dart';
import '../../tool/mock_shop/fixture.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void _prepareView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Save'));
  await tester.pumpAndSettle();
}

Future<void> _selectSupplier(
  WidgetTester tester,
  int index,
  String name,
) async {
  final dropdown = find.byType(DropdownButtonFormField<String?>).at(index);
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> _openEditor(
  WidgetTester tester,
  MockLocalWorkspace workspace,
  MockShopFixture fixture, {
  String? lineId,
  bool custom = true,
  String customName = 'SCN-025 input probe',
}) async {
  await tester.pumpWidget(
    AppScope(
      db: workspace.db,
      pin: workspace.pin,
      deviceId: workspace.deviceId,
      wipeLocalData: () async => throw StateError('Reset is outside this test'),
      restoreFromBackup: (_, _) async =>
          throw StateError('Restore is outside this test'),
      child: MaterialApp(
        key: UniqueKey(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => JobLineEditor(
                    jobId: fixture.nativeId('job', 'JOB-001'),
                    lineId: lineId,
                  ),
                ),
              ),
              child: const Text('Open fixture editor'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open fixture editor'));
  await tester.pumpAndSettle();
  expect(find.byType(JobLineEditor), findsOneWidget);
  if (lineId == null && custom) {
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await _enter(tester, _field('Custom name'), customName);
  }
}

void main() {
  late MockShopFixture fixture;
  late MockLocalWorkspace workspace;

  setUpAll(() {
    fixture = MockShopFixture.read(Directory('test/fixtures/mock_shop'));
  });
  setUp(() async {
    workspace = await MockLocalWorkspace.create();
    await workspace.import(fixture);
  });
  tearDown(() => workspace.close());

  testWidgets(
    'mock shop app renders active Jobs and sourced catalog variants',
    (tester) async {
      _prepareView(tester);
      await tester.pumpWidget(
        WiredPartsApp(
          db: workspace.db,
          pin: workspace.pin,
          deviceId: workspace.deviceId,
          reset: LocalDataReset(
            supportDir: workspace.root,
            documentsDir: workspace.root,
            photosDir: Directory('${workspace.root.path}/photos'),
          ),
          reopenDatabase: () =>
              throw StateError('Database replacement is outside this test'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Maple duplex rough-in'), findsOneWidget);
      expect(find.text('Copper Kettle cafe refresh'), findsOneWidget);
      expect(find.text('Riverbend emergency outlet repair'), findsNothing);
      expect(find.text('Willow retail refresh'), findsNothing);
      final jobs = await workspace.db.select(workspace.db.jobs).get();
      expect(jobs, hasLength(7));
      expect(jobs.where((job) => job.status == 'active'), hasLength(5));
      expect(jobs.where((job) => job.status == 'archived'), hasLength(2));
      await tester.tap(find.text('Catalog'));
      await tester.pumpAndSettle();
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Search the tree',
      );
      await _enter(tester, search, 'CW-1-BL');
      expect(find.textContaining('CW-1-BL'), findsWidgets);
      expect(find.textContaining('CW-1-WH'), findsNothing);
      await _enter(tester, search, 'CW-1-WH');
      expect(find.textContaining('CW-1-WH'), findsWidgets);
      expect(find.textContaining('CW-1-BL'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'SCN-025 rejects typed negative requested, shop and split quantities',
    (tester) async {
      _prepareView(tester);
      final before = await workspace.publicBusinessDigest();
      for (final entry in [
        ('Requested', 'Enter a valid requested quantity'),
        ('Shop', 'Enter a valid shop quantity'),
        ('Qty', 'Each order split needs a quantity > 0'),
      ]) {
        await _openEditor(tester, workspace, fixture);
        if (entry.$1 == 'Qty') {
          await _selectSupplier(tester, 0, 'The Home Depot');
        }
        await _enter(tester, _field(entry.$1), '-1');
        final renderedInput = tester
            .widget<TextField>(_field(entry.$1))
            .controller!
            .text;
        await _save(tester);
        expect(
          (await workspace.db.select(workspace.db.jobLines).get()).length,
          40,
          reason:
              'Typed negative ${entry.$1} was rendered as $renderedInput and must not create a line',
        );
        expect(find.text(entry.$2), findsOneWidget);
        expect(await workspace.publicBusinessDigest(), before);
        expect(
          await workspace.db.select(workspace.db.orderSplits).get(),
          isEmpty,
        );
        expect(find.byType(JobLineEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'SCN-025 reports missing and malformed editor inputs without writes',
    (tester) async {
      _prepareView(tester);
      final before = await workspace.publicBusinessDigest();
      final cases = <({String kind, String error})>[
        (
          kind: 'missing catalog',
          error: 'Pick a catalog part or enter a custom name',
        ),
        (kind: 'empty custom', error: 'Custom name is required'),
        (kind: 'bad requested', error: 'Enter a valid requested quantity'),
        (kind: 'bad shop', error: 'Enter a valid shop quantity'),
        (kind: 'missing supplier', error: 'Each order split needs a supplier'),
        (kind: 'zero split', error: 'Each order split needs a quantity > 0'),
      ];
      for (final entry in cases) {
        await _openEditor(
          tester,
          workspace,
          fixture,
          custom: entry.kind != 'missing catalog',
          customName: entry.kind == 'empty custom' ? '' : 'SCN-025 input probe',
        );
        switch (entry.kind) {
          case 'bad requested':
            await _enter(tester, _field('Requested'), '1..2');
          case 'bad shop':
            await _enter(tester, _field('Shop'), '1..2');
          case 'missing supplier':
            await _enter(tester, _field('Qty'), '1');
          case 'zero split':
            await _selectSupplier(tester, 0, 'The Home Depot');
            await _enter(tester, _field('Qty'), '0');
        }
        await _save(tester);
        expect(find.text(entry.error), findsOneWidget);
        expect(await workspace.publicBusinessDigest(), before);
        expect(
          await workspace.db.select(workspace.db.orderSplits).get(),
          isEmpty,
        );
        expect(find.byType(JobLineEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('SCN-025 displays 5 then -1 and saves the actual allocation', (
    tester,
  ) async {
    _prepareView(tester);
    await _openEditor(
      tester,
      workspace,
      fixture,
      customName: 'SCN-025 saved allocation',
    );
    await _enter(tester, _field('Requested'), '20');
    await _enter(tester, _field('Shop'), '8');
    await _selectSupplier(tester, 0, 'The Home Depot');
    await _enter(tester, _field('Qty'), '7');
    expect(find.text('Left to Pull/Order 5'), findsOneWidget);
    await tester.ensureVisible(find.text('Add split'));
    await tester.tap(find.text('Add split'));
    await tester.pumpAndSettle();
    await _selectSupplier(tester, 1, "Lowe's");
    await _enter(tester, _field('Qty').at(1), '6');
    expect(find.text('Left to Pull/Order -1'), findsOneWidget);
    await _save(tester);
    expect(find.text('Open fixture editor'), findsOneWidget);
    final jobs = JobsRepository(workspace.db, workspace.deviceId);
    final lines = await jobs.listLinesForJob(
      fixture.nativeId('job', 'JOB-001'),
    );
    final line = lines.singleWhere(
      (item) => item.customName == 'SCN-025 saved allocation',
    );
    expect(line.neededQty, 20);
    expect(line.shopPullQty, 8);
    final splits = await jobs.orderSplitsForLine(line.id);
    expect(splits, hasLength(2));
    expect(splits.map((split) => split.quantity), containsAll([7, 6]));
    expect(
      splits.map((split) => split.supplierId),
      containsAll([
        fixture.nativeId('supplier', 'home-depot'),
        fixture.nativeId('supplier', 'lowes'),
      ]),
    );
    await _openEditor(tester, workspace, fixture, lineId: line.id);
    expect(find.text('Left to Pull/Order -1'), findsOneWidget);
    expect(
      tester.widget<TextField>(_field('Requested')).controller!.text,
      '20',
    );
    expect(tester.widget<TextField>(_field('Shop')).controller!.text, '8');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
