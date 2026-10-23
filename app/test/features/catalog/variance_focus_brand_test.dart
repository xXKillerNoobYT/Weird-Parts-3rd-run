import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';

import '../warehouse/warehouse_test_support.dart';

enum _FocusBrand { missing, deleted, live }

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  late WarehouseFixture fixture;
  late EditDrafts edits;
  late MaintenanceRepository maintenance;
  const pendingJobName = '  Unrelated unfinished Job  ';
  const parentName = '  Parent Part input stays exact  ';
  const parentDescription = '  Parent description stays exact  ';
  const varianceName = '  White / unfinished option  ';
  const partNumber = '  UNFINISHED-MPN  ';

  String varianceSlot() =>
      '${editDraftPrefix}variance-new/${Uri.encodeComponent(fixture.partId)}';
  String parentSlot() =>
      '${editDraftPrefix}part/${Uri.encodeComponent(fixture.partId)}';

  Future<Map<String, String?>> draftRows(String slot) async => {
    for (final row in ['input', 'control'])
      row: await fixture.db.settingsDao.getSetting('$slot/$row'),
  };

  Future<Map<String, List<Map<String, Object?>>>> businessRecords() async {
    final records = await fixture.snapshot();
    return records..remove(fixture.db.appSettings.actualTableName);
  }

  setUp(() async {
    fixture = await WarehouseFixture.create();
    edits = EditDrafts(
      db: fixture.db,
      pin: fixture.pin,
      deviceId: fixture.device,
    );
    maintenance = MaintenanceRepository(
      fixture.db,
      fixture.pin,
      fixture.device,
    );
    final job =
        (await edits.openNewJob() as FreshEdit<NewJobEditSession>).session;
    job.replace(const NewJobInput(nameText: pendingJobName));
    await job.leave(LeaveIntent.back);
  });

  tearDown(() async {
    await edits.quiesce(StorageChange.exit);
    await fixture.db.close();
  });

  Future<void> openFocused(WidgetTester tester, String brandId) async {
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppScope(
        db: fixture.db,
        pin: fixture.pin,
        deviceId: fixture.device,
        edits: edits,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: MaterialApp(
          home: PartDetailPage(partId: fixture.partId, focusBrandId: brandId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder brandField() => find.descendant(
    of: find.byType(AlertDialog).last,
    matching: find.byType(DropdownButtonFormField<String>),
  );

  String rawText(WidgetTester tester, String label) =>
      tester.widget<TextField>(_field(label)).controller!.text;

  void expectFreshForm(WidgetTester tester, String? selectedBrand) {
    expect(find.text('Unfinished edits cannot be resumed.'), findsNothing);
    expect(find.text('Resume'), findsNothing);
    expect(_field('Variance (color / option)'), findsOneWidget);
    expect(_field('Part number'), findsOneWidget);
    expect(
      tester.widget<TextField>(_field('Variance (color / option)')).enabled,
      isTrue,
    );
    expect(tester.widget<TextField>(_field('Part number')).enabled, isTrue);
    expect(
      tester.state<FormFieldState<String>>(brandField()).value,
      selectedBrand,
    );
    expect(
      tester.widget<DropdownButtonFormField<String>>(brandField()).onChanged,
      isNotNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Add brand'))
          .onPressed,
      isNotNull,
    );
    expect(rawText(tester, 'Variance (color / option)'), isEmpty);
    expect(rawText(tester, 'Part number'), isEmpty);
  }

  Future<void> editParentAndReopen(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Back').last);
    await tester.pumpAndSettle();
    await tester.enterText(_field('Name'), parentName);
    await tester.enterText(_field('Description'), parentDescription);
    await tester.pumpAndSettle();
    final add = find.widgetWithText(TextButton, 'Add variance').first;
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
  }

  for (final scenario in [
    (focus: _FocusBrand.missing, hasLiveBrand: true),
    (focus: _FocusBrand.deleted, hasLiveBrand: true),
    (focus: _FocusBrand.missing, hasLiveBrand: false),
    (focus: _FocusBrand.deleted, hasLiveBrand: false),
    (focus: _FocusBrand.live, hasLiveBrand: true),
  ]) {
    testWidgets(
      'fresh ${scenario.focus.name} focus with ${scenario.hasLiveBrand ? 'a live Brand' : 'no live Brands'} opens an editable variance',
      (tester) async {
        final liveBrand = scenario.hasLiveBrand
            ? await maintenance.createBrand('A live default Brand')
            : null;
        var focusBrand = 'missing-focused-brand';
        if (scenario.focus != _FocusBrand.missing) {
          focusBrand = await maintenance.createBrand('Z focused Brand');
          if (scenario.focus == _FocusBrand.deleted) {
            await fixture.db.customStatement(
              'UPDATE brands SET deleted_at = 1 WHERE id = ?',
              [focusBrand],
            );
          }
        }
        final expectedBrand = scenario.focus == _FocusBrand.live
            ? focusBrand
            : liveBrand;
        final before = await businessRecords();
        final unrelated = await draftRows('${editDraftPrefix}job-new');

        await openFocused(tester, focusBrand);
        expectFreshForm(tester, expectedBrand);
        expect(await businessRecords(), before);
        expect(await draftRows('${editDraftPrefix}job-new'), unrelated);
        await tester.enterText(
          _field('Variance (color / option)'),
          varianceName,
        );
        await tester.enterText(_field('Part number'), partNumber);
        await tester.pumpAndSettle();
        expect(rawText(tester, 'Variance (color / option)'), varianceName);
        expect(rawText(tester, 'Part number'), partNumber);
        expect(await businessRecords(), before);

        await editParentAndReopen(tester);
        final parent = await draftRows(parentSlot());
        expect(parent['input'], isNotNull);
        expect(find.text('Resume'), findsOneWidget);
        expect(_field('Variance (color / option)'), findsNothing);
        await tester.tap(find.text('Discard unfinished edits'));
        await tester.pumpAndSettle();
        expectFreshForm(tester, liveBrand);
        expect(await draftRows(varianceSlot()), {
          'input': null,
          'control': null,
        });
        expect(await draftRows(parentSlot()), parent);
        expect(await draftRows('${editDraftPrefix}job-new'), unrelated);
        expect(await businessRecords(), before);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
        await tester.pumpAndSettle();
        expect(rawText(tester, 'Name'), parentName);
        expect(rawText(tester, 'Description'), parentDescription);
        expect(await draftRows(parentSlot()), parent);
        expect(await draftRows('${editDraftPrefix}job-new'), unrelated);
        expect(await businessRecords(), before);
      },
    );
  }

  testWidgets(
    'admitted variance with a deleted Brand stays blocked until explicit Discard',
    (tester) async {
      final liveBrand = await maintenance.createBrand('A live default Brand');
      final deletedBrand = await maintenance.createBrand('Z selected Brand');
      final session = (await edits.openNewVariance(
        partId: fixture.partId,
        initial: VarianceInput(
          brandId: deletedBrand,
          varianceNameText: '',
          mpnText: '',
          isMain: false,
        ),
      ) as FreshEdit<NewVarianceEditSession>).session;
      session.replace(
        VarianceInput(
          brandId: deletedBrand,
          varianceNameText: varianceName,
          mpnText: partNumber,
          isMain: false,
        ),
      );
      await session.leave(LeaveIntent.back);
      await fixture.db.customStatement(
        'UPDATE brands SET deleted_at = 1 WHERE id = ?',
        [deletedBrand],
      );
      final pending = await draftRows(varianceSlot());
      final unrelated = await draftRows('${editDraftPrefix}job-new');
      final before = await businessRecords();
      expect(pending['input'], isNotNull);
      expect(pending['control'], isNotNull);

      await openFocused(tester, deletedBrand);
      expect(find.text('Unfinished edits cannot be resumed.'), findsOneWidget);
      expect(find.text('Preserved input'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        pending['input'],
      );
      expect(find.text('Resume'), findsNothing);
      expect(_field('Variance (color / option)'), findsNothing);
      expect(_field('Part number'), findsNothing);
      expect(await draftRows(varianceSlot()), pending);
      expect(await draftRows('${editDraftPrefix}job-new'), unrelated);
      expect(await businessRecords(), before);

      await editParentAndReopen(tester);
      final parent = await draftRows(parentSlot());
      expect(parent['input'], isNotNull);
      expect(find.text('Unfinished edits cannot be resumed.'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        pending['input'],
      );
      expect(await draftRows(varianceSlot()), pending);
      expect(await draftRows('${editDraftPrefix}job-new'), unrelated);
      expect(await businessRecords(), before);

      await tester.scrollUntilVisible(
        find.text('Discard unfinished edits'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(AlertDialog).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Discard unfinished edits'));
      await tester.pumpAndSettle();
      expectFreshForm(tester, liveBrand);
      expect(await draftRows(varianceSlot()), {'input': null, 'control': null});
      expect(await draftRows(parentSlot()), parent);
      expect(await draftRows('${editDraftPrefix}job-new'), unrelated);
      expect(await businessRecords(), before);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pumpAndSettle();
      expect(rawText(tester, 'Name'), parentName);
      expect(rawText(tester, 'Description'), parentDescription);
      expect(await draftRows(parentSlot()), parent);
      expect(await draftRows('${editDraftPrefix}job-new'), unrelated);
      expect(await businessRecords(), before);
    },
  );
}
