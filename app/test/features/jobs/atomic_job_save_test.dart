import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/job_line_qty.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late AppDatabase db;
  late String device;
  late JobsRepository jobs;
  late String job;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    device = await db.settingsDao.ensureDeviceId();
    jobs = JobsRepository(db, device);
    job = await jobs.createJob('Synthetic atomic job');
  });
  tearDown(() async => db.close());

  Future<Map<String, Object>> snapshot() async => {
    'jobs': await db.select(db.jobs).get(),
    'lines': await db.select(db.jobLines).get(),
    'splits': await db.select(db.orderSplits).get(),
  };

  Future<void> update(
    String id, {
    double needed = 9,
    double shop = 3,
    List<({String supplierId, double qty})>? splits,
  }) => jobs.updateLine(
    lineId: id,
    partId: null,
    brandVersionId: null,
    customName: 'Updated name',
    customNotes: 'Updated custom notes',
    uom: 'box',
    notes: 'Updated notes',
    neededQty: needed,
    shopPullQty: shop,
    splits: splits,
  );

  Future<String> originalLine() async {
    final id = await jobs.addLine(
      jobId: job,
      customName: 'Original name',
      customNotes: 'Original custom notes',
      notes: 'Original notes',
      uom: 'ea',
      neededQty: 7,
      shopPullQty: 2,
      splits: [(supplierId: 'historical-supplier', qty: 1)],
    );
    await jobs.replaceOrderSplits(id, [
      (supplierId: 'historical-supplier', qty: 5),
    ]);
    return id;
  }

  Future<void> failSecondSplit() => db.customStatement(
    "CREATE TRIGGER reject_second_split BEFORE INSERT ON order_splits WHEN NEW.quantity = 99 BEGIN SELECT RAISE(ABORT, 'synthetic second split failure'); END",
  );

  test(
    'missing and deleted Job refuse new bundled line without writes',
    () async {
      for (final jobId in ['missing-job', job]) {
        if (jobId == job) {
          await db.customStatement(
            'UPDATE jobs SET deleted_at = 1 WHERE id = ?',
            [job],
          );
        }
        final before = await snapshot();
        await expectLater(
          jobs.addLine(
            jobId: jobId,
            customName: 'Orphan',
            neededQty: 1,
            splits: [(supplierId: 'historical-supplier', qty: 1)],
          ),
          throwsStateError,
        );
        expect(await snapshot(), before);
      }
    },
  );

  test('missing and deleted line refuse update pull replace and attach without writes', () async {
    final id = await originalLine();
    await jobs.removeLine(id);
    for (final line in ['missing-line', id]) {
      final before = await snapshot();
      await expectLater(
        update(line, splits: [(supplierId: 'historical-supplier', qty: 1)]),
        throwsStateError,
      );
      expect(await snapshot(), before);
      await expectLater(jobs.setShopPull(line, 3), throwsStateError);
      expect(await snapshot(), before);
      await expectLater(
        jobs.replaceOrderSplits(line, [
          (supplierId: 'historical-supplier', qty: 1),
        ]),
        throwsStateError,
      );
      expect(await snapshot(), before);
      await expectLater(
        jobs.attachCatalogPart(
          lineId: line,
          partId: 'historical-part',
          splits: [(supplierId: 'historical-supplier', qty: 1)],
        ),
        throwsStateError,
      );
      expect(await snapshot(), before);
    }
  });

  test(
    'second split insert failure rolls back new line and first split',
    () async {
      final before = await snapshot();
      await failSecondSplit();
      await expectLater(
        jobs.addLine(
          jobId: job,
          customName: 'Failed line',
          neededQty: 7,
          splits: [
            (supplierId: 'historical-supplier', qty: 1),
            (supplierId: 'another-supplier', qty: 99),
          ],
        ),
        throwsA(anything),
      );
      expect(await snapshot(), before);
    },
  );

  test(
    'second split insert failure restores full edited line and every split row',
    () async {
      final id = await originalLine();
      final before = await snapshot();
      expect(
        (before['splits'] as List<OrderSplit>).where(
          (s) => s.deletedAt != null,
        ),
        hasLength(1),
      );
      await failSecondSplit();
      await expectLater(
        update(
          id,
          splits: [
            (supplierId: 'historical-supplier', qty: 1),
            (supplierId: 'another-supplier', qty: 99),
          ],
        ),
        throwsA(anything),
      );
      expect(await snapshot(), before);
    },
  );

  test(
    'catalog attach and split failure restore original custom line',
    () async {
      final id = await originalLine();
      final before = await snapshot();
      await failSecondSplit();
      await expectLater(
        jobs.attachCatalogPart(
          lineId: id,
          partId: 'historical-part',
          neededQty: 12,
          shopPullQty: 5,
          splits: [
            (supplierId: 'historical-supplier', qty: 1),
            (supplierId: 'another-supplier', qty: 99),
          ],
        ),
        throwsA(anything),
      );
      expect(await snapshot(), before);
    },
  );

  test('omitted splits preserve every existing row and empty splits clear active rows', () async {
    final id = await originalLine();
    final oldLine = (await jobs.getJobLine(id))!;
    final oldSplits = await db.select(db.orderSplits).get();
    await update(id);
    expect(await db.select(db.orderSplits).get(), oldSplits);
    var line = (await jobs.getJobLine(id))!;
    expect(line.id, id);
    expect(line.jobId, job);
    expect(line.originDeviceId, oldLine.originDeviceId);
    expect(line.createdAt, oldLine.createdAt);
    expect(line.revision, oldLine.revision + 1);
    await update(id, splits: []);
    expect(await jobs.orderSplitsForLine(id), isEmpty);
    final after = await db.select(db.orderSplits).get();
    final oldTombstone = oldSplits.singleWhere((s) => s.deletedAt != null);
    expect(after.singleWhere((s) => s.id == oldTombstone.id), oldTombstone);
    final oldActive = oldSplits.singleWhere((s) => s.deletedAt == null);
    expect(
      after.singleWhere((s) => s.id == oldActive.id).revision,
      oldActive.revision + 1,
    );
  });

  test('nonfinite and negative line quantities refuse every public quantity writer without writes', () async {
    final id = await originalLine();
    final before = await snapshot();
    for (final value in [
      -1.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      await expectLater(
        jobs.addLine(jobId: job, neededQty: value),
        throwsStateError,
      );
      await expectLater(
        jobs.addLine(jobId: job, neededQty: 1, shopPullQty: value),
        throwsStateError,
      );
      await expectLater(update(id, needed: value), throwsStateError);
      await expectLater(update(id, shop: value), throwsStateError);
      await expectLater(jobs.setShopPull(id, value), throwsStateError);
      await expectLater(
        jobs.attachCatalogPart(
          lineId: id,
          partId: 'historical-part',
          neededQty: value,
        ),
        throwsStateError,
      );
      await expectLater(
        jobs.attachCatalogPart(
          lineId: id,
          partId: 'historical-part',
          shopPullQty: value,
        ),
        throwsStateError,
      );
      expect(await snapshot(), before);
    }
  });

  test('nonpositive and nonfinite splits refuse bundled and separate public writes', () async {
    final id = await originalLine();
    final before = await snapshot();
    for (final value in [
      0.0,
      -1.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      final splits = [(supplierId: 'historical-supplier', qty: value)];
      await expectLater(
        jobs.addLine(jobId: job, neededQty: 1, splits: splits),
        throwsStateError,
      );
      await expectLater(update(id, splits: splits), throwsStateError);
      await expectLater(jobs.replaceOrderSplits(id, splits), throwsStateError);
      await expectLater(
        jobs.attachCatalogPart(
          lineId: id,
          partId: 'historical-part',
          splits: splits,
        ),
        throwsStateError,
      );
      expect(await snapshot(), before);
    }
  });

  test('ordinary Jobs bundle needs no catalog PIN and allows archived Job and finite excess', () async {
    final pin = PinService(db.settingsDao);
    await pin.setPin('2468');
    await jobs.archiveJob(job);
    final id = await jobs.addLine(
      jobId: job,
      neededQty: 1,
      shopPullQty: 2,
      customName: 'Excess is allowed',
      splits: [(supplierId: 'historical-supplier', qty: 3)],
    );
    final line = (await jobs.getJobLine(id))!;
    final splits = await jobs.orderSplitsForLine(id);
    final qty = JobLineQty(
      requested: line.neededQty,
      shop: line.shopPullQty,
      supplierSplits: [
        for (final s in splits)
          JobSupplierSplit(supplierName: 'Historical', qty: s.quantity),
      ],
    );
    expect(qty.leftToPullOrder, -4);
    expect(qty.listSubtitle, contains('Left to Pull/Order -4'));
    await update(id, needed: 0, shop: 0, splits: []);
    expect(pin.isUnlocked, isFalse);
  });

  test('company marker refuses bundles and existing quantity writers without mutation', () async {
    final id = await originalLine();
    await db.customStatement(
      'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
      ['synthetic-job-blocker', 1, 'blocked', 'synthetic-refusal-marker'],
    );
    final before = await snapshot();
    await expectLater(
      jobs.addLine(jobId: job, neededQty: 1, splits: []),
      throwsStateError,
    );
    await expectLater(update(id, splits: []), throwsStateError);
    await expectLater(jobs.setShopPull(id, 1), throwsStateError);
    await expectLater(jobs.replaceOrderSplits(id, []), throwsStateError);
    await expectLater(
      jobs.attachCatalogPart(lineId: id, partId: 'historical-part', splits: []),
      throwsStateError,
    );
    expect(await snapshot(), before);
  });

  test(
    'bundled line metadata IDs and all split rows survive file-backed reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atomic-job-save-',
      );
      final file = File('${directory.path}/synthetic.sqlite');
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      device = await db.settingsDao.ensureDeviceId();
      jobs = JobsRepository(db, device);
      job = await jobs.createJob('File-backed job');
      final id = await originalLine();
      await update(
        id,
        splits: [
          (supplierId: 'historical-supplier', qty: 3),
          (supplierId: 'historical-second-supplier', qty: 4),
        ],
      );
      final before = await snapshot();
      final saved = (await jobs.getJobLine(id))!;
      expect(saved.customNotes, 'Updated custom notes');
      expect(saved.uom, 'box');
      expect(saved.notes, 'Updated notes');
      expect(saved.neededQty, 9);
      expect(saved.shopPullQty, 3);
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      jobs = JobsRepository(db, device);
      try {
        expect(await snapshot(), before);
        expect((await jobs.getJobLine(id))!.id, id);
        expect(await jobs.orderSplitsForLine(id), hasLength(2));
        expect(await db.settingsDao.ensureDeviceId(), device);
      } finally {
        await db.close();
        await directory.delete(recursive: true);
        db = AppDatabase.forTesting(NativeDatabase.memory());
      }
    },
  );
}
