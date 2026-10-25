import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/company/company_store_markers.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/warehouse/warehouse_integrity.dart';

import 'fixture.dart';

enum MockShopProfile { localShop, companyJobs }

enum _Table {
  categories('categories'),
  styles('styles'),
  types('types'),
  brands('brands'),
  suppliers('suppliers'),
  parts('parts'),
  versions('brand_versions'),
  listings('supplier_listings'),
  jobs('jobs'),
  lines('job_lines'),
  locations('warehouse_locations'),
  counts('warehouse_counts');

  const _Table(this.sqlName);
  final String sqlName;
}

final class MockImportReceipt {
  const MockImportReceipt({
    required this.fixtureHash,
    required this.counts,
    required this.unchanged,
  });
  final String fixtureHash;
  final Map<String, int> counts;
  final bool unchanged;
  Map<String, Object?> toJson() => {
    'profile': MockShopProfile.localShop.name,
    'fixture_sha256': fixtureHash,
    'schema_version': kAppSchemaVersion,
    'counts': counts,
    'unchanged': unchanged,
    'setup_evidence_only': true,
    'unsupported_native_entities': const [
      'stock_movements',
      'reservations',
      'purchase_orders',
      'staff_roles',
      'automations',
      'seven_state_job_workflow',
    ],
    'projection': const {
      'job_status':
          'completed/cancelled archived; original stage retained in notes',
      'shop_pull': 'issued_qty - returned_qty + reserved_qty',
      'warehouse': 'on_hand_qty absolute observation, not movement replay',
    },
  };
}

String ephemeralMockPin() {
  final random = Random.secure();
  return List.generate(8, (_) => random.nextInt(10)).join();
}

final class _ProfileClaim {
  _ProfileClaim(this.root, this.file);
  final String root;
  final RandomAccessFile file;
  static final _held = <String>{};

  static _ProfileClaim acquire(Directory root) {
    if (!_held.add(root.path)) {
      throw StateError('Mock profile is already open');
    }
    RandomAccessFile? file;
    try {
      final path = '${root.path}.lock';
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw StateError('Refusing a redirected mock profile claim');
      }
      file = File(path).openSync(mode: FileMode.append);
      file.lockSync(FileLock.exclusive);
      return _ProfileClaim(root.path, file);
    } catch (_) {
      file?.closeSync();
      _held.remove(root.path);
      throw StateError('Mock profile claim is unavailable');
    }
  }

  void close() {
    try {
      file.closeSync();
    } finally {
      _held.remove(root);
    }
  }
}

final class MockLocalWorkspace {
  MockLocalWorkspace._(
    this.root,
    this._db,
    this._pin,
    this._secret,
    this._deviceId,
    this._claim, {
    this.profileId,
  });

  static const _owner = 'wired-parts-mock-shop-v1';
  static const _marker = 'mock_shop_import_v1';
  final Directory root;
  AppDatabase _db;
  PinService _pin;
  AppDatabase get db => _db;
  PinService get pin => _pin;
  final String? _secret;
  final String _deviceId;
  final String? profileId;
  final _ProfileClaim? _claim;
  bool _closed = false;
  String get deviceId => _deviceId;
  File get databaseFile => File('${root.path}/wired_parts.sqlite');

  static Future<MockLocalWorkspace> create() async {
    final root = await Directory.systemTemp.createTemp(
      'wired-parts-mock-shop-',
    );
    return _createAt(root);
  }

  static Directory profileRoot(String profileId) {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$').hasMatch(profileId)) {
      throw ArgumentError('Invalid mock profile identifier');
    }
    return Directory(
      p.join(
        Directory.systemTemp.resolveSymbolicLinksSync(),
        'wired-parts-mock-shop-profile-$profileId',
      ),
    );
  }

  static Future<MockLocalWorkspace> createProfile({
    required String profileId,
  }) async {
    final root = profileRoot(profileId);
    final claim = _ProfileClaim.acquire(root);
    try {
      if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Mock profile creation requires an absent target');
      }
      await root.create();
      return await _createAt(root, profileId: profileId, claim: claim);
    } catch (_) {
      claim.close();
      rethrow;
    }
  }

  static Future<MockLocalWorkspace> _createAt(
    Directory root, {
    String? profileId,
    _ProfileClaim? claim,
  }) async {
    await File('${root.path}/owner').writeAsString(_owner, flush: true);
    final db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/wired_parts.sqlite')),
    );
    try {
      final deviceId = await db.settingsDao.ensureDeviceId();
      final pin = PinService(db.settingsDao);
      final secret = ephemeralMockPin();
      await pin.setPin(secret);
      await pin.unlock(secret);
      return MockLocalWorkspace._(
        root,
        db,
        pin,
        secret,
        deviceId,
        claim,
        profileId: profileId,
      );
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  static Future<MockLocalWorkspace> resumeProfile({
    required String profileId,
    required MockShopFixture fixture,
  }) async {
    if (fixture.sha256Value != mockShopFixtureSha256) {
      throw StateError('Mock profile requires the frozen fixture');
    }
    final root = profileRoot(profileId);
    final claim = _ProfileClaim.acquire(root);
    try {
      _requireProfileFiles(root);
      final binding = jsonDecode(
        File('${root.path}/profile.json').readAsStringSync(),
      );
      const keys = {
        'format',
        'profile_id',
        'root',
        'fixture_sha256',
        'schema_version',
        'device_id',
      };
      if (binding is! Map<String, dynamic> ||
          binding.length != keys.length ||
          !binding.keys.toSet().containsAll(keys) ||
          binding['format'] != 1 ||
          binding['profile_id'] != profileId ||
          binding['root'] != root.path ||
          binding['fixture_sha256'] != fixture.sha256Value ||
          binding['schema_version'] != kAppSchemaVersion ||
          binding['device_id'] is! String ||
          (binding['device_id'] as String).isEmpty) {
        throw StateError('Mock profile identity does not match');
      }
      final deviceId = binding['device_id'] as String;
      await _preflightProfile(root, fixture, deviceId);
      final db = AppDatabase.forTesting(
        NativeDatabase(File('${root.path}/wired_parts.sqlite')),
      );
      return MockLocalWorkspace._(
        root,
        db,
        PinService(db.settingsDao),
        null,
        deviceId,
        claim,
        profileId: profileId,
      );
    } catch (_) {
      claim.close();
      throw StateError('Mock profile resume refused');
    }
  }

  static void _requireProfileFiles(Directory root) {
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        root.resolveSymbolicLinksSync() != root.path) {
      throw StateError('Refusing an unowned mock profile');
    }
    for (final name in ['owner', 'profile.json', 'wired_parts.sqlite']) {
      if (FileSystemEntity.typeSync('${root.path}/$name', followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('Mock profile initialization is incomplete');
      }
    }
    for (final entry in root.listSync(recursive: true, followLinks: false)) {
      if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
              FileSystemEntityType.link ||
          !p.isWithin(root.path, entry.resolveSymbolicLinksSync())) {
        throw StateError('Refusing a redirected mock profile');
      }
    }
    if (File('${root.path}/owner').readAsStringSync() != _owner) {
      throw StateError('Refusing an unowned mock profile');
    }
  }

  static Future<void> _preflightProfile(
    Directory root,
    MockShopFixture fixture,
    String deviceId,
  ) async {
    final sqlite = raw.sqlite3.open(
      '${root.path}/wired_parts.sqlite',
      mode: raw.OpenMode.readOnly,
    );
    final model = AppDatabase.forTesting(
      NativeDatabase.opened(
        sqlite,
        enableMigrations: false,
        closeUnderlyingOnClose: false,
      ),
    );
    try {
      sqlite.execute('BEGIN');
      if (sqlite.select('PRAGMA user_version').single.values.single !=
              kAppSchemaVersion ||
          sqlite.select('PRAGMA integrity_check').single.values.single !=
              'ok' ||
          sqlite.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw StateError('Invalid mock profile database');
      }
      final expected = model.allTables.map((t) => t.actualTableName).toSet();
      final tables = sqlite
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%'",
          )
          .map((r) => r['name'])
          .toSet();
      if (tables.length != expected.length ||
          !tables.containsAll(expected) ||
          sqlite
              .select(
                "SELECT 1 FROM sqlite_master "
                "WHERE type IN ('trigger', 'view') LIMIT 1",
              )
              .isNotEmpty) {
        throw StateError('Unsupported mock profile schema');
      }
      for (final table in model.allTables) {
        final columns = sqlite
            .select('PRAGMA table_info("${table.actualTableName}")')
            .map((r) => r['name'])
            .toSet();
        final required = table.$columns.map((c) => c.name).toSet();
        if (columns.length != required.length ||
            !columns.containsAll(required)) {
          throw StateError('Unsupported mock profile columns');
        }
      }
      final devices = sqlite.select('SELECT id FROM device_profiles');
      final settings = {
        for (final r in sqlite.select('SELECT key, value FROM app_settings'))
          r['key']: r['value'],
      };
      if (devices.length != 1 ||
          devices.single['id'] != deviceId ||
          settings[_marker] != fixture.sha256Value ||
          settings['editor_pin_hash'] is! String ||
          !RegExp(r'^[0-9a-f]{32}:[0-9a-f]{64}$')
              .hasMatch(settings['editor_pin_hash'] as String) ||
          settings.containsKey(kInstallationBindingKey)) {
        throw StateError('Mock profile security state does not match');
      }
      for (final table in companyMarkerTables) {
        if (sqlite.select('SELECT 1 FROM "$table" LIMIT 1').isNotEmpty) {
          throw StateError('Company stores cannot resume as local mock shops');
        }
      }
      const references = [
        ('styles', 'category_id', 'categories'),
        ('types', 'style_id', 'styles'),
        ('parts', 'category_id', 'categories'),
        ('parts', 'style_id', 'styles'),
        ('parts', 'type_id', 'types'),
        ('parts', 'default_supplier_id', 'suppliers'),
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
      for (final (table, column, parent) in references) {
        if (sqlite
            .select(
              'SELECT 1 FROM "$table" child '
              'LEFT JOIN "$parent" parent ON child."$column" = parent.id '
              'WHERE child."$column" IS NOT NULL AND parent.id IS NULL LIMIT 1',
            )
            .isNotEmpty) {
          throw StateError('Invalid mock profile relationship');
        }
      }
      if (sqlite
          .select(
            'SELECT 1 FROM job_lines line '
            'JOIN brand_versions version ON line.brand_version_id = version.id '
            'WHERE line.part_id IS NULL OR line.part_id != version.part_id LIMIT 1',
          )
          .isNotEmpty) {
        throw StateError('Mock line variant belongs to another part');
      }
      await validateWarehouseStore(model);
    } finally {
      try {
        await model.close();
      } finally {
        sqlite.dispose();
      }
    }
  }

  void _requireOwned() {
    if (_closed ||
        FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync('${root.path}/owner', followLinks: false) !=
            FileSystemEntityType.file ||
        File('${root.path}/owner').readAsStringSync() != _owner ||
        FileSystemEntity.typeSync(databaseFile.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw StateError('Refusing an unowned mock workspace');
    }
  }

  Future<void> unlock() async {
    final secret = _secret;
    if (secret == null || !await pin.unlock(secret)) {
      throw StateError('Synthetic editor requires supported PIN unlock');
    }
  }

  Future<void> reopen() async {
    if (profileId != null) {
      throw StateError('Named mock profiles require close and explicit resume');
    }
    _requireOwned();
    await db.close();
    _db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    if (await db.settingsDao.ensureDeviceId() != deviceId) {
      throw StateError('Mock workspace device identity changed');
    }
    _pin = PinService(db.settingsDao);
    if (_secret != null) await unlock();
  }

  Future<void> close({bool retainForInspection = false}) async {
    if (_closed) return;
    try {
      await db.close();
      if (profileId == null && !retainForInspection) {
        _requireOwned();
        await root.delete(recursive: true);
      }
    } finally {
      _closed = true;
      _claim?.close();
    }
  }

  Future<MockImportReceipt> import(
    MockShopFixture fixture, {
    Future<void> Function()? beforeCommit,
  }) async {
    if (profileId != null && fixture.sha256Value != mockShopFixtureSha256) {
      throw StateError('Mock profile requires the frozen fixture');
    }
    _requireOwned();
    await pin.requireUnlocked();
    final projection = _project(fixture);
    final receipt = await legacyBusinessWrite(db, () async {
      await pin.requireUnlocked();
      final prior = await db.settingsDao.getSetting(_marker);
      final actual = await _readRows();
      for (final table in db.allTables) {
        final name = table.actualTableName;
        if (name == 'app_settings' ||
            name == 'device_profiles' ||
            projection.containsKey(name)) {
          continue;
        }
        if ((await db.customSelect('SELECT 1 FROM "$name" LIMIT 1').get())
            .isNotEmpty) {
          throw StateError('Mock target contains an unprojected business row');
        }
      }
      if (prior != null) {
        if (prior != fixture.sha256Value ||
            canonicalMockJson(actual) != canonicalMockJson(projection)) {
          throw StateError('Mock import collision: existing content changed');
        }
        return MockImportReceipt(
          fixtureHash: fixture.sha256Value,
          counts: _counts(projection),
          unchanged: true,
        );
      }
      for (final table in db.allTables) {
        final name = table.actualTableName;
        if (name == 'app_settings' || name == 'device_profiles') continue;
        if ((await db.customSelect('SELECT 1 FROM "$name" LIMIT 1').get())
            .isNotEmpty) {
          throw StateError('Mock importer requires an empty business store');
        }
      }
      final allowedSettings = await db.select(db.appSettings).get();
      if (allowedSettings.any((s) => s.key != 'editor_pin_hash')) {
        throw StateError('Refusing foreign app settings in mock target');
      }
      for (final table in _Table.values) {
        final name = table.sqlName;
        for (final row in projection[name]!) {
          final columns = row.keys.toList();
          final names = columns.map((c) => '"$c"').join(',');
          final placeholders = List.filled(columns.length, '?').join(',');
          await db.customStatement(
            'INSERT INTO "$name" ($names) VALUES ($placeholders)',
            [for (final c in columns) row[c]],
          );
        }
      }
      await beforeCommit?.call();
      await pin.requireUnlocked();
      if (canonicalMockJson(await _readRows()) !=
          canonicalMockJson(projection)) {
        throw StateError('Imported rows differ from the declared projection');
      }
      await db.settingsDao.setSetting(_marker, fixture.sha256Value);
      return MockImportReceipt(
        fixtureHash: fixture.sha256Value,
        counts: _counts(projection),
        unchanged: false,
      );
    });
    if (profileId != null) {
      final binding = File('${root.path}/profile.json');
      if (!binding.existsSync()) {
        await binding.create(exclusive: true);
        await binding.writeAsString(
          jsonEncode({
            'format': 1,
            'profile_id': profileId,
            'root': root.resolveSymbolicLinksSync(),
            'fixture_sha256': fixture.sha256Value,
            'schema_version': kAppSchemaVersion,
            'device_id': deviceId,
          }),
          flush: true,
        );
      }
    }
    return receipt;
  }

  Future<Map<String, List<Map<String, Object?>>>> _readRows() async => {
    for (final t in _Table.values)
      t.sqlName:
          (await db
                  .customSelect('SELECT * FROM "${t.sqlName}" ORDER BY id')
                  .get())
              .map((r) => r.data)
              .toList(),
  };

  Future<String> publicBusinessDigest() async => sha256
      .convert(utf8.encode(canonicalMockJson(await _readRows())))
      .toString();

  Map<String, int> _counts(Map<String, List<Map<String, Object?>>> rows) => {
    for (final e in rows.entries) e.key: e.value.length,
  };

  Map<String, List<Map<String, Object?>>> _project(MockShopFixture f) {
    final rows = {
      for (final t in _Table.values) t.sqlName: <Map<String, Object?>>[],
    };
    final time = f.asOf.millisecondsSinceEpoch ~/ 1000;
    Map<String, Object?> common(String id) => {
      'id': id,
      'origin_device_id': deviceId,
      'created_at': time,
      'modified_at': time,
      'revision': 1,
      'deleted_at': null,
    };
    void add(_Table t, Map<String, Object?> row) => rows[t.sqlName]!.add(row);
    final categories = <String>{};
    final brands = <String>{};
    for (final value in f.variants.values) {
      final v = value as Map<String, dynamic>;
      final category = v['category'] as String;
      final brand = v['brand'] as String;
      final cid = f.nativeId('category', category);
      final sid = f.nativeId('type', category);
      final tid = f.nativeId('variant-type', v['id']);
      if (categories.add(category)) {
        add(_Table.categories, {...common(cid), 'name': category});
        add(_Table.styles, {
          ...common(sid),
          'category_id': cid,
          'name': 'Fixture stock items',
        });
      }
      if (brands.add(brand)) {
        add(_Table.brands, {
          ...common(f.nativeId('brand', brand)),
          'name': brand,
        });
      }
      final vid = v['id'] as String;
      final part = f.nativeId('part', vid);
      final version = f.nativeId('brand-version', vid);
      final offers = f.offers.values
          .cast<Map<String, dynamic>>()
          .where((o) => o['variant_id'] == vid)
          .toList();
      add(_Table.types, {
        ...common(tid),
        'style_id': sid,
        'name': v['model_number'],
      });
      add(_Table.parts, {
        ...common(part),
        'name': v['name'],
        'description': v['name'],
        'category_id': cid,
        'style_id': sid,
        'type_id': tid,
        'uom': v['stock_unit'] == 'each' ? 'ea' : 'ft',
        'specs': canonicalMockJson(v),
        'keywords': vid,
        'photo_path': null,
        'active': 1,
        'default_supplier_id': f.nativeId(
          'supplier',
          offers.first['supplier_id'],
        ),
      });
      add(_Table.versions, {
        ...common(version),
        'part_id': part,
        'brand_id': f.nativeId('brand', brand),
        'mpn': v['model_number'],
        'model': v['model_number'],
        'description': v['name'],
        'variance_name': v['color'] ?? '',
        'is_main': 1,
      });
    }
    for (final value in f.suppliers.values) {
      final s = value as Map<String, dynamic>;
      add(_Table.suppliers, {
        ...common(f.nativeId('supplier', s['id'])),
        'name': s['name'],
      });
    }
    for (final value in f.offers.values) {
      final o = value as Map<String, dynamic>;
      add(_Table.listings, {
        ...common(f.nativeId('offer', o['id'])),
        'brand_version_id': f.nativeId('brand-version', o['variant_id']),
        'supplier_id': f.nativeId('supplier', o['supplier_id']),
        'sku': o['supplier_sku'] ?? '',
        'description': 'Fixture supplier listing; online ID is in provenance',
        'package_qty':
            (f.variants[o['variant_id']]['quantity_per_sell_unit'] as num)
                .toDouble(),
        'last_price': (o['price_usd'] as num?)?.toDouble(),
        'notes': canonicalMockJson(o),
      });
    }
    for (final value in f.jobs.values) {
      final j = value as Map<String, dynamic>;
      final customer = f.raw['customers'][j['customer_id']];
      add(_Table.jobs, {
        ...common(f.nativeId('job', j['id'])),
        'name': j['title'],
        'customer': customer['name'],
        'location': customer['site_label'],
        'job_number': j['id'],
        'status': const ['completed', 'cancelled'].contains(j['status'])
            ? 'archived'
            : 'active',
        'notes': canonicalMockJson({
          'fixture': j,
          'native_status_projection':
              const ['completed', 'cancelled'].contains(j['status'])
              ? 'archived'
              : 'active',
          'unsupported_workflow_stage': j['status'],
        }),
      });
    }
    for (final value in f.materials.values) {
      final l = value as Map<String, dynamic>;
      add(_Table.lines, {
        ...common(f.nativeId('material', l['id'])),
        'job_id': f.nativeId('job', l['job_id']),
        'part_id': f.nativeId('part', l['variant_id']),
        'brand_version_id': f.nativeId('brand-version', l['variant_id']),
        'custom_name': null,
        'custom_notes': null,
        'needed_qty': (l['planned_qty'] as num).toDouble(),
        'shop_pull_qty':
            ((l['issued_qty'] as num) -
                    (l['returned_qty'] as num) +
                    (l['reserved_qty'] as num))
                .toDouble(),
        'uom': l['stock_unit'] == 'each' ? 'ea' : 'ft',
        'notes': canonicalMockJson(l),
      });
    }
    for (final value in f.locations.values) {
      final l = value as Map<String, dynamic>;
      add(_Table.locations, {
        ...common(f.nativeId('location', l['id'])),
        'name': l['name'],
        'name_key': warehouseNameKey(l['name']),
      });
    }
    for (final value in f.stock) {
      final r = value as Map<String, dynamic>;
      final lid = r['location_id'] as String;
      final vid = r['variant_id'] as String;
      add(_Table.counts, {
        'id': f.nativeId('count', '$lid/$vid'),
        'location_id': f.nativeId('location', lid),
        'part_id': f.nativeId('part', vid),
        'prior_count_id': null,
        'ordinal': 1,
        'quantity': (r['on_hand_qty'] as num).toDouble(),
        'uom': f.variants[vid]['stock_unit'] == 'each' ? 'ea' : 'ft',
        'observed_at': time,
        'recorded_at': time,
        'origin_device_id': deviceId,
        'note': canonicalMockJson({
          'fixture_stock': r,
          'projection': 'absolute on-hand observation only',
        }),
      });
    }
    for (final value in rows.values) {
      value.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    }
    return rows;
  }
}
