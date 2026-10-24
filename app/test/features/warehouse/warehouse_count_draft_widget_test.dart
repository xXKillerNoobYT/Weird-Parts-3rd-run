import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/warehouse/warehouse_repository.dart';

import 'warehouse_test_support.dart';

void main() {
  testWidgets(
    'unfinished physical count resumes exactly after normal close and reopen',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'warehouse-count-draft-',
      );
      final file = File('${directory.path}/synthetic.sqlite');
      final fixture = await WarehouseFixture.create(file: file);
      var db = fixture.db;
      var dbOpen = true;
      final deviceId = fixture.device;
      var pin = fixture.pin;
      late final String priorCountId;

      addTearDown(
        () => tester.runAsync(() async {
          if (dbOpen) await db.close();
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        }),
      );

      final prior = await fixture.repo.recordCount(
        fixture.draft(quantity: 6.25, note: 'Existing observation'),
      );
      priorCountId = prior.id;

      Future<void> pumpApp() async {
        await tester.pumpWidget(
          WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
        );
        await tester.pumpAndSettle();
      }

      Future<void> openRecount() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Inventory / Warehouses'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Shop shelf'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recount'));
        await tester.pumpAndSettle();
      }

      Finder field(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      Finder observedText() => find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text && widget.data?.startsWith('Observed ') == true,
        ),
      );

      await pumpApp();
      await openRecount();

      const rawQuantity = '  not-a-number  ';
      const rawNote = '  top shelf check\nsecond line · keep spaces  ';
      await tester.enterText(field('Count quantity'), rawQuantity);
      await tester.enterText(field('Count note'), rawNote);
      final initialObservedLabel = tester.widget<Text>(observedText()).data!;
      await tester.tap(observedText());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK').last);
      await tester.pumpAndSettle();

      final observedLabel = tester.widget<Text>(observedText()).data!;
      expect(observedLabel, isNot(initialObservedLabel));
      expect(await db.select(db.warehouseCounts).get(), hasLength(1));

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
      await openRecount();

      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Discard unfinished edits'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(field('Count quantity')).controller!.text,
        rawQuantity,
      );
      expect(
        tester.widget<TextField>(field('Count note')).controller!.text,
        rawNote,
      );
      expect(tester.widget<Text>(observedText()).data, observedLabel);
      expect(await db.select(db.warehouseCounts).get(), hasLength(1));

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final history = await WarehouseRepository(
        db,
        pin,
        deviceId,
      ).loadCountHistory(fixture.locationId, fixture.partId);
      expect(history, hasLength(1));
      expect(history.single.id, priorCountId);
      expect(history.single.quantity, 6.25);
      expect(history.single.note, 'Existing observation');
    },
  );

  testWidgets(
    'Back retains invalid count input and Cancel discards only that draft',
    (tester) async {
      final fixture = await WarehouseFixture.create();
      addTearDown(fixture.db.close);
      final prior = await fixture.repo.recordCount(
        fixture.draft(quantity: 4.5, note: 'Prior count'),
      );
      await tester.pumpWidget(
        WiredPartsApp(
          db: fixture.db,
          pin: fixture.pin,
          deviceId: fixture.device,
        ),
      );
      await tester.pumpAndSettle();

      Future<void> openRecount() async {
        await tester.tap(find.text('More').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Inventory / Warehouses'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Shop shelf'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recount'));
        await tester.pumpAndSettle();
      }

      Finder field(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );

      await openRecount();
      const rawQuantity = '  not valid  ';
      const rawNote = '  shelf A\nsecond observation  ';
      await tester.enterText(field('Count quantity'), rawQuantity);
      await tester.enterText(field('Count note'), rawNote);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        await fixture.db.select(fixture.db.warehouseCounts).get(),
        hasLength(1),
      );

      await tester.tap(find.text('Recount'));
      await tester.pumpAndSettle();
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Discard unfinished edits'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('Count quantity')).controller!.text,
        rawQuantity,
      );
      expect(
        tester.widget<TextField>(field('Count note')).controller!.text,
        rawNote,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final counts = await fixture.repo.loadCountHistory(
        fixture.locationId,
        fixture.partId,
      );
      expect(counts, hasLength(1));
      expect(counts.single.id, prior.id);
      expect(counts.single.quantity, 4.5);
      expect(
        await fixture.db
            .customSelect(
              "SELECT key FROM app_settings WHERE key LIKE 'local_edit_v1/warehouse-count/%' ORDER BY key",
            )
            .get(),
        isEmpty,
      );
    },
  );

  testWidgets('saved count receipt survives Close until Done acknowledges it', (
    tester,
  ) async {
    final fixture = await WarehouseFixture.create();
    addTearDown(fixture.db.close);
    final edits = EditDrafts(
      db: fixture.db,
      pin: fixture.pin,
      deviceId: fixture.device,
    );
    final session = (await edits.openWarehouseCount(
      locationId: fixture.locationId,
      partId: fixture.partId,
      uom: 'ea',
      expectedPriorCountId: null,
    ) as FreshEdit<WarehouseCountEditSession>).session;
    session.replace(
      WarehouseCountInput(
        quantityText: ' 8.5 ',
        noteText: 'Saved before the response was lost',
        observedAt: DateTime.utc(2026, 10, 21, 11, 12, 13),
      ),
    );
    await session.flush();
    final created = await session.save();
    final receiptKey =
        'local_edit_v1/warehouse-count/${Uri.encodeComponent(fixture.locationId)}/${Uri.encodeComponent(fixture.partId)}/control';
    final receipt = await fixture.db.settingsDao.getSetting(receiptKey);
    expect(receipt, isNotNull);

    await tester.pumpWidget(
      WiredPartsApp(db: fixture.db, pin: fixture.pin, deviceId: fixture.device),
    );
    await tester.pumpAndSettle();

    Future<void> openRecount() async {
      await tester.tap(find.text('More').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inventory / Warehouses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shop shelf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recount'));
      await tester.pumpAndSettle();
    }

    await openRecount();
    expect(find.text('Count saved'), findsOneWidget);
    expect(find.text('Saved 8.5 ea'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(await fixture.db.settingsDao.getSetting(receiptKey), receipt);
    var rows = await fixture.repo.loadCountHistory(
      fixture.locationId,
      fixture.partId,
    );
    expect(rows, hasLength(1));
    expect(rows.single.id, created.count.id);
    expect(rows.single.quantity, 8.5);

    await tester.tap(find.text('Recount'));
    await tester.pumpAndSettle();
    expect(find.text('Count saved'), findsOneWidget);
    expect(find.text('Saved 8.5 ea'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await tester.pumpAndSettle();

    expect(await fixture.db.settingsDao.getSetting(receiptKey), isNull);
    rows = await fixture.repo.loadCountHistory(
      fixture.locationId,
      fixture.partId,
    );
    expect(rows, hasLength(1));
    expect(rows.single.id, created.count.id);
    expect(rows.single.quantity, 8.5);
  });
}
