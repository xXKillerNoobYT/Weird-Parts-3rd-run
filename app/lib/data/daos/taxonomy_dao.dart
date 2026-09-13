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

  Future<void> renameCategory(String id, String name) async {
    final now = DateTime.now().toUtc();
    await (update(categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion.custom(
        name: Variable(name),
        modifiedAt: Variable(now),
        revision: categories.revision + const Constant(1),
      ),
    );
  }

  Future<void> renameStyle(String id, String name) async {
    final now = DateTime.now().toUtc();
    await (update(styles)..where((t) => t.id.equals(id))).write(
      StylesCompanion.custom(
        name: Variable(name),
        modifiedAt: Variable(now),
        revision: styles.revision + const Constant(1),
      ),
    );
  }

  Future<void> renameType(String id, String name) async {
    final now = DateTime.now().toUtc();
    await (update(types)..where((t) => t.id.equals(id))).write(
      TypesCompanion.custom(
        name: Variable(name),
        modifiedAt: Variable(now),
        revision: types.revision + const Constant(1),
      ),
    );
  }

  Future<void> renameBrand(String id, String name) async {
    final now = DateTime.now().toUtc();
    await (update(brands)..where((t) => t.id.equals(id))).write(
      BrandsCompanion.custom(
        name: Variable(name),
        modifiedAt: Variable(now),
        revision: brands.revision + const Constant(1),
      ),
    );
  }

  Future<bool> isCategoryEmpty(String id) async {
    final styles = await listStyles(categoryId: id);
    if (styles.isNotEmpty) return false;
    return !await db.partsDao.hasLiveParts(categoryId: id);
  }

  Future<bool> isStyleEmpty(String id) async {
    final types = await listTypes(styleId: id);
    if (types.isNotEmpty) return false;
    return !await db.partsDao.hasLiveParts(styleId: id);
  }

  Future<bool> isTypeEmpty(String id) async {
    return !await db.partsDao.hasLiveParts(typeId: id);
  }

  Future<void> softDeleteCategory(String id) async {
    await _tombstoneCategories(id);
  }

  Future<void> softDeleteStyle(String id) async {
    await _tombstoneStyles(id);
  }

  Future<void> softDeleteType(String id) async {
    await _tombstoneTypes(id);
  }

  Future<void> _tombstoneCategories(String id) async {
    final now = DateTime.now().toUtc();
    await (update(categories)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
      CategoriesCompanion.custom(
        deletedAt: Variable(now),
        modifiedAt: Variable(now),
        revision: categories.revision + const Constant(1),
      ),
    );
  }

  Future<void> _tombstoneStyles(String id) async {
    final now = DateTime.now().toUtc();
    await (update(styles)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
      StylesCompanion.custom(
        deletedAt: Variable(now),
        modifiedAt: Variable(now),
        revision: styles.revision + const Constant(1),
      ),
    );
  }

  Future<void> _tombstoneTypes(String id) async {
    final now = DateTime.now().toUtc();
    await (update(types)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
      TypesCompanion.custom(
        deletedAt: Variable(now),
        modifiedAt: Variable(now),
        revision: types.revision + const Constant(1),
      ),
    );
  }
}
