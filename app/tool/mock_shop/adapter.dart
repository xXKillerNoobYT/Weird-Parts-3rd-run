import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/company/company_store_markers.dart';
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

final class MockLocalWorkspace {
  MockLocalWorkspace._(
    this.root, this._db, this._pin, this._secret, this._deviceId,
  );

  static const _owner = 'wired-parts-mock-shop-v1';
  static const _marker = 'mock_shop_import_v1';
  final Directory root;
  AppDatabase _db;
  PinService _pin;
  AppDatabase get db => _db;
  PinService get pin => _pin;
  final String _secret;
  final String _deviceId;
  bool _closed = false;
  String get deviceId => _deviceId;
  File get databaseFile => File('${root.path}/wired_parts.sqlite');

  static Future<MockLocalWorkspace> create() async {
    final root = await Directory.systemTemp.createTemp(
      'wired-parts-mock-shop-',
    );
    await File('${root.path}/owner').writeAsString(_owner, flush: true);
    final db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/wired_parts.sqlite')),
    );
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);
    final secret = ephemeralMockPin();
    await pin.setPin(secret);
    await pin.unlock(secret);
    return MockLocalWorkspace._(root, db, pin, secret, deviceId);
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

  Future<void> unlock() => pin.unlock(_secret).then((ok) {
    if (!ok) throw StateError('Synthetic editor unlock failed');
  });

  Future<void> reopen() async {
    _requireOwned();
    await db.close();
    _db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    if (await db.settingsDao.ensureDeviceId() != deviceId) {
      throw StateError('Mock workspace device identity changed');
    }
    _pin = PinService(db.settingsDao);
    await unlock();
  }

  Future<void> close({bool retainForInspection = false}) async {
    if (_closed) return;
    _requireOwned();
    await db.close();
    _closed = true;
    if (!retainForInspection) await root.delete(recursive: true);
  }

  Future<MockImportReceipt> import(
    MockShopFixture fixture, {
    Future<void> Function()? beforeCommit,
  }) async {
    _requireOwned();
    await pin.requireUnlocked();
    final projection = _project(fixture);
    return legacyBusinessWrite(db, () async {
      await pin.requireUnlocked();
      final prior = await db.settingsDao.getSetting(_marker);
      final actual = await _readRows();
      for (final table in db.allTables) {
        final name = table.actualTableName;
        if (name == 'app_settings' || name == 'device_profiles' ||
            projection.containsKey(name)) continue;
        if ((await db.customSelect('SELECT 1 FROM "' + name +
            '" LIMIT 1').get()).isNotEmpty) {
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
