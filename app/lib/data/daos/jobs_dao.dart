import 'package:drift/drift.dart';

import '../../core/new_id.dart';
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

  Future<List<Job>> listActiveJobs() {
    return (select(jobs)
          ..where((t) => t.status.equals('active') & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.modifiedAt)]))
        .get();
  }

  Future<void> archiveJob(String id) async {
    final now = DateTime.now().toUtc();
    await (update(jobs)..where((t) => t.id.equals(id))).write(
      JobsCompanion(
        status: const Value('archived'),
        modifiedAt: Value(now),
      ),
    );
  }

  Future<Job?> getJob(String id) {
    return (select(jobs)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<List<JobLine>> listLinesForJob(String jobId) {
    return (select(jobLines)
          ..where((t) => t.jobId.equals(jobId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
  }

  Future<String> insertJobLine({
    required String id,
    required String jobId,
    required String? partId,
    required String? brandVersionId,
    required double neededQty,
    required double shopPullQty,
    required String deviceId,
    String? customName,
    String? customNotes,
    String? uom,
    String? notes,
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
        customName: Value(customName),
        customNotes: Value(customNotes),
        uom: Value(uom),
        notes: Value(notes),
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  /// Rewrites identity/qty fields, including clearing nullables with [Value(null)].
  Future<void> updateJobLine({
    required String id,
    required String? partId,
    required String? brandVersionId,
    required String? customName,
    String? customNotes,
    required double neededQty,
    required double shopPullQty,
    String? uom,
    String? notes,
  }) async {
    final now = DateTime.now().toUtc();
    await (update(jobLines)..where((t) => t.id.equals(id))).write(
      JobLinesCompanion(
        partId: Value(partId),
        brandVersionId: Value(brandVersionId),
        customName: Value(customName),
        customNotes: Value(customNotes),
        neededQty: Value(neededQty),
        shopPullQty: Value(shopPullQty),
        uom: Value(uom),
        notes: Value(notes),
        modifiedAt: Value(now),
      ),
    );
  }

  Future<void> setShopPull(String lineId, double qty) async {
    final now = DateTime.now().toUtc();
    await (update(jobLines)..where((t) => t.id.equals(lineId))).write(
      JobLinesCompanion(
        shopPullQty: Value(qty),
        modifiedAt: Value(now),
      ),
    );
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

  /// Soft-deletes existing non-tombstone splits, then inserts [splits].
  Future<void> replaceOrderSplits({
    required String lineId,
    required List<({String supplierId, double qty})> splits,
    required String deviceId,
  }) async {
    await transaction(() async {
      final now = DateTime.now().toUtc();
      await (update(orderSplits)
            ..where(
              (t) => t.jobLineId.equals(lineId) & t.deletedAt.isNull(),
            ))
          .write(
        OrderSplitsCompanion(
          deletedAt: Value(now),
          modifiedAt: Value(now),
        ),
      );
      for (final split in splits) {
        await insertOrderSplit(
          id: newId(),
          jobLineId: lineId,
          supplierId: split.supplierId,
          qty: split.qty,
          deviceId: deviceId,
        );
      }
    });
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
