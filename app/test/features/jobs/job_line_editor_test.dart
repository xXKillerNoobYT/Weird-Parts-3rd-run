import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/job_line_editor.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _openEditor(
  WidgetTester tester, {
  required AppDatabase db,
  required String deviceId,
  required String jobId,
  String? lineId,
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      db: db,
      pin: PinService(db.settingsDao),
      deviceId: deviceId,
      wipeLocalData: () async {},
      restoreFromBackup: (_, _) async {},
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => JobLineEditor(jobId: jobId, lineId: lineId),
                ),
              ),
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

void main() {
  late AppDatabase db;
  late String deviceId;
  late JobsRepository jobs;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deviceId = await db.settingsDao.ensureDeviceId();
    jobs = JobsRepository(db, deviceId);
  });
  tearDown(() async => db.close());

  for (final catalogLinked in [true, false]) {
    testWidgets(
      'quantity edit preserves metadata on ${catalogLinked ? 'catalog' : 'custom'} line',
      (tester) async {
        final supplierId = await db.taxonomyDao.insertSupplier(
          id: newId(),
          name: 'Synthetic supplier',
          deviceId: deviceId,
        );
        String? partId;
        String? brandVersionId;
        if (catalogLinked) {
          final brandId = await db.taxonomyDao.insertBrand(
            id: newId(),
            name: 'Synthetic brand',
            deviceId: deviceId,
          );
          partId = await db.partsDao.insertGeneralPart(
            id: newId(),
            name: 'Synthetic part',
            deviceId: deviceId,
          );
          brandVersionId = await db.partsDao.insertBrandVersion(
            id: newId(),
            partId: partId,
            brandId: brandId,
            mpn: 'SYNTH-1',
            deviceId: deviceId,
          );
          await db.partsDao.insertSupplierListing(
            id: newId(),
            brandVersionId: brandVersionId,
            supplierId: supplierId,
            sku: 'SYNTH-SKU',
            deviceId: deviceId,
          );
        }
        final jobId = await jobs.createJob('Synthetic job');
        final lineId = await jobs.addLine(
          jobId: jobId,
          partId: partId,
          brandVersionId: brandVersionId,
          customName: catalogLinked ? null : 'Synthetic custom part',
          customNotes: 'Synthetic custom notes',
          uom: 'box',
          notes: 'Synthetic line notes',
          neededQty: 7,
          shopPullQty: 2,
        );
        await jobs.replaceOrderSplits(lineId, [
          (supplierId: supplierId, qty: 5),
        ]);
        final original = (await jobs.getJobLine(lineId))!;
        final originalSplit = (await jobs.orderSplitsForLine(lineId)).single;

        await _openEditor(
          tester,
          db: db,
          deviceId: deviceId,
          jobId: jobId,
          lineId: lineId,
        );
        await tester.enterText(_field('Requested'), '9');
        await tester.enterText(_field('Shop'), '3');
        await tester.ensureVisible(_field('Qty'));
        await tester.enterText(_field('Qty'), '4');
        await tester.tap(find.widgetWithText(TextButton, 'Save'));
        await tester.pumpAndSettle();
        expect(find.text('Open editor'), findsOneWidget);

        final saved = (await jobs.getJobLine(lineId))!;
        expect(saved.customNotes, 'Synthetic custom notes');
        expect(saved.uom, 'box');
        expect(saved.notes, 'Synthetic line notes');
        expect(saved.id, original.id);
        expect(saved.jobId, jobId);
        expect(saved.partId, partId);
        expect(saved.brandVersionId, brandVersionId);
        expect(saved.customName, original.customName);
        expect(saved.originDeviceId, original.originDeviceId);
        expect(saved.createdAt, original.createdAt);
        expect(saved.revision, original.revision + 1);
        expect(saved.neededQty, 9);
        expect(saved.shopPullQty, 3);
        expect(await jobs.listLinesForJob(jobId), hasLength(1));
        final activeSplits = await jobs.orderSplitsForLine(lineId);
        expect(activeSplits, hasLength(1));
        expect(activeSplits.single.id, isNot(originalSplit.id));
        expect(activeSplits.single.jobLineId, lineId);
        expect(activeSplits.single.supplierId, supplierId);
        expect(activeSplits.single.quantity, 4);
        expect(
          activeSplits.fold<double>(0, (sum, split) => sum + split.quantity),
          4,
        );
        final storedSplits = await (db.select(
          db.orderSplits,
        )..where((split) => split.jobLineId.equals(lineId))).get();
        expect(storedSplits, hasLength(2));
        final tombstone = storedSplits.singleWhere(
          (split) => split.id == originalSplit.id,
        );
        expect(tombstone.deletedAt, isNotNull);
        expect(tombstone.quantity, 5);
        expect(tombstone.revision, originalSplit.revision + 1);
      },
    );
  }

  testWidgets('new custom line saves with null metadata', (tester) async {
    final jobId = await jobs.createJob('Synthetic custom job');
    await _openEditor(tester, db: db, deviceId: deviceId, jobId: jobId);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('Custom name'), 'Synthetic new line');
    await tester.enterText(_field('Requested'), '6');
    await tester.enterText(_field('Shop'), '2');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Open editor'), findsOneWidget);
    final saved = (await jobs.listLinesForJob(jobId)).single;
    expect(saved.customName, 'Synthetic new line');
    expect(saved.partId, isNull);
    expect(saved.brandVersionId, isNull);
    expect(saved.customNotes, isNull);
    expect(saved.uom, isNull);
    expect(saved.notes, isNull);
    expect(saved.neededQty, 6);
    expect(saved.shopPullQty, 2);
    expect(await jobs.orderSplitsForLine(saved.id), isEmpty);
  });
}
