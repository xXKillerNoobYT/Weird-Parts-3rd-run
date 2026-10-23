import 'package:drift/drift.dart';

import '../../data/app_database.dart';
import '../catalog/catalog_tree.dart';
import '../company/company_store_markers.dart';
import '../pin/pin_service.dart';
import 'warehouse_integrity.dart';

class WarehouseCountDraft {
  const WarehouseCountDraft({
    required this.id,
    required this.locationId,
    required this.partId,
    required this.expectedPriorCountId,
    required this.quantity,
    required this.uom,
    required this.observedAt,
    this.note = '',
  });

  final String id;
  final String locationId;
  final String partId;
  final String? expectedPriorCountId;
  final double quantity;
  final String uom;
  final DateTime observedAt;
  final String note;
}

class WarehouseStock {
  const WarehouseStock({required this.count, required this.part});
  final WarehouseCount count;
  final Part part;
  bool get needsRecount => count.uom != part.uom.trim();
}

class WarehouseRepository {
  WarehouseRepository(this._db, this._pin, this._deviceId);
  final AppDatabase _db;
  final PinService _pin;
  final String _deviceId;

  Future<List<WarehouseLocation>> loadLocations() => _read(
    () =>
        (_db.select(_db.warehouseLocations)
              ..where((t) => t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.asc(t.nameKey)]))
            .get(),
  );

  Future<CatalogTreeSnapshot> loadPartChoices() =>
      _read(() => loadCatalogTreeSnapshot(_db, activeOnly: false));

  Future<Part?> loadPart(String id) => _read(() => _db.partsDao.getPart(id));

  Future<WarehouseLocation> createLocation({
    required String id,
    required String name,
  }) => legacyBusinessWrite(_db, () async {
    await _pin.requireUnlocked();
    final trimmed = name.trim();
    if (id.isEmpty || trimmed.isEmpty || _deviceId.isEmpty) {
      throw StateError('Location name and identity are required');
    }
    final existing = await (_db.select(
      _db.warehouseLocations,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing != null) {
      if (existing.name == trimmed &&
          existing.originDeviceId == _deviceId &&
          existing.deletedAt == null) {
        return existing;
      }
      throw StateError('Location ID already has different data');
    }
    await _requireUniqueName(trimmed);
    final now = warehouseTimestamp(DateTime.now());
    await _pin.requireUnlocked();
    final saved = await _db
        .into(_db.warehouseLocations)
        .insertReturning(
          WarehouseLocationsCompanion.insert(
            id: id,
            originDeviceId: _deviceId,
            createdAt: now,
            modifiedAt: now,
            name: trimmed,
            nameKey: warehouseNameKey(trimmed),
          ),
        );
    await _pin.requireUnlocked();
    return saved;
  });

  Future<void> renameLocation({
    required String id,
    required int expectedRevision,
    required String name,
  }) => legacyBusinessWrite(_db, () async {
    await _pin.requireUnlocked();
    final location = await _liveLocation(id);
    if (location.revision != expectedRevision) {
      throw StateError('Location changed. Reload before renaming.');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw StateError('Location name is required');
    if (location.name == trimmed) return;
    await _requireUniqueName(trimmed, except: id);
    await _pin.requireUnlocked();
    await (_db.update(
      _db.warehouseLocations,
    )..where((t) => t.id.equals(id))).write(
      WarehouseLocationsCompanion(
        name: Value(trimmed),
        nameKey: Value(warehouseNameKey(trimmed)),
        modifiedAt: Value(warehouseTimestamp(DateTime.now())),
        revision: Value(location.revision + 1),
      ),
    );
    await _pin.requireUnlocked();
  });

  Future<WarehouseCount?> latestCount(String locationId, String partId) =>
      _read(
        () =>
            (_db.select(_db.warehouseCounts)
                  ..where(
                    (t) =>
                        t.locationId.equals(locationId) &
                        t.partId.equals(partId),
                  )
                  ..orderBy([(t) => OrderingTerm.desc(t.ordinal)])
                  ..limit(1))
                .getSingleOrNull(),
      );

  Future<List<WarehouseCount>> loadCountHistory(
    String locationId,
    String partId,
  ) => _read(
    () =>
        (_db.select(_db.warehouseCounts)
              ..where(
                (t) =>
                    t.locationId.equals(locationId) & t.partId.equals(partId),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.ordinal)]))
            .get(),
  );

  Future<List<WarehouseStock>> loadLatestCounts(
    String locationId,
  ) => _read(() async {
    final counts =
        await (_db.select(_db.warehouseCounts)
              ..where((t) => t.locationId.equals(locationId))
              ..orderBy([(t) => OrderingTerm.desc(t.ordinal)]))
            .get();
    final latest = <String, WarehouseStock>{};
    final parts = {for (final p in await _db.select(_db.parts).get()) p.id: p};
    for (final row in counts) {
      final part = parts[row.partId];
      if (part == null) throw StateError('Inventory references a missing Part');
      latest.putIfAbsent(
        row.partId,
        () => WarehouseStock(count: row, part: part),
      );
    }
    return latest.values.toList()
      ..sort((a, b) => a.part.name.compareTo(b.part.name));
  });

  Future<WarehouseCount> recordCount(WarehouseCountDraft draft) =>
      legacyBusinessWrite(_db, () async {
        await _pin.requireUnlocked();
        final uom = draft.uom.trim();
        final note = draft.note.trim();
        final observedAt = warehouseTimestamp(draft.observedAt);
        final existing = await (_db.select(
          _db.warehouseCounts,
        )..where((t) => t.id.equals(draft.id))).getSingleOrNull();
        if (existing != null) {
          if (existing.originDeviceId == _deviceId &&
              existing.locationId == draft.locationId &&
              existing.partId == draft.partId &&
              existing.priorCountId == draft.expectedPriorCountId &&
              existing.quantity == draft.quantity &&
              existing.uom == uom &&
              existing.observedAt.isAtSameMomentAs(observedAt) &&
              existing.note == note) {
            await _pin.requireUnlocked();
            return existing;
          }
          throw StateError('Count ID already has different data');
        }
        requireWarehouseQuantity(draft.quantity);
        if (draft.id.isEmpty || _deviceId.isEmpty || uom.isEmpty) {
          throw StateError('Count identity and unit are required');
        }
        await _liveLocation(draft.locationId);
        final part = await _db.partsDao.getPart(draft.partId);
        if (part == null) throw StateError('Part is no longer in the catalog');
        if (part.uom.trim() != uom) {
          throw StateError(
            'Part unit changed. Reload and recount without conversion.',
          );
        }
        final head = await latestCount(draft.locationId, draft.partId);
        if (head?.id != draft.expectedPriorCountId) {
          throw StateError(
            'Count changed. Cancel and reload before recounting.',
          );
        }
        await _pin.requireUnlocked();
        final saved = await _db
            .into(_db.warehouseCounts)
            .insertReturning(
              WarehouseCountsCompanion.insert(
                id: draft.id,
                locationId: draft.locationId,
                partId: draft.partId,
                priorCountId: Value(draft.expectedPriorCountId),
                ordinal: (head?.ordinal ?? 0) + 1,
                quantity: draft.quantity,
                uom: uom,
                observedAt: observedAt,
                recordedAt: warehouseTimestamp(DateTime.now()),
                originDeviceId: _deviceId,
                note: Value(note),
              ),
            );
        await _pin.requireUnlocked();
        return saved;
      });

  Future<WarehouseLocation> _liveLocation(String id) async {
    final row = await (_db.select(
      _db.warehouseLocations,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    if (row == null) throw StateError('Warehouse location is unavailable');
    return row;
  }

  Future<void> _requireUniqueName(String name, {String? except}) async {
    final row =
        await (_db.select(_db.warehouseLocations)
              ..where((t) => t.nameKey.equals(warehouseNameKey(name))))
            .getSingleOrNull();
    if (row != null && row.id != except) {
      throw StateError('A warehouse with that name already exists');
    }
  }

  Future<T> _read<T>(Future<T> Function() read) => _db.transaction(() async {
    if (await hasCompanyStoreMarkers(_db)) {
      throw StateError(
        'This shop belongs to a company. Legacy inventory is unavailable.',
      );
    }
    return read();
  });
}
