import 'package:drift/drift.dart';

/// Shared sync metadata columns for taxonomy and parts tables.
mixin SyncColumns on Table {
  TextColumn get id => text()();
  TextColumn get originDeviceId => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get modifiedAt => dateTime()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Categories extends Table with SyncColumns {
  TextColumn get name => text()();
}

class Styles extends Table with SyncColumns {
  TextColumn get categoryId => text()();
  TextColumn get name => text()();
}

class Types extends Table with SyncColumns {
  TextColumn get styleId => text()();
  TextColumn get name => text()();
}

class Devices extends Table with SyncColumns {
  TextColumn get name => text()();
}

class Brands extends Table with SyncColumns {
  TextColumn get name => text()();
}

class Suppliers extends Table with SyncColumns {
  TextColumn get name => text()();
}
