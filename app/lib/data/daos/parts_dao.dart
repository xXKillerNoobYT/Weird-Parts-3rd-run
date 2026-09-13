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
    String? categoryId,
    String? styleId,
    String? typeId,
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
        categoryId: Value(categoryId),
        styleId: Value(styleId),
        typeId: Value(typeId),
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
    String varianceName = '',
    bool isMain = false,
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
        varianceName: Value(varianceName),
        isMain: Value(isMain),
      ),
    );
    if (isMain) {
      await _ensureSingleMain(
        partId: partId,
        brandId: brandId,
        keepId: id,
      );
    }
    return id;
  }

  Future<void> updateBrandVersion({
    required String id,
    required String mpn,
    required String varianceName,
    required bool isMain,
  }) async {
    final current = await (select(brandVersions)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .getSingleOrNull();
    if (current == null) return;
    final now = DateTime.now().toUtc();
    await (update(brandVersions)..where((t) => t.id.equals(id))).write(
      BrandVersionsCompanion.custom(
        mpn: Variable(mpn),
        varianceName: Variable(varianceName),
        isMain: Variable(isMain),
        modifiedAt: Variable(now),
        revision: brandVersions.revision + const Constant(1),
      ),
    );
    if (isMain) {
      await _ensureSingleMain(
        partId: current.partId,
        brandId: current.brandId,
        keepId: id,
      );
    }
  }

  Future<void> _ensureSingleMain({
    required String partId,
    required String brandId,
    required String keepId,
  }) async {
    final now = DateTime.now().toUtc();
    await (update(brandVersions)
          ..where(
            (t) =>
                t.partId.equals(partId) &
                t.brandId.equals(brandId) &
                t.id.equals(keepId).not() &
                t.deletedAt.isNull() &
                t.isMain.equals(true),
          ))
        .write(
      BrandVersionsCompanion.custom(
        isMain: const Constant(false),
        modifiedAt: Variable(now),
        revision: brandVersions.revision + const Constant(1),
      ),
    );
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

  Future<Part?> getPart(String partId, {bool includeDeleted = false}) {
    final q = select(parts)..where((t) => t.id.equals(partId));
    if (!includeDeleted) {
      q.where((t) => t.deletedAt.isNull());
    }
    return q.getSingleOrNull();
  }

  Future<void> updatePart({
    required String id,
    required String name,
    required String description,
    required String uom,
    String? defaultSupplierId,
    required bool active,
    String? categoryId,
    String? styleId,
    String? typeId,
  }) async {
    final now = DateTime.now().toUtc();
    await (update(parts)..where((t) => t.id.equals(id))).write(
      PartsCompanion.custom(
        name: Variable(name),
        description: Variable(description),
        uom: Variable(uom),
        defaultSupplierId: Variable(defaultSupplierId),
        active: Variable(active),
        categoryId: Variable(categoryId),
        styleId: Variable(styleId),
        typeId: Variable(typeId),
        modifiedAt: Variable(now),
        revision: parts.revision + const Constant(1),
      ),
    );
  }

  Future<void> setPhotoPath(String id, String? photoPath) async {
    final now = DateTime.now().toUtc();
    await (update(parts)..where((t) => t.id.equals(id))).write(
      PartsCompanion.custom(
        photoPath: Variable(photoPath),
        modifiedAt: Variable(now),
        revision: parts.revision + const Constant(1),
      ),
    );
  }

  Future<List<Part>> listParts({
    bool activeOnly = true,
    bool includeDeleted = false,
  }) {
    final q = select(parts);
    if (!includeDeleted) {
      q.where((t) => t.deletedAt.isNull());
    }
    if (activeOnly) {
      q.where((t) => t.active.equals(true));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.name)]);
    return q.get();
  }

  Future<List<BrandVersion>> listBrandVersionsForPart(
    String partId, {
    bool includeDeleted = false,
  }) {
    final q = select(brandVersions)..where((t) => t.partId.equals(partId));
    if (!includeDeleted) {
      q.where((t) => t.deletedAt.isNull());
    }
    q.orderBy([
      (t) => OrderingTerm.desc(t.isMain),
      (t) => OrderingTerm.asc(t.varianceName),
      (t) => OrderingTerm.asc(t.mpn),
    ]);
    return q.get();
  }

  Future<List<BrandVersion>> listAllBrandVersions() {
    return (select(brandVersions)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isMain),
            (t) => OrderingTerm.asc(t.varianceName),
            (t) => OrderingTerm.asc(t.mpn),
          ]))
        .get();
  }

  Future<List<SupplierListing>> listingsForBrandVersion(
    String bvId, {
    bool includeDeleted = false,
  }) {
    final q = select(supplierListings)
      ..where((t) => t.brandVersionId.equals(bvId));
    if (!includeDeleted) {
      q.where((t) => t.deletedAt.isNull());
    }
    return q.get();
  }

  Future<bool> hasLiveParts({
    String? categoryId,
    String? styleId,
    String? typeId,
  }) async {
    final q = select(parts)..where((t) => t.deletedAt.isNull());
    if (categoryId != null) {
      q.where((t) => t.categoryId.equals(categoryId));
    }
    if (styleId != null) {
      q.where((t) => t.styleId.equals(styleId));
    }
    if (typeId != null) {
      q.where((t) => t.typeId.equals(typeId));
    }
    q.limit(1);
    return (await q.get()).isNotEmpty;
  }

  /// Tombstones the part and its live brand versions, listings, and devices.
  ///
  /// Job lines keep `partId`, `brandVersionId`, and split `supplierId`s.
  /// Resolve those rows with `includeDeleted: true` so the editor still
  /// names the part and cannot wipe saved supplier splits.
  Future<void> softDeletePart(String id) async {
    await transaction(() async {
      final now = DateTime.now().toUtc();
      final versions = await (select(brandVersions)
            ..where((t) => t.partId.equals(id) & t.deletedAt.isNull()))
          .get();
      final versionIds = [for (final v in versions) v.id];
      if (versionIds.isNotEmpty) {
        await (update(supplierListings)
              ..where(
                (t) =>
                    t.brandVersionId.isIn(versionIds) & t.deletedAt.isNull(),
              ))
            .write(
          SupplierListingsCompanion.custom(
            deletedAt: Variable(now),
            modifiedAt: Variable(now),
            revision: supplierListings.revision + const Constant(1),
          ),
        );
        await (update(brandVersions)
              ..where((t) => t.partId.equals(id) & t.deletedAt.isNull()))
            .write(
          BrandVersionsCompanion.custom(
            deletedAt: Variable(now),
            modifiedAt: Variable(now),
            revision: brandVersions.revision + const Constant(1),
          ),
        );
      }
      await (update(partDevices)
            ..where((t) => t.partId.equals(id) & t.deletedAt.isNull()))
          .write(
        PartDevicesCompanion.custom(
          deletedAt: Variable(now),
          modifiedAt: Variable(now),
          revision: partDevices.revision + const Constant(1),
        ),
      );
      await (update(parts)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
          .write(
        PartsCompanion.custom(
          deletedAt: Variable(now),
          modifiedAt: Variable(now),
          revision: parts.revision + const Constant(1),
        ),
      );
    });
  }
}
