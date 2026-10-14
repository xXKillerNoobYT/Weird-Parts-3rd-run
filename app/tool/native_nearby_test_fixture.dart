import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

import 'nearby_lan_workspace.dart';
import 'native_nearby_test_crypto.dart';

/// Test entrypoints may reopen an owned fixture, but may never initialize one.
ValidationWorkspace openExistingNativeFixture({
  required String run,
  required ValidationRole role,
  Directory? temporaryDirectory,
}) {
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$').hasMatch(run)) {
    rejectNativeTest('fixture-rejected');
  }
  final temp = (temporaryDirectory ?? Directory.systemTemp)
      .resolveSymbolicLinksSync();
  final root = Directory(p.join(temp, 'wired-parts-lan-$run-${role.name}'));
  final owner = File(p.join(root.path, 'validation-owner.json'));
  final sqlite = File(p.join(root.path, 'support', kSqliteFileName));
  if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      FileSystemEntity.typeSync(owner.path, followLinks: false) !=
          FileSystemEntityType.file ||
      FileSystemEntity.typeSync(sqlite.path, followLinks: false) !=
          FileSystemEntityType.file) {
    rejectNativeTest('fixture-rejected');
  }
  final Object? contents;
  try {
    contents = jsonDecode(owner.readAsStringSync());
  } catch (_) {
    rejectNativeTest('fixture-rejected');
  }
  if (contents is! Map ||
      contents.length != 5 ||
      contents['format'] != 1 ||
      contents['run'] != run ||
      contents['role'] != role.name ||
      contents['root'] != root.path ||
      contents['initialized'] != true) {
    rejectNativeTest('fixture-rejected');
  }
  // Workspace owns locking and recursive link rejection. All required state
  // exists before this call; this path never calls seed or markInitialized.
  final workspace = ValidationWorkspace.open(
    run: run,
    role: role,
    temporaryDirectory: temporaryDirectory,
    requireExisting: true,
  );
  try {
    _validateExistingDatabase(sqlite, workspace.deviceId);
    return workspace;
  } catch (_) {
    workspace.close();
    rejectNativeTest('fixture-rejected');
  }
}

void _validateExistingDatabase(File file, String deviceId) {
  if (file.lengthSync() < 100 || file.lengthSync() > 512 * 1024 * 1024) {
    rejectNativeTest('fixture-rejected');
  }
  final db = raw.sqlite3.open(file.path, mode: raw.OpenMode.readOnly);
  try {
    db.execute('BEGIN');
    if (db.select('PRAGMA user_version').single.values.single != 2) {
      rejectNativeTest('fixture-rejected');
    }
    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'])
        .toSet();
    if (!tables.containsAll(_schema2Columns.keys)) {
      rejectNativeTest('fixture-rejected');
    }
    for (final entry in _schema2Columns.entries) {
      final columns = db
          .select('PRAGMA table_info("${entry.key}")')
          .map((row) => row['name'])
          .toSet();
      final expected = {
        ...entry.value,
        if (entry.key != 'device_profiles' && entry.key != 'app_settings')
          ..._syncColumns,
      };
      if (!columns.containsAll(expected)) rejectNativeTest('fixture-rejected');
    }
    final profiles = db.select(
      'SELECT id, display_name, created_at FROM device_profiles LIMIT 2',
    );
    if (profiles.length != 1 ||
        profiles.single['id'] != deviceId ||
        profiles.single['display_name'] is! String ||
        (profiles.single['display_name'] as String).trim().isEmpty ||
        profiles.single['created_at'] is! int ||
        (profiles.single['created_at'] as int) < 0) {
      rejectNativeTest('fixture-rejected');
    }
    final check = db.select('PRAGMA quick_check');
    if (check.length != 1 || check.single.values.single != 'ok') {
      rejectNativeTest('fixture-rejected');
    }
  } finally {
    db.dispose();
  }
}

// This entrypoint deliberately admits only the frozen schema-2 test fixture.
// A future migration must update its admission tests before a native rerun.
const _syncColumns = {
  'id',
  'origin_device_id',
  'created_at',
  'modified_at',
  'revision',
  'deleted_at',
};
const _schema2Columns = {
  'device_profiles': {'id', 'display_name', 'created_at'},
  'app_settings': {'key', 'value'},
  'categories': {'name'},
  'styles': {'category_id', 'name'},
  'types': {'style_id', 'name'},
  'devices': {'name'},
  'brands': {'name'},
  'suppliers': {'name'},
  'parts': {
    'name',
    'description',
    'category_id',
    'style_id',
    'type_id',
    'uom',
    'specs',
    'keywords',
    'photo_path',
    'active',
    'default_supplier_id',
  },
  'part_devices': {'part_id', 'device_id'},
  'brand_versions': {
    'part_id',
    'brand_id',
    'mpn',
    'model',
    'description',
    'variance_name',
    'is_main',
  },
  'supplier_listings': {
    'brand_version_id',
    'supplier_id',
    'sku',
    'description',
    'package_qty',
    'last_price',
    'notes',
  },
  'jobs': {'name', 'customer', 'location', 'job_number', 'status', 'notes'},
  'job_lines': {
    'job_id',
    'part_id',
    'custom_name',
    'custom_notes',
    'brand_version_id',
    'needed_qty',
    'shop_pull_qty',
    'uom',
    'notes',
  },
  'order_splits': {'job_line_id', 'supplier_id', 'quantity'},
};

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();

/// Full rows remain private in app memory. Only aggregate digests and typed
/// checks may leave the resident test; raw settings include a PIN verifier.
final class NativeFixtureSnapshot {
  NativeFixtureSnapshot._({
    required this.domain,
    required this.settings,
    required this.profiles,
    required this.assets,
    required this.ownerDigest,
    required this.schemaVersion,
    required this.integrityValid,
    required this.referencesValid,
    required this.referenceCount,
  });

  final Map<String, List<Map<String, Object?>>> domain;
  final List<Map<String, Object?>> settings, profiles;
  final List<Map<String, Object?>> assets;
  final String ownerDigest;
  final int schemaVersion;
  final bool integrityValid, referencesValid;
  final int referenceCount;
  int get rowCount => domain.values.fold(0, (sum, rows) => sum + rows.length);
  String get digest => _digest([schemaVersion, domain, assets]);
  String get assetsDigest => _digest(assets);
  String get profileDigest => _digest(profiles);
  String get sharedSettingsDigest => _digest(
    settings
        .where(
          (row) =>
              row['key'] != kLastNearbyAtKey &&
              row['key'] != kLastNearbyPeerKey &&
              row['key'] != 'editor_pin_hash',
        )
        .toList(),
  );
  // These digests are sealed to the root coordinator; never public outputs.
  String get privateSharedSettingsDigest => _digest(
    settings
        .where(
          (row) =>
              row['key'] != kLastNearbyAtKey &&
              row['key'] != kLastNearbyPeerKey,
        )
        .toList(),
  );
  String get privatePinDigest => _digest(setting('editor_pin_hash'));
  String get completeSettingsDigest => _digest(settings);
  Object? setting(String key) => settings
      .where((row) => row['key'] == key)
      .map((row) => row['value'])
      .singleOrNull;

  static Future<NativeFixtureSnapshot> capture(
    AppDatabase db,
    ValidationWorkspace workspace,
  ) async {
    final domain = <String, List<Map<String, Object?>>>{};
    late List<Map<String, Object?>> settings, profiles;
    late int version;
    late bool integrity, validReferences;
    var referenceCount = 0;
    await db.transaction(() async {
      final tables = db.allTables.toList()
        ..sort((a, b) => a.actualTableName.compareTo(b.actualTableName));
      for (final table in tables) {
        final name = table.actualTableName;
        final order = name == 'app_settings' ? 'key' : 'id';
        final rows =
            (await db
                    .customSelect('SELECT * FROM "$name" ORDER BY "$order"')
                    .get())
                .map((row) => Map<String, Object?>.from(row.data))
                .toList();
        if (name == 'app_settings') {
          settings = rows;
        } else if (name == 'device_profiles') {
          profiles = rows;
        } else {
          domain[name] = rows;
        }
      }
      version = (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');
      final check = await db.customSelect('PRAGMA integrity_check').get();
      integrity = check.length == 1 && check.single.data.values.single == 'ok';
      validReferences =
          (await db.customSelect('PRAGMA foreign_key_check').get()).isEmpty;
      for (final (table, column, target) in _references) {
        final ids = domain[target]!.map((row) => row['id']).toSet();
        for (final row in domain[table]!) {
          if (row[column] != null) referenceCount++;
          if (row[column] != null && !ids.contains(row[column])) {
            validReferences = false;
          }
        }
      }
    });
    if (profiles.length != 1 || profiles.single['id'] != workspace.deviceId) {
      rejectNativeTest('fixture-rejected');
    }
    final assets = <Map<String, Object?>>[];
    if (workspace.photos.existsSync()) {
      for (final entity in workspace.photos.listSync(followLinks: false)) {
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
            FileSystemEntityType.file) {
          rejectNativeTest('fixture-rejected');
        }
        final file = File(entity.path);
        assets.add({
          'name': p.basename(file.path),
          'length': file.lengthSync(),
          'sha256': sha256.convert(file.readAsBytesSync()).toString(),
        });
      }
    }
    assets.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    for (final row in domain['parts']!) {
      final photo = row['photo_path'];
      if (photo != null &&
          (photo is! String ||
              p.isAbsolute(photo) ||
              p.basename(photo) != photo ||
              !assets.any((asset) => asset['name'] == photo))) {
        validReferences = false;
      }
    }
    return NativeFixtureSnapshot._(
      domain: domain,
      settings: settings,
      profiles: profiles,
      assets: assets,
      ownerDigest: sha256
          .convert(
            File(p.join(workspace.root.path, 'validation-owner.json'))
                .readAsBytesSync(),
          )
          .toString(),
      schemaVersion: version,
      integrityValid: integrity,
      referencesValid: validReferences,
      referenceCount: referenceCount,
    );
  }
}

const _references = [
  ('styles', 'category_id', 'categories'),
  ('types', 'style_id', 'styles'),
  ('parts', 'category_id', 'categories'),
  ('parts', 'style_id', 'styles'),
  ('parts', 'type_id', 'types'),
  ('parts', 'default_supplier_id', 'suppliers'),
  ('part_devices', 'part_id', 'parts'),
  ('part_devices', 'device_id', 'devices'),
  ('brand_versions', 'part_id', 'parts'),
  ('brand_versions', 'brand_id', 'brands'),
  ('supplier_listings', 'brand_version_id', 'brand_versions'),
  ('supplier_listings', 'supplier_id', 'suppliers'),
  ('job_lines', 'job_id', 'jobs'),
  ('job_lines', 'part_id', 'parts'),
  ('job_lines', 'brand_version_id', 'brand_versions'),
  ('order_splits', 'job_line_id', 'job_lines'),
  ('order_splits', 'supplier_id', 'suppliers'),
];
