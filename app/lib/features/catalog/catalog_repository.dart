import '../../core/new_id.dart';
import '../../data/app_database.dart';
import '../pin/pin_service.dart';

class CatalogRepository {
  CatalogRepository(this._db, this._pin, this._deviceId);

  final AppDatabase _db;
  final PinService _pin;
  final String _deviceId;

  Future<List<Part>> listParts({bool activeOnly = true}) =>
      _db.partsDao.listParts(activeOnly: activeOnly);

  Future<Part?> getPart(String partId) => _db.partsDao.getPart(partId);

  Future<List<BrandVersion>> listBrandVersionsForPart(String partId) =>
      _db.partsDao.listBrandVersionsForPart(partId);

  Future<List<SupplierListing>> listingsForBrandVersion(String bvId) =>
      _db.partsDao.listingsForBrandVersion(bvId);

  Future<String> createGeneralPart({
    required String name,
    String? defaultSupplierId,
  }) async {
    await _pin.requireUnlocked();
    return _db.partsDao.insertGeneralPart(
      id: newId(),
      name: name,
      deviceId: _deviceId,
      defaultSupplierId: defaultSupplierId,
    );
  }

  Future<void> updatePart({
    required String partId,
    required String name,
    required String description,
    required String uom,
    String? defaultSupplierId,
    required bool active,
  }) async {
    await _pin.requireUnlocked();
    await _db.partsDao.updatePart(
      id: partId,
      name: name,
      description: description,
      uom: uom,
      defaultSupplierId: defaultSupplierId,
      active: active,
    );
  }

  Future<String> createBrandVersion({
    required String partId,
    required String brandId,
    required String mpn,
  }) async {
    await _pin.requireUnlocked();
    return _db.partsDao.insertBrandVersion(
      id: newId(),
      partId: partId,
      brandId: brandId,
      mpn: mpn,
      deviceId: _deviceId,
    );
  }

  Future<String> createSupplierListing({
    required String brandVersionId,
    required String supplierId,
    required String sku,
  }) async {
    await _pin.requireUnlocked();
    return _db.partsDao.insertSupplierListing(
      id: newId(),
      brandVersionId: brandVersionId,
      supplierId: supplierId,
      sku: sku,
      deviceId: _deviceId,
    );
  }
}
