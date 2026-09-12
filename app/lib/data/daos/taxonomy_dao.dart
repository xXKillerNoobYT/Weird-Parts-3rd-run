import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/taxonomy.dart';

part 'taxonomy_dao.g.dart';

@DriftAccessor(tables: [Categories, Styles, Types, Devices, Brands, Suppliers])
class TaxonomyDao extends DatabaseAccessor<AppDatabase>
    with _$TaxonomyDaoMixin {
  TaxonomyDao(super.db);

  Future<String> insertSupplier({
    required String id,
    required String name,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(suppliers).insert(
      SuppliersCompanion.insert(
        id: id,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<String> insertBrand({
    required String id,
    required String name,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(brands).insert(
      BrandsCompanion.insert(
        id: id,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }
}
