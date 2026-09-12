import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/jobs.dart';

part 'jobs_dao.g.dart';

@DriftAccessor(tables: [Jobs, JobLines, OrderSplits])
class JobsDao extends DatabaseAccessor<AppDatabase> with _$JobsDaoMixin {
  JobsDao(super.db);

  Future<String> insertJob({
    required String id,
    required String name,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(jobs).insert(
      JobsCompanion.insert(
        id: id,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<String> insertJobLine({
    required String id,
    required String jobId,
    required String? partId,
    required String? brandVersionId,
    required double neededQty,
    required double shopPullQty,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(jobLines).insert(
      JobLinesCompanion.insert(
        id: id,
        jobId: jobId,
        partId: Value(partId),
        brandVersionId: Value(brandVersionId),
        neededQty: neededQty,
        shopPullQty: Value(shopPullQty),
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<String> insertOrderSplit({
    required String id,
    required String jobLineId,
    required String supplierId,
    required double qty,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(orderSplits).insert(
      OrderSplitsCompanion.insert(
        id: id,
        jobLineId: jobLineId,
        supplierId: supplierId,
        quantity: qty,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<JobLine?> getJobLine(String lineId) {
    return (select(jobLines)
          ..where((t) => t.id.equals(lineId) & t.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<List<OrderSplit>> orderSplitsForLine(String lineId) {
    return (select(orderSplits)
          ..where((t) => t.jobLineId.equals(lineId) & t.deletedAt.isNull()))
        .get();
  }
}
