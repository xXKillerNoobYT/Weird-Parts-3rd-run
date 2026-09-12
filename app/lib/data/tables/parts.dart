import 'package:drift/drift.dart';

import 'taxonomy.dart';

class Parts extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get categoryId => text().nullable()();
  TextColumn get styleId => text().nullable()();
  TextColumn get typeId => text().nullable()();
  TextColumn get uom => text().withDefault(const Constant('ea'))();
  TextColumn get specs => text().withDefault(const Constant(''))();
  TextColumn get keywords => text().withDefault(const Constant(''))();
  TextColumn get photoPath => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  TextColumn get defaultSupplierId => text().nullable()();
}

class PartDevices extends Table with SyncColumns {
  TextColumn get partId => text()();
  TextColumn get deviceId => text()();
}

class BrandVersions extends Table with SyncColumns {
  TextColumn get partId => text()();
  TextColumn get brandId => text()();
  TextColumn get mpn => text()();
  TextColumn get model => text().withDefault(const Constant(''))();
  TextColumn get description => text().withDefault(const Constant(''))();
}

class SupplierListings extends Table with SyncColumns {
  TextColumn get brandVersionId => text()();
  TextColumn get supplierId => text()();
  TextColumn get sku => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  RealColumn get packageQty => real().withDefault(const Constant(1.0))();
  RealColumn get lastPrice => real().nullable()();
  TextColumn get notes => text().nullable()();
}
