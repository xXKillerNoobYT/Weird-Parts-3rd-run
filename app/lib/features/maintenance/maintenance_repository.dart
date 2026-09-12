import '../../core/new_id.dart';
import '../../data/app_database.dart';
import '../pin/pin_service.dart';

class MaintenanceRepository {
  MaintenanceRepository(this._db, this._pin, this._deviceId);

  final AppDatabase _db;
  final PinService _pin;
  final String _deviceId;

  Future<List<Category>> listCategories() => _db.taxonomyDao.listCategories();

  Future<List<Style>> listStyles({String? categoryId}) =>
      _db.taxonomyDao.listStyles(categoryId: categoryId);

  Future<List<Type>> listTypes({String? styleId}) =>
      _db.taxonomyDao.listTypes(styleId: styleId);

  Future<List<Device>> listDevices() => _db.taxonomyDao.listDevices();

  Future<List<Brand>> listBrands() => _db.taxonomyDao.listBrands();

  Future<List<Supplier>> listSuppliers() => _db.taxonomyDao.listSuppliers();

  Future<String> createCategory(String name) async {
    await _pin.requireUnlocked();
    return _db.taxonomyDao.insertCategory(
      id: newId(),
      name: name,
      deviceId: _deviceId,
    );
  }

  Future<String> createStyle({
    required String categoryId,
    required String name,
  }) async {
    await _pin.requireUnlocked();
    return _db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: categoryId,
      name: name,
      deviceId: _deviceId,
    );
  }

  Future<String> createType({
    required String styleId,
    required String name,
  }) async {
    await _pin.requireUnlocked();
    return _db.taxonomyDao.insertType(
      id: newId(),
      styleId: styleId,
      name: name,
      deviceId: _deviceId,
    );
  }

  Future<String> createDevice(String name) async {
    await _pin.requireUnlocked();
    return _db.taxonomyDao.insertDevice(
      id: newId(),
      name: name,
      deviceId: _deviceId,
    );
  }

  Future<String> createBrand(String name) async {
    await _pin.requireUnlocked();
    return _db.taxonomyDao.insertBrand(
      id: newId(),
      name: name,
      deviceId: _deviceId,
    );
  }

  Future<String> createSupplier(String name) async {
    await _pin.requireUnlocked();
    return _db.taxonomyDao.insertSupplier(
      id: newId(),
      name: name,
      deviceId: _deviceId,
    );
  }
}
