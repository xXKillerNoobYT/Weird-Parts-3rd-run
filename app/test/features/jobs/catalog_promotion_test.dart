import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/catalog_promotion.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late AppDatabase db;
  late String device;
  late PinService pin;
  late JobsRepository jobs;
  late CatalogPromotion promotion;
  late String job;
  late String category;
  late String style;
  late String variant;

  Future<void> initialize() async {
    device = await db.settingsDao.ensureDeviceId();
    pin = PinService(db.settingsDao);
    jobs = JobsRepository(db, device);
    promotion = CatalogPromotion(db, pin, device);
    final maintenance = MaintenanceRepository(db, pin, device);
    category = await maintenance.createCategory('Synthetic category');
    style = await maintenance.createStyle(
      categoryId: category,
      name: 'Synthetic type',
    );
    variant = await maintenance.createType(
      styleId: style,
      name: 'Synthetic variant',
    );
    job = await jobs.createJob('Synthetic promotion job');
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await initialize();
  });
  tearDown(() async => db.close());

  Future<Map<String, Object>> snapshot() async => {
    'parts': await db.select(db.parts).get(),
    'jobs': await db.select(db.jobs).get(),
    'lines': await db.select(db.jobLines).get(),
    'splits': await db.select(db.orderSplits).get(),
  };

  Future<String> originalLine() async {
    await db.partsDao.insertGeneralPart(
      id: 'historical-part',
      name: 'Legacy part',
      deviceId: device,
    );
    await db.partsDao.softDeletePart('historical-part');
    final id = await jobs.addLine(
      jobId: job,
      partId: 'historical-part',
      brandVersionId: 'historical-version',
      customNotes: 'Keep custom notes',
      notes: 'Keep line notes',
      uom: 'box',
      neededQty: 7,
      shopPullQty: 2,
      splits: [(supplierId: 'historical-supplier', qty: 1)],
    );
    await jobs.replaceOrderSplits(id, [
      (supplierId: 'historical-supplier', qty: 5),
    ]);
    return id;
  }

  Future<({String partId, String lineId})> promote({
    String? lineId,
    String? jobId,
    String? categoryId,
    String? styleId,
    String? typeId,
    String name = 'Promoted part',
    double needed = 9,
    double shop = 3,
    List<({String supplierId, double qty})> splits = const [
      (supplierId: 'historical-supplier', qty: 4),
    ],
  }) => promotion.promote(
    jobId: jobId ?? job,
    lineId: lineId,
    name: name,
    categoryId: categoryId ?? category,
    styleId: styleId ?? style,
    typeId: typeId ?? variant,
    neededQty: needed,
    shopPullQty: shop,
    splits: splits,
  );

  for (final editing in [false, true]) {
    for (final failure in ['line', 'split']) {
      test(
        '${editing ? 'edit' : 'new'} promotion $failure failure restores every prior business row',
        () async {
          final lineId = editing ? await originalLine() : null;
          final before = await snapshot();
          final table = failure == 'line' ? 'job_lines' : 'order_splits';
          final event = failure == 'line' && editing ? 'UPDATE' : 'INSERT';
          final splitCondition = failure == 'split'
              ? 'AND NEW.quantity = 99'
              : '';
          await db.customStatement(
            "CREATE TRIGGER reject_promotion BEFORE $event ON $table WHEN EXISTS (SELECT 1 FROM parts WHERE name = 'Promoted part') $splitCondition BEGIN SELECT RAISE(ABORT, 'synthetic failure after catalog creation'); END",
          );
          await expectLater(
            promote(
              lineId: lineId,
              splits: [
                (supplierId: 'historical-supplier', qty: 1),
                (supplierId: 'second-historical-supplier', qty: 99),
              ],
            ),
            throwsA(
              predicate(
                (error) => error.toString().contains(
                  'synthetic failure after catalog creation',
                ),
              ),
            ),
          );
          expect(await snapshot(), before);
        },
      );
    }
  }

  test('successful existing promotion preserves identity metadata and historical split reference', () async {
    final id = await originalLine();
    final old = (await jobs.getJobLine(id))!;
    final result = await promote(lineId: id);
    final part = (await db.partsDao.getPart(result.partId))!;
    final saved = (await jobs.getJobLine(id))!;
    expect(result.lineId, id);
    expect(saved.partId, result.partId);
    expect(saved.brandVersionId, isNull);
    expect(saved.customName, isNull);
    expect(saved.customNotes, old.customNotes);
    expect(saved.notes, old.notes);
    expect(saved.uom, old.uom);
    expect(saved.originDeviceId, old.originDeviceId);
    expect(saved.createdAt, old.createdAt);
    expect(saved.jobId, old.jobId);
    expect(saved.revision, old.revision + 1);
    expect(saved.neededQty, 9);
    expect(saved.shopPullQty, 3);
    expect(
      (part.categoryId, part.styleId, part.typeId),
      (category, style, variant),
    );
    expect(
      (await jobs.orderSplitsForLine(id)).single.supplierId,
      'historical-supplier',
    );
    expect(
      (await db.partsDao.getPart(
        'historical-part',
        includeDeleted: true,
      ))!.deletedAt,
      isNotNull,
    );
  });

  test('missing deleted or mismatched targets refuse promotion without stray parts', () async {
    final id = await originalLine();
    final other = await jobs.createJob('Other job');
    for (final args in [
      (jobId: 'missing-job', lineId: null),
      (jobId: job, lineId: 'missing-line'),
      (jobId: other, lineId: id),
    ]) {
      final before = await snapshot();
      await expectLater(
        promote(jobId: args.jobId, lineId: args.lineId),
        throwsStateError,
      );
      expect(await snapshot(), before);
    }
    await jobs.removeLine(id);
    var before = await snapshot();
    await expectLater(promote(lineId: id), throwsStateError);
    expect(await snapshot(), before);
    await db.customStatement('UPDATE jobs SET deleted_at = 1 WHERE id = ?', [
      job,
    ]);
    before = await snapshot();
    await expectLater(promote(), throwsStateError);
    expect(await snapshot(), before);
  });

  test('incomplete hierarchy invalid name and quantities roll back catalog creation', () async {
    final before = await snapshot();
    for (final request in [
      () => promote(name: ''),
      () => promote(categoryId: ''),
      () => promote(styleId: 'missing-style'),
      () => promote(typeId: 'missing-variant'),
      () => promote(needed: double.infinity),
      () => promote(shop: -1),
      () => promote(
        splits: [(supplierId: 'historical-supplier', qty: double.nan)],
      ),
    ]) {
      await expectLater(request(), throwsStateError);
      expect(await snapshot(), before);
    }
  });

  test('current PIN and company fences refuse new and existing promotion without writes', () async {
    final id = await originalLine();
    await pin.setPin('2468');
    var before = await snapshot();
    for (final lineId in [null, id]) {
      await expectLater(promote(lineId: lineId), throwsStateError);
      expect(await snapshot(), before);
    }
    await pin.unlock('2468');
    pin.lock();
    await expectLater(promote(lineId: id), throwsStateError);
    expect(await snapshot(), before);
    await pin.unlock('2468');
    await db.customStatement(
      'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
      ['synthetic-promotion-blocker', 1, 'blocked', 'synthetic-refusal-marker'],
    );
    before = await snapshot();
    for (final lineId in [null, id]) {
      await expectLater(promote(lineId: lineId), throwsStateError);
      expect(await snapshot(), before);
    }
  });

  test(
    'new and existing promotion results survive file-backed reopen exactly',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atomic-promotion-',
      );
      final file = File('${directory.path}/synthetic.sqlite');
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      await initialize();
      final id = await originalLine();
      final existing = await promote(lineId: id);
      final added = await promote(name: 'Second promoted part');
      expect(existing.lineId, id);
      expect(added.lineId, isNot(id));
      expect(added.partId, isNot(existing.partId));
      final before = await snapshot();
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      jobs = JobsRepository(db, device);
      try {
        expect(await snapshot(), before);
        expect(
          (await jobs.getJobLine(existing.lineId))!.partId,
          existing.partId,
        );
        expect((await jobs.getJobLine(added.lineId))!.partId, added.partId);
        expect(
          (await jobs.orderSplitsForLine(existing.lineId)).single.quantity,
          4,
        );
        expect(
          (await jobs.orderSplitsForLine(added.lineId)).single.quantity,
          4,
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
        db = AppDatabase.forTesting(NativeDatabase.memory());
      }
    },
  );
}
