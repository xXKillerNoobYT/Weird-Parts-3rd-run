import '../../core/new_id.dart';
import '../../data/app_database.dart';
import '../company/company_store_markers.dart';

class JobsRepository {
  JobsRepository(this._db, this._deviceId);

  final AppDatabase _db;
  final String _deviceId;

  Future<String> createJob(String name, {String? reservedJobId}) async {
    final savedName = name.trim();
    if (savedName.isEmpty) throw StateError('Job name is required');
    if (reservedJobId != null && reservedJobId.trim().isEmpty) {
      throw StateError('Reserved Job ID must not be empty');
    }
    return _db.jobsDao.insertJob(
      id: reservedJobId ?? newId(),
      name: savedName,
      deviceId: _deviceId,
    );
  }

  Future<List<Job>> listActiveJobs() => _db.jobsDao.listActiveJobs();

  Future<Job?> getJob(String id) => _db.jobsDao.getJob(id);

  Future<void> archiveJob(String id) => _db.jobsDao.archiveJob(id);

  Future<List<JobLine>> listLinesForJob(String jobId) =>
      _db.jobsDao.listLinesForJob(jobId);

  Future<JobLine?> getJobLine(String lineId) => _db.jobsDao.getJobLine(lineId);

  Future<List<OrderSplit>> orderSplitsForLine(String lineId) =>
      _db.jobsDao.orderSplitsForLine(lineId);

  Future<String> addLine({
    required String jobId,
    String? reservedLineId,
    String? partId,
    String? brandVersionId,
    String? customName,
    String? customNotes,
    required double neededQty,
    double shopPullQty = 0,
    String? uom,
    String? notes,
    List<({String supplierId, double qty})>? splits,
  }) async {
    if (reservedLineId != null && reservedLineId.trim().isEmpty) {
      throw StateError('Reserved Job line ID must not be empty');
    }
    final savedSplits = splits == null ? null : List.of(splits);
    _requireQuantities(neededQty, shopPullQty, savedSplits);
    return legacyBusinessWrite(_db, () async {
      if (await getJob(jobId) == null) throw StateError('Job no longer exists');
      final id = await _db.jobsDao.insertJobLine(
        id: reservedLineId ?? newId(),
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
      if (savedSplits != null) await replaceOrderSplits(id, savedSplits);
      return id;
    });
  }

  Future<void> updateLine({
    required String lineId,
    required String? partId,
    required String? brandVersionId,
    required String? customName,
    required String? customNotes,
    required double neededQty,
    required double shopPullQty,
    required String? uom,
    required String? notes,
    List<({String supplierId, double qty})>? splits,
  }) async {
    final savedSplits = splits == null ? null : List.of(splits);
    _requireQuantities(neededQty, shopPullQty, savedSplits);
    await legacyBusinessWrite(_db, () async {
      await _requireLiveLine(lineId);
      await _db.jobsDao.updateJobLine(
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
      if (savedSplits != null) await replaceOrderSplits(lineId, savedSplits);
    });
  }

  Future<void> setShopPull(String lineId, double qty) async {
    _requireQuantity(qty, 'Shop quantity');
    await legacyBusinessWrite(_db, () async {
      await _requireLiveLine(lineId);
      await _db.jobsDao.setShopPull(lineId, qty);
    });
  }

  Future<void> removeLine(String lineId) {
    return _db.jobsDao.softDeleteJobLine(lineId);
  }

  /// Point a custom line at a catalog part and drop the custom name.
  ///
  /// Pass [neededQty] / [shopPullQty] / [splits] to persist unsaved form
  /// values (edit-mode promote). Stored qty/splits are kept when omitted.
  Future<void> attachCatalogPart({
    required String lineId,
    required String partId,
    double? neededQty,
    double? shopPullQty,
    List<({String supplierId, double qty})>? splits,
  }) async {
    final savedSplits = splits == null ? null : List.of(splits);
    if (neededQty != null) _requireQuantity(neededQty, 'Requested quantity');
    if (shopPullQty != null) _requireQuantity(shopPullQty, 'Shop quantity');
    _requireSplits(savedSplits);
    await legacyBusinessWrite(_db, () async {
      final line = await _requireLiveLine(lineId);
      await updateLine(
        lineId: lineId,
        partId: partId,
        brandVersionId: null,
        customName: null,
        customNotes: line.customNotes,
        neededQty: neededQty ?? line.neededQty,
        shopPullQty: shopPullQty ?? line.shopPullQty,
        uom: line.uom,
        notes: line.notes,
        splits: savedSplits,
      );
    });
  }

  Future<void> replaceOrderSplits(
    String lineId,
    List<({String supplierId, double qty})> splits,
  ) async {
    final savedSplits = List.of(splits);
    _requireSplits(savedSplits);
    await legacyBusinessWrite(_db, () async {
      await _requireLiveLine(lineId);
      await _db.jobsDao.replaceOrderSplits(
        lineId: lineId,
        splits: savedSplits,
        deviceId: _deviceId,
      );
    });
  }

  Future<JobLine> _requireLiveLine(String lineId) async {
    final line = await getJobLine(lineId);
    if (line == null) throw StateError('Job line no longer exists');
    return line;
  }

  static void _requireQuantity(
    double qty,
    String label, {
    bool positive = false,
  }) {
    if (!qty.isFinite || (positive ? qty <= 0 : qty < 0)) {
      throw StateError(
        '$label must be finite and ${positive ? 'greater than zero' : 'nonnegative'}',
      );
    }
  }

  static void _requireSplits(List<({String supplierId, double qty})>? splits) {
    for (final split in splits ?? <({String supplierId, double qty})>[]) {
      _requireQuantity(split.qty, 'Split quantity', positive: true);
    }
  }

  static void _requireQuantities(
    double neededQty,
    double shopPullQty,
    List<({String supplierId, double qty})>? splits,
  ) {
    _requireQuantity(neededQty, 'Requested quantity');
    _requireQuantity(shopPullQty, 'Shop quantity');
    _requireSplits(splits);
  }
}
