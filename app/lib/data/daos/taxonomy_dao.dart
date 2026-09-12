import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/taxonomy.dart';

part 'taxonomy_dao.g.dart';

@DriftAccessor(tables: [Categories, Styles, Types, Devices, Brands, Suppliers])
class TaxonomyDao extends DatabaseAccessor<AppDatabase>
    with _$TaxonomyDaoMixin {
  TaxonomyDao(super.db);

  Future<String> insertCategory({
    required String id,
    required String name,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(categories).insert(
      CategoriesCompanion.insert(
        id: id,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<String> insertStyle({
    required String id,
    required String categoryId,
    required String name,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(styles).insert(
      StylesCompanion.insert(
        id: id,
        categoryId: categoryId,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<String> insertType({
    required String id,
    required String styleId,
    required String name,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(types).insert(
      TypesCompanion.insert(
        id: id,
        styleId: styleId,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<String> insertDevice({
    required String id,
    required String name,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(devices).insert(
      DevicesCompanion.insert(
        id: id,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

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

  Future<List<Category>> listCategories() {
    return (select(categories)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
  }

  Future<List<Style>> listStyles({String? categoryId}) {
    final q = select(styles)..where((t) => t.deletedAt.isNull());
    if (categoryId != null) {
      q.where((t) => t.categoryId.equals(categoryId));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.get();
  }

  Future<List<Type>> listTypes({String? styleId}) {
    final q = select(types)..where((t) => t.deletedAt.isNull());
    if (styleId != null) {
      q.where((t) => t.styleId.equals(styleId));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.get();
  }

  Future<List<Device>> listDevices() {
    return (select(devices)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
  }

  Future<List<Brand>> listBrands() {
    return (select(brands)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
  }

  Future<List<Supplier>> listSuppliers() {
    return (select(suppliers)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
  }
}
