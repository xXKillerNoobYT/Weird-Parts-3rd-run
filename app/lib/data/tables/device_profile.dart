import 'package:drift/drift.dart';

class DeviceProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get displayName =>
      text().withDefault(const Constant('This device'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
