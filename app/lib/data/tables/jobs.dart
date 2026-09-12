import 'package:drift/drift.dart';

import 'taxonomy.dart';

class Jobs extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get customer => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get jobNumber => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get notes => text().nullable()();
}

class JobLines extends Table with SyncColumns {
  TextColumn get jobId => text()();
  TextColumn get partId => text().nullable()();
  TextColumn get customName => text().nullable()();
  TextColumn get customNotes => text().nullable()();
  TextColumn get brandVersionId => text().nullable()();
  RealColumn get neededQty => real()();
  RealColumn get shopPullQty => real().withDefault(const Constant(0.0))();
  TextColumn get uom => text().nullable()();
  TextColumn get notes => text().nullable()();
}

class OrderSplits extends Table with SyncColumns {
  TextColumn get jobLineId => text()();
  TextColumn get supplierId => text()();
  RealColumn get quantity => real()();
}
