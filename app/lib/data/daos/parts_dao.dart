import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/parts.dart';

part 'parts_dao.g.dart';

@DriftAccessor(tables: [Parts, PartDevices, BrandVersions, SupplierListings])
class PartsDao extends DatabaseAccessor<AppDatabase> with _$PartsDaoMixin {
  PartsDao(super.db);

  Future<String> insertGeneralPart({
    required String id,
    required String name,
    required String deviceId,
    String? defaultSupplierId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(parts).insert(
      PartsCompanion.insert(
        id: id,
        name: name,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
        defaultSupplierId: Value(defaultSupplierId),
      ),
    );
    return id;
  }

  Future<String> insertBrandVersion({
    required String id,
    required String partId,
    required String brandId,
    required String mpn,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(brandVersions).insert(
      BrandVersionsCompanion.insert(
        id: id,
        partId: partId,
        brandId: brandId,
        mpn: mpn,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<String> insertSupplierListing({
    required String id,
    required String brandVersionId,
    required String supplierId,
    required String sku,
    required String deviceId,
  }) async {
    final now = DateTime.now().toUtc();
    await into(supplierListings).insert(
      SupplierListingsCompanion.insert(
        id: id,
        brandVersionId: brandVersionId,
        supplierId: supplierId,
        sku: sku,
        originDeviceId: deviceId,
        createdAt: now,
        modifiedAt: now,
      ),
    );
    return id;
  }

  Future<Part?> getPart(String partId) {
    return (select(parts)
          ..where((t) => t.id.equals(partId) & t.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<void> updatePart({
    required String id,
    required String name,
    required String description,
    required String uom,
    String? defaultSupplierId,
    required bool active,
  }) async {
    final now = DateTime.now().toUtc();
    await (update(parts)..where((t) => t.id.equals(id))).write(
      PartsCompanion(
        name: Value(name),
        description: Value(description),
        uom: Value(uom),
        defaultSupplierId: Value(defaultSupplierId),
        active: Value(active),
        modifiedAt: Value(now),
      ),
    );
  }

  Future<List<Part>> listParts({bool activeOnly = true}) {
    final q = select(parts)..where((t) => t.deletedAt.isNull());
    if (activeOnly) {
      q.where((t) => t.active.equals(true));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.get();
  }

  Future<List<BrandVersion>> listBrandVersionsForPart(String partId) {
    return (select(brandVersions)
          ..where((t) => t.partId.equals(partId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.mpn)]))
        .get();
  }

  Future<List<SupplierListing>> listingsForBrandVersion(String bvId) {
    return (select(supplierListings)
          ..where(
            (t) => t.brandVersionId.equals(bvId) & t.deletedAt.isNull(),
          ))
        .get();
  }
}
