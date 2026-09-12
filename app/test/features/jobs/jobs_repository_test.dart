import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';

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

  test('create job, add line with splits, archive', () async {
    final s1 = await db.taxonomyDao.insertSupplier(
      id: newId(),
      name: 'A',
      deviceId: deviceId,
    );
    final s2 = await db.taxonomyDao.insertSupplier(
      id: newId(),
      name: 'B',
      deviceId: deviceId,
    );
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Valve',
      defaultSupplierId: s1,
      deviceId: deviceId,
    );

    final jobId = await jobs.createJob('Boiler swap');
    final active = await jobs.listActiveJobs();
    expect(active.map((j) => j.id), contains(jobId));

    final lineId = await jobs.addLine(
      jobId: jobId,
      partId: partId,
      neededQty: 10,
      shopPullQty: 4,
    );
    final created = await jobs.getJobLine(lineId);
    expect(created!.revision, 1);

    await jobs.replaceOrderSplits(lineId, [
      (supplierId: s1, qty: 3),
      (supplierId: s2, qty: 3),
    ]);

    final lines = await jobs.listLinesForJob(jobId);
    expect(lines, hasLength(1));
    expect(lines.first.neededQty, 10);
    expect(lines.first.shopPullQty, 4);
    final splits = await jobs.orderSplitsForLine(lineId);
    expect(splits.map((s) => s.quantity).fold<double>(0, (a, b) => a + b), 6);
    expect(splits.every((s) => s.revision == 1), isTrue);

    await jobs.updateLine(
      lineId: lineId,
      partId: null,
      brandVersionId: null,
      customName: 'Custom valve',
      neededQty: 10,
      shopPullQty: 4,
    );
    final updated = await jobs.getJobLine(lineId);
    expect(updated!.partId, isNull);
    expect(updated.customName, 'Custom valve');
    expect(updated.revision, 2);

    await jobs.setShopPull(lineId, 5);
    final pulled = await jobs.getJobLine(lineId);
    expect(pulled!.shopPullQty, 5);
    expect(pulled.revision, 3);

    await jobs.replaceOrderSplits(lineId, [
      (supplierId: s1, qty: 2),
    ]);
    final replaced = await jobs.orderSplitsForLine(lineId);
    expect(replaced, hasLength(1));
    expect(replaced.first.revision, 1);

    await jobs.removeLine(lineId);
    expect(await jobs.listLinesForJob(jobId), isEmpty);
    expect(await jobs.getJobLine(lineId), isNull);

    await jobs.archiveJob(jobId);
    final job = await (db.select(db.jobs)..where((t) => t.id.equals(jobId)))
        .getSingle();
    expect(job.status, 'archived');
    expect(job.revision, 2);
    final after = await jobs.listActiveJobs();
    expect(after.map((j) => j.id), isNot(contains(jobId)));
  });
}
