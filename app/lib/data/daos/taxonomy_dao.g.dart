// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'taxonomy_dao.dart';

// ignore_for_file: type=lint
mixin _$TaxonomyDaoMixin on DatabaseAccessor<AppDatabase> {
  $CategoriesTable get categories => attachedDatabase.categories;
  $StylesTable get styles => attachedDatabase.styles;
  $TypesTable get types => attachedDatabase.types;
  $DevicesTable get devices => attachedDatabase.devices;
  $BrandsTable get brands => attachedDatabase.brands;
  $SuppliersTable get suppliers => attachedDatabase.suppliers;
  TaxonomyDaoManager get managers => TaxonomyDaoManager(this);
}

class TaxonomyDaoManager {
  final _$TaxonomyDaoMixin _db;
  TaxonomyDaoManager(this._db);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$StylesTableTableManager get styles =>
      $$StylesTableTableManager(_db.attachedDatabase, _db.styles);
  $$TypesTableTableManager get types =>
      $$TypesTableTableManager(_db.attachedDatabase, _db.types);
  $$DevicesTableTableManager get devices =>
      $$DevicesTableTableManager(_db.attachedDatabase, _db.devices);
  $$BrandsTableTableManager get brands =>
      $$BrandsTableTableManager(_db.attachedDatabase, _db.brands);
  $$SuppliersTableTableManager get suppliers =>
      $$SuppliersTableTableManager(_db.attachedDatabase, _db.suppliers);
}
