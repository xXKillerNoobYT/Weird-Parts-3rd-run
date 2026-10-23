import 'dart:io';

import 'package:drift/native.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/warehouse/warehouse_repository.dart';

class WarehouseFixture {
  WarehouseFixture._(
    this.db,
    this.pin,
    this.device,
    this.partId,
    this.locationId,
  );

  final AppDatabase db;
  final PinService pin;
  final String device;
  final String partId;
  final String locationId;
  WarehouseRepository get repo => WarehouseRepository(db, pin, device);
  CatalogRepository get catalog => CatalogRepository(db, pin, device);

  static Future<WarehouseFixture> create({
    File? file,
    NativeDatabase? executor,
  }) async {
    final db = AppDatabase.forTesting(
      executor ??
          (file == null ? NativeDatabase.memory() : NativeDatabase(file)),
    );
    final device = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);
    final maintenance = MaintenanceRepository(db, pin, device);
    final category = await maintenance.createCategory('Synthetic category');
    final style = await maintenance.createStyle(
      categoryId: category,
      name: 'Synthetic type',
    );
    final variant = await maintenance.createType(
      styleId: style,
      name: 'Synthetic variant',
    );
    final part = await CatalogRepository(db, pin, device).createGeneralPart(
      name: 'Counted part',
      categoryId: category,
      styleId: style,
      typeId: variant,
    );
    final location = newId();
    await WarehouseRepository(
      db,
      pin,
      device,
    ).createLocation(id: location, name: 'Shop shelf');
    return WarehouseFixture._(db, pin, device, part, location);
  }

  WarehouseCountDraft draft({
    String? id,
    String? locationId,
    String? partId,
    String? prior,
    double quantity = 12.5,
    String uom = 'ea',
    DateTime? observedAt,
    String note = '',
  }) => WarehouseCountDraft(
    id: id ?? newId(),
    locationId: locationId ?? this.locationId,
    partId: partId ?? this.partId,
    expectedPriorCountId: prior,
    quantity: quantity,
    uom: uom,
    observedAt: observedAt ?? DateTime.utc(2026, 10, 20, 9, 15, 13, 123, 456),
    note: note,
  );

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async => {
    for (final table in db.allTables)
      table.actualTableName:
          (await db
                  .customSelect(
                    'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
                  )
                  .get())
              .map((row) => row.data)
              .toList(),
  };
}
