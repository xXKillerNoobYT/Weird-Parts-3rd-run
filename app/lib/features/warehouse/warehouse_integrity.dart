import 'package:drift/drift.dart';

import '../../data/app_database.dart';

String warehouseNameKey(String name) => name.trim().toLowerCase();

void requireWarehouseQuantity(double quantity) {
  if (!quantity.isFinite || quantity < 0) {
    throw StateError('Count must be a finite, nonnegative quantity');
  }
}

DateTime warehouseTimestamp(DateTime value) =>
    DateTime.fromMillisecondsSinceEpoch(
      (value.millisecondsSinceEpoch ~/ 1000) * 1000,
      isUtc: true,
    );

/// Validates stored observations without treating catalog tombstones as loss.
Future<void> validateWarehouseStore(AppDatabase db) async {
  final locations = await db.select(db.warehouseLocations).get();
  final parts = await db.select(db.parts).get();
  final counts = await (db.select(
    db.warehouseCounts,
  )..orderBy([(t) => OrderingTerm.asc(t.ordinal)])).get();
  final locationIds = <String>{};
  final countIds = <String>{};
  final partIds = parts.map((row) => row.id).toSet();
  final names = <String>{};
  for (final row in locations) {
    if (row.id.isEmpty ||
        !locationIds.add(row.id) ||
        row.originDeviceId.isEmpty ||
        row.revision < 1 ||
        row.name.isEmpty ||
        row.name != row.name.trim() ||
        row.nameKey != warehouseNameKey(row.name) ||
        !names.add(row.nameKey)) {
      throw StateError('Invalid warehouse location');
    }
  }
  final heads = <(String, String), WarehouseCount>{};
  for (final row in counts) {
    requireWarehouseQuantity(row.quantity);
    final head = heads[(row.locationId, row.partId)];
    if (row.id.isEmpty ||
        !countIds.add(row.id) ||
        row.originDeviceId.isEmpty ||
        row.uom.isEmpty ||
        row.uom != row.uom.trim() ||
        row.note != row.note.trim() ||
        !locationIds.contains(row.locationId) ||
        !partIds.contains(row.partId) ||
        row.ordinal != (head?.ordinal ?? 0) + 1 ||
        row.priorCountId != head?.id) {
      throw StateError('Invalid warehouse count reference or causal chain');
    }
    heads[(row.locationId, row.partId)] = row;
  }
}
