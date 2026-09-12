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
  int get schemaVersion => 1;
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    // Prefer Application Support over Documents: OneDrive-backed Documents
    // on Windows can fail SQLite open (SQLITE_CANTOPEN / code 14).
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'wired_parts.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
