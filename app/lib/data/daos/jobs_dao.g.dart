// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'jobs_dao.dart';

// ignore_for_file: type=lint
mixin _$JobsDaoMixin on DatabaseAccessor<AppDatabase> {
  $JobsTable get jobs => attachedDatabase.jobs;
  $JobLinesTable get jobLines => attachedDatabase.jobLines;
  $OrderSplitsTable get orderSplits => attachedDatabase.orderSplits;
  JobsDaoManager get managers => JobsDaoManager(this);
}

class JobsDaoManager {
  final _$JobsDaoMixin _db;
  JobsDaoManager(this._db);
  $$JobsTableTableManager get jobs =>
      $$JobsTableTableManager(_db.attachedDatabase, _db.jobs);
  $$JobLinesTableTableManager get jobLines =>
      $$JobLinesTableTableManager(_db.attachedDatabase, _db.jobLines);
  $$OrderSplitsTableTableManager get orderSplits =>
      $$OrderSplitsTableTableManager(_db.attachedDatabase, _db.orderSplits);
}
