// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'parts_dao.dart';

// ignore_for_file: type=lint
mixin _$PartsDaoMixin on DatabaseAccessor<AppDatabase> {
  $PartsTable get parts => attachedDatabase.parts;
  $PartDevicesTable get partDevices => attachedDatabase.partDevices;
  $BrandVersionsTable get brandVersions => attachedDatabase.brandVersions;
  $SupplierListingsTable get supplierListings =>
      attachedDatabase.supplierListings;
  PartsDaoManager get managers => PartsDaoManager(this);
}

class PartsDaoManager {
  final _$PartsDaoMixin _db;
  PartsDaoManager(this._db);
  $$PartsTableTableManager get parts =>
      $$PartsTableTableManager(_db.attachedDatabase, _db.parts);
  $$PartDevicesTableTableManager get partDevices =>
      $$PartDevicesTableTableManager(_db.attachedDatabase, _db.partDevices);
  $$BrandVersionsTableTableManager get brandVersions =>
      $$BrandVersionsTableTableManager(_db.attachedDatabase, _db.brandVersions);
  $$SupplierListingsTableTableManager get supplierListings =>
      $$SupplierListingsTableTableManager(
        _db.attachedDatabase,
        _db.supplierListings,
      );
}
