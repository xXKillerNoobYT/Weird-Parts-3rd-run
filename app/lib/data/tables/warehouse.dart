import 'package:drift/drift.dart';

import 'parts.dart';
import 'taxonomy.dart';

class WarehouseLocations extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get nameKey => text().unique()();
}

class WarehouseCounts extends Table {
  TextColumn get id => text()();
  TextColumn get locationId => text().references(WarehouseLocations, #id)();
  TextColumn get partId => text().references(Parts, #id)();
  TextColumn get priorCountId =>
      text().nullable().references(WarehouseCounts, #id)();
  IntColumn get ordinal => integer()();
  RealColumn get quantity => real()();
  TextColumn get uom => text()();
  DateTimeColumn get observedAt => dateTime()();
  DateTimeColumn get recordedAt => dateTime()();
  TextColumn get originDeviceId => text()();
  TextColumn get note => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {locationId, partId, ordinal},
  ];

  @override
  List<String> get customConstraints => [
    'CHECK (ordinal > 0)',
    'CHECK (quantity >= 0)',
  ];
}
