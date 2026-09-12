import '../../core/new_id.dart';
import '../../data/app_database.dart';

class JobsRepository {
  JobsRepository(this._db, this._deviceId);

  final AppDatabase _db;
  final String _deviceId;

  Future<String> createJob(String name) {
    return _db.jobsDao.insertJob(
      id: newId(),
      name: name,
      deviceId: _deviceId,
    );
  }

  Future<List<Job>> listActiveJobs() => _db.jobsDao.listActiveJobs();

  Future<Job?> getJob(String id) => _db.jobsDao.getJob(id);

  Future<void> archiveJob(String id) => _db.jobsDao.archiveJob(id);

  Future<List<JobLine>> listLinesForJob(String jobId) =>
      _db.jobsDao.listLinesForJob(jobId);

  Future<JobLine?> getJobLine(String lineId) =>
      _db.jobsDao.getJobLine(lineId);

  Future<List<OrderSplit>> orderSplitsForLine(String lineId) =>
      _db.jobsDao.orderSplitsForLine(lineId);

  Future<String> addLine({
    required String jobId,
    String? partId,
    String? brandVersionId,
    String? customName,
    String? customNotes,
    required double neededQty,
    double shopPullQty = 0,
    String? uom,
    String? notes,
  }) {
    return _db.jobsDao.insertJobLine(
      id: newId(),
      jobId: jobId,
      partId: partId,
      brandVersionId: brandVersionId,
      neededQty: neededQty,
      shopPullQty: shopPullQty,
      deviceId: _deviceId,
      customName: customName,
      customNotes: customNotes,
      uom: uom,
      notes: notes,
    );
  }

  Future<void> updateLine({
    required String lineId,
    required String? partId,
    required String? brandVersionId,
    required String? customName,
    String? customNotes,
    required double neededQty,
    required double shopPullQty,
    String? uom,
    String? notes,
  }) {
    return _db.jobsDao.updateJobLine(
      id: lineId,
      partId: partId,
      brandVersionId: brandVersionId,
      customName: customName,
      customNotes: customNotes,
      neededQty: neededQty,
      shopPullQty: shopPullQty,
      uom: uom,
      notes: notes,
    );
  }

  Future<void> setShopPull(String lineId, double qty) {
    return _db.jobsDao.setShopPull(lineId, qty);
  }

  Future<void> removeLine(String lineId) {
    return _db.jobsDao.softDeleteJobLine(lineId);
  }

  Future<void> replaceOrderSplits(
    String lineId,
    List<({String supplierId, double qty})> splits,
  ) {
    return _db.jobsDao.replaceOrderSplits(
      lineId: lineId,
      splits: splits,
      deviceId: _deviceId,
    );
  }
}
