import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'daos/jobs_dao.dart';
import 'daos/parts_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/taxonomy_dao.dart';
import 'tables/app_settings.dart';
import 'tables/device_profile.dart';
import 'tables/jobs.dart';
import 'tables/parts.dart';
import 'tables/taxonomy.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    DeviceProfiles,
    AppSettings,
    Categories,
    Styles,
    Types,
    Devices,
    Brands,
    Suppliers,
    Parts,
    PartDevices,
    BrandVersions,
    SupplierListings,
    Jobs,
    JobLines,
    OrderSplits,
  ],
  daos: [SettingsDao, TaxonomyDao, PartsDao, JobsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(brandVersions, brandVersions.varianceName);
            await m.addColumn(brandVersions, brandVersions.isMain);
          }
        },
      );
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'wired_parts.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
