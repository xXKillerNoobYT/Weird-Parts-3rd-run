import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/new_id.dart';
import '../../data/app_database.dart';
import '../backup/backup_store.dart';
import '../company/company_store_markers.dart';
import '../pin/pin_service.dart';
import 'catalog_tree.dart';
import 'part_photo_store.dart';

class CatalogRepository {
  CatalogRepository(this._db, this._pin, this._deviceId);

  final AppDatabase _db;
  final PinService _pin;
  final String _deviceId;

  Future<List<Part>> listParts({
    bool activeOnly = true,
    bool includeDeleted = false,
  }) => _db.partsDao.listParts(
    activeOnly: activeOnly,
    includeDeleted: includeDeleted,
  );

  Future<Part?> getPart(String partId, {bool includeDeleted = false}) =>
      _db.partsDao.getPart(partId, includeDeleted: includeDeleted);

  Future<List<BrandVersion>> listBrandVersionsForPart(
    String partId, {
    bool includeDeleted = false,
  }) => _db.partsDao.listBrandVersionsForPart(
    partId,
    includeDeleted: includeDeleted,
  );

  Future<List<SupplierListing>> listingsForBrandVersion(
    String bvId, {
    bool includeDeleted = false,
  }) => _db.partsDao.listingsForBrandVersion(
    bvId,
    includeDeleted: includeDeleted,
  );

  Future<CatalogTreeSnapshot> loadTreeSnapshot({bool activeOnly = false}) =>
      loadCatalogTreeSnapshot(_db, activeOnly: activeOnly);

  Future<String> attachPhoto({
    required String partId,
    required Uint8List bytes,
    PartPhotoStore store = const PartPhotoStore(),
    Directory? root,
  }) async {
    if (_db.hasCallerTransaction) {
      throw StateError('Photo changes require their own transaction');
    }
    await _pin.requireUnlocked();
    return BackupIo.waitAndRun(() async {
      String? previous;
      String? staged;
      final String stored;
      try {
        stored = await legacyBusinessWrite(_db, () async {
          await _pin.requireUnlocked();
          final part = await _db.partsDao.getPart(partId);
          if (part == null) {
            throw StateError('Part is no longer in the catalog');
          }
          previous = part.photoPath;
          final path = await store.saveForPart(
            partId: partId,
            bytes: bytes,
            root: root,
          );
          staged = path;
          await _pin.requireUnlocked();
          await _db.partsDao.setPhotoPath(partId, path);
          await _pin.requireUnlocked();
          return path;
        });
      } catch (_) {
        final failed = staged;
        if (failed != null && failed != previous) {
          await _cleanupPhotoFile(
            failed,
            phase: 'attachment rollback',
            store: store,
            root: root,
          );
        }
        rethrow;
      }
      final oldPath = previous;
      if (oldPath != null && oldPath.isNotEmpty && oldPath != stored) {
        await _cleanupPhotoFile(
          oldPath,
          phase: 'attachment commit',
          store: store,
          root: root,
        );
      }
      return stored;
    });
  }

  Future<void> clearPhoto(
    String partId, {
    PartPhotoStore store = const PartPhotoStore(),
    Directory? root,
  }) async {
    if (_db.hasCallerTransaction) {
      throw StateError('Photo changes require their own transaction');
    }
    await _pin.requireUnlocked();
    await BackupIo.waitAndRun(() async {
      final existing = await legacyBusinessWrite(_db, () async {
        await _pin.requireUnlocked();
        final part = await _db.partsDao.getPart(partId);
        if (part == null) throw StateError('Part is no longer in the catalog');
        await _db.partsDao.setPhotoPath(partId, null);
        await _pin.requireUnlocked();
        return part.photoPath;
      });
      if (existing != null && existing.isNotEmpty) {
        await _cleanupPhotoFile(
          existing,
          phase: 'clear commit',
          store: store,
          root: root,
        );
      }
    });
  }

  Future<void> _cleanupPhotoFile(
    String path, {
    required String phase,
    required PartPhotoStore store,
    Directory? root,
  }) async {
    try {
      await store.deleteAt(path, root: root);
    } on FileSystemException catch (error) {
      debugPrint(
        'Part photo cleanup failed after $phase, OS code ${error.osError?.errorCode ?? 'unknown'}.',
      );
    }
  }

  Future<String> createGeneralPart({
    required String name,
    String? defaultSupplierId,
    String? categoryId,
    String? styleId,
    String? typeId,
  }) async {
    await _pin.requireUnlocked();
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) throw StateError('Part name is required');
    return legacyBusinessWrite(_db, () async {
      await _requireNestedTaxonomy(
        categoryId: categoryId,
        styleId: styleId,
        typeId: typeId,
      );
      await _pin.requireUnlocked();
      return _db.partsDao.insertGeneralPart(
        id: newId(),
        name: trimmedName,
        deviceId: _deviceId,
        defaultSupplierId: defaultSupplierId,
        categoryId: categoryId,
        styleId: styleId,
        typeId: typeId,
      );
    });
  }

  Future<void> _requireNestedTaxonomy({
    required String? categoryId,
    required String? styleId,
    required String? typeId,
  }) async {
    if (categoryId == null ||
        categoryId.isEmpty ||
        styleId == null ||
        styleId.isEmpty ||
        typeId == null ||
        typeId.isEmpty) {
      throw StateError('Category, Type, and Variant are required');
    }
    final categories = await _db.taxonomyDao.listCategories();
    if (!categories.any((c) => c.id == categoryId)) {
      throw StateError('Category must exist');
    }
    final styles = await _db.taxonomyDao.listStyles(categoryId: categoryId);
    if (!styles.any((s) => s.id == styleId)) {
      throw StateError('Type must belong to the selected Category');
    }
    final variants = await _db.taxonomyDao.listTypes(styleId: styleId);
    if (!variants.any((t) => t.id == typeId)) {
      throw StateError('Variant must belong to the selected Type');
    }
  }

  Future<void> updatePart({
    required String partId,
    required String name,
    required String description,
    required String uom,
    String? defaultSupplierId,
    required bool active,
    String? categoryId,
    String? styleId,
    String? typeId,
    String? specs,
  }) async {
    await _pin.requireUnlocked();
    await legacyBusinessWrite(_db, () async {
      await _requireNestedTaxonomy(
        categoryId: categoryId,
        styleId: styleId,
        typeId: typeId,
      );
      await _pin.requireUnlocked();
      await _db.partsDao.updatePart(
        id: partId,
        name: name,
        description: description,
        uom: uom,
        defaultSupplierId: defaultSupplierId,
        active: active,
        categoryId: categoryId,
        styleId: styleId,
        typeId: typeId,
        specs: specs,
      );
    });
  }

  Future<String> createBrandVersion({
    required String partId,
    required String brandId,
    required String mpn,
    String varianceName = '',
    bool isMain = false,
  }) async {
    await _pin.requireUnlocked();
    return _db.partsDao.insertBrandVersion(
      id: newId(),
      partId: partId,
      brandId: brandId,
      mpn: mpn,
      deviceId: _deviceId,
      varianceName: varianceName,
      isMain: isMain,
    );
  }

  Future<void> updateBrandVersion({
    required String id,
    required String mpn,
    required String varianceName,
    required bool isMain,
  }) async {
    await _pin.requireUnlocked();
    await _db.partsDao.updateBrandVersion(
      id: id,
      mpn: mpn,
      varianceName: varianceName,
      isMain: isMain,
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

  Future<int> countJobLinesForPart(String partId) =>
      _db.jobsDao.countLiveLinesForPart(partId);

  Future<void> deletePart(
    String partId, {
    PartPhotoStore store = const PartPhotoStore(),
    Directory? root,
  }) async {
    await _pin.requireUnlocked();
    await BackupIo.waitAndRun(() async {
      final part = await _db.partsDao.getPart(partId);
      await _db.partsDao.softDeletePart(partId);
      final photo = part?.photoPath;
      if (photo != null && photo.isNotEmpty) {
        await store.deleteAt(photo, root: root);
      }
      await store.deleteAllForPart(partId, root: root);
    });
  }

  /// Soft-deletes an empty category / type / variant folder.
  Future<void> deleteEmptyFolder({
    required CatalogTreeKind kind,
    required String id,
  }) async {
    await _pin.requireUnlocked();
    await legacyBusinessWrite(_db, () async {
      await _pin.requireUnlocked();
      switch (kind) {
        case CatalogTreeKind.category:
          if (!await _db.taxonomyDao.isCategoryEmpty(id)) {
            throw StateError('Folder is not empty');
          }
          await _db.taxonomyDao.softDeleteCategory(id);
        case CatalogTreeKind.type:
          if (!await _db.taxonomyDao.isStyleEmpty(id)) {
            throw StateError('Folder is not empty');
          }
          await _db.taxonomyDao.softDeleteStyle(id);
        case CatalogTreeKind.variant:
          if (!await _db.taxonomyDao.isTypeEmpty(id)) {
            throw StateError('Folder is not empty');
          }
          await _db.taxonomyDao.softDeleteType(id);
        default:
          throw StateError('Not an empty folder');
      }
    });
  }
}
