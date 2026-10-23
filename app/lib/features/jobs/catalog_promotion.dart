import '../../data/app_database.dart';
import '../catalog/catalog_repository.dart';
import '../company/company_store_markers.dart';
import '../pin/pin_service.dart';
import 'jobs_repository.dart';

class CatalogPromotion {
  CatalogPromotion(this._db, this._pin, String deviceId)
    : _catalog = CatalogRepository(_db, _pin, deviceId),
      _jobs = JobsRepository(_db, deviceId);

  final AppDatabase _db;
  final PinService _pin;
  final CatalogRepository _catalog;
  final JobsRepository _jobs;

  Future<({String partId, String lineId})> promote({
    required String jobId,
    String? lineId,
    String? reservedNewLineId,
    String? reservedPartId,
    required String name,
    required String categoryId,
    required String styleId,
    required String typeId,
    required double neededQty,
    required double shopPullQty,
    required List<({String supplierId, double qty})> splits,
  }) async {
    final savedSplits = List.of(splits);
    return legacyBusinessWrite(_db, () async {
      await _pin.requireUnlocked();
      if (await _jobs.getJob(jobId) == null) {
        throw StateError('Job no longer exists');
      }
      final line = lineId == null ? null : await _jobs.getJobLine(lineId);
      if (lineId != null && (line == null || line.jobId != jobId)) {
        throw StateError('Job line no longer belongs to this job');
      }
      if (reservedPartId != null &&
          await (_db.select(_db.parts)
                    ..where((row) => row.id.equals(reservedPartId)))
                  .getSingleOrNull() !=
              null) {
        throw StateError('Reserved Part ID is already in use');
      }
      final partId = await _catalog.createGeneralPart(
        reservedId: reservedPartId,
        name: name,
        categoryId: categoryId,
        styleId: styleId,
        typeId: typeId,
      );
      final String savedLineId;
      if (line != null) {
        await _jobs.attachCatalogPart(
          lineId: line.id,
          partId: partId,
          neededQty: neededQty,
          shopPullQty: shopPullQty,
          splits: savedSplits,
        );
        savedLineId = line.id;
      } else {
        savedLineId = await _jobs.addLine(
          jobId: jobId,
          reservedLineId: reservedNewLineId,
          partId: partId,
          neededQty: neededQty,
          shopPullQty: shopPullQty,
          splits: savedSplits,
        );
      }
      await _pin.requireUnlocked();
      return (partId: partId, lineId: savedLineId);
    });
  }
}
