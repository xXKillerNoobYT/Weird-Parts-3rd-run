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

  Future<List<Part>> listParts() {
    return (select(parts)
          ..where((t) => t.deletedAt.isNull() & t.active.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
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
