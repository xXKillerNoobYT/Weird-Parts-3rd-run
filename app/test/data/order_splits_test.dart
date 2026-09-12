import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  test('job line tracks needed, shop pull, and split orders', () async {
    final deviceId = await db.settingsDao.ensureDeviceId();
    final s1 = await db.taxonomyDao.insertSupplier(id: newId(), name: 'A', deviceId: deviceId);
    final s2 = await db.taxonomyDao.insertSupplier(id: newId(), name: 'B', deviceId: deviceId);
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Valve',
      defaultSupplierId: s1,
      deviceId: deviceId,
    );
    final jobId = await db.jobsDao.insertJob(
      id: newId(),
      name: 'Boiler swap',
      deviceId: deviceId,
    );
    final lineId = await db.jobsDao.insertJobLine(
      id: newId(),
      jobId: jobId,
      partId: partId,
      brandVersionId: null,
      neededQty: 10,
      shopPullQty: 4,
      deviceId: deviceId,
    );
    await db.jobsDao.insertOrderSplit(id: newId(), jobLineId: lineId, supplierId: s1, qty: 3, deviceId: deviceId);
    await db.jobsDao.insertOrderSplit(id: newId(), jobLineId: lineId, supplierId: s2, qty: 3, deviceId: deviceId);

    final line = await db.jobsDao.getJobLine(lineId);
    expect(line!.neededQty, 10);
    expect(line.shopPullQty, 4);
    final splits = await db.jobsDao.orderSplitsForLine(lineId);
    expect(splits, hasLength(2));
    expect(splits.map((s) => s.quantity).fold<double>(0, (a, b) => a + b), 6);
  });
}
