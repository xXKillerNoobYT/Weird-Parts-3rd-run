import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

void main() {
  test(
    'encrypted backup restores warehouse locations and full count history',
    () async {
      final source = Directory.systemTemp.createTempSync('wp-warehouse-src-');
      final destination = Directory.systemTemp.createTempSync(
        'wp-warehouse-dst-',
      );
      addTearDown(() => source.deleteSync(recursive: true));
      addTearDown(() => destination.deleteSync(recursive: true));

      final sourceFile = await _createShop(source, includeWarehouse: true);
      final liveFile = await _createShop(destination);
      final originalLive = liveFile.readAsBytesSync();
      final livePhotos = Directory(p.join(destination.path, 'part_photos'))
        ..createSync();
      File(p.join(livePhotos.path, 'keep.jpg')).writeAsBytesSync([7, 7]);
      final sourcePhotos = Directory(p.join(source.path, 'part_photos'))
        ..createSync();
      File(p.join(sourcePhotos.path, 'warehouse-part.jpg'))
          .writeAsBytesSync([0xFF, 0xD8, 4, 5, 0xFF, 0xD9]);
      final store = BackupStore(supportDir: source);
      final codec = BackupCodec(iterations: 1000);
      final payload = await store.collect(
        sourceDeviceId: 'synthetic-source',
        createdAt: DateTime.utc(2026, 10, 20),
        sqliteBytes: Uint8List.fromList(sourceFile.readAsBytesSync()),
      );
      final encrypted = await codec.encrypt(payload, 'synthetic password');
      await expectLater(
        codec.decrypt(encrypted, 'incorrect password'),
        throwsA(isA<BackupFormatException>()),
      );
      final damagedEncrypted = Uint8List.fromList(encrypted)
        ..[encrypted.length - 1] ^= 1;
      await expectLater(
        codec.decrypt(damagedEncrypted, 'synthetic password'),
        throwsA(isA<BackupFormatException>()),
      );
      expect(liveFile.readAsBytesSync(), originalLive);
      expect(File(p.join(livePhotos.path, 'keep.jpg')).readAsBytesSync(), [
        7,
        7,
      ]);
      final decoded = await codec.decrypt(encrypted, 'synthetic password');
      await BackupStore(supportDir: destination).replaceWithPayload(
        payload: decoded,
        reset: LocalDataReset(
          supportDir: destination,
          documentsDir: destination,
        ),
      );

      final restored = AppDatabase.forTesting(
        NativeDatabase(File(p.join(destination.path, kSqliteFileName))),
      );
      try {
        final locations = await restored
            .select(restored.warehouseLocations)
            .get();
        final counts = await (restored.select(
          restored.warehouseCounts,
        )..orderBy([(t) => OrderingTerm.asc(t.ordinal)])).get();
        expect(locations.map((row) => (row.id, row.name, row.nameKey)), [
          ('loc-1', 'Front counter', 'front counter'),
        ]);
        expect(counts, hasLength(2));
        expect(counts[0].id, 'count-1');
        expect(counts[0].priorCountId, isNull);
        expect(counts[0].quantity, 8.5);
        expect(counts[0].uom, 'ea');
        expect(counts[0].note, 'opening count');
        expect(counts[1].id, 'count-2');
        expect(counts[1].priorCountId, 'count-1');
        expect(counts[1].ordinal, 2);
        expect(counts[1].quantity, 6);
        expect(counts[1].note, 'after sale');
        expect(counts.every((row) => row.partId == 'part-1'), isTrue);
        expect(counts.every((row) => row.locationId == 'loc-1'), isTrue);
        expect(
          File(p.join(destination.path, 'part_photos', 'warehouse-part.jpg'))
              .readAsBytesSync(),
          [0xFF, 0xD8, 4, 5, 0xFF, 0xD9],
        );
      } finally {
        await restored.close();
      }
    },
  );

  test(
    'schema 11 backup upgrades in staging with empty warehouse tables',
    () async {
      final oldBackup = Directory.systemTemp.createTempSync(
        'wp-warehouse-v11-',
      );
      final destination = Directory.systemTemp.createTempSync(
        'wp-warehouse-v11-dst-',
      );
      addTearDown(() => oldBackup.deleteSync(recursive: true));
      addTearDown(() => destination.deleteSync(recursive: true));
      final oldFile = await _createShop(oldBackup);
      final raw = raw_sqlite.sqlite3.open(oldFile.path);
      try {
        raw.execute('DROP TABLE warehouse_counts');
        raw.execute('DROP TABLE warehouse_locations');
        raw.execute('DROP TABLE company_user_events');
        raw.execute('DROP TABLE company_user_deliveries');
        raw.execute('PRAGMA user_version = 11');
      } finally {
        raw.dispose();
      }
      final original = oldFile.readAsBytesSync();
      final payload = BackupPayload(
        createdAt: DateTime.utc(2026, 10, 20),
        sourceDeviceId: 'synthetic-v11',
        sqliteBytes: Uint8List.fromList(original),
        photos: const {},
      );

      await BackupStore(supportDir: destination).replaceWithPayload(
        payload: payload,
        reset: LocalDataReset(
          supportDir: destination,
          documentsDir: destination,
        ),
      );

      expect(oldFile.readAsBytesSync(), original);
      final restored = AppDatabase.forTesting(
        NativeDatabase(File(p.join(destination.path, kSqliteFileName))),
      );
      try {
        expect(await restored.select(restored.parts).get(), hasLength(1));
        expect(
          await restored.select(restored.warehouseLocations).get(),
          isEmpty,
        );
        expect(await restored.select(restored.warehouseCounts).get(), isEmpty);
      } finally {
        await restored.close();
      }
    },
  );

  test(
    'schema 12 backup missing a warehouse table refuses before live swap',
    () async {
      final destination = Directory.systemTemp.createTempSync(
        'wp-warehouse-live-',
      );
      final bad = Directory.systemTemp.createTempSync('wp-warehouse-missing-');
      addTearDown(() => destination.deleteSync(recursive: true));
      addTearDown(() => bad.deleteSync(recursive: true));
      final liveFile = await _createShop(destination);
      final originalSqlite = liveFile.readAsBytesSync();
      final livePhotos = Directory(p.join(destination.path, 'part_photos'))
        ..createSync();
      final livePhoto = File(p.join(livePhotos.path, 'keep.jpg'))
        ..writeAsBytesSync([8, 9]);

      final badFile = await _createShop(bad);
      final malformed = AppDatabase.forTesting(NativeDatabase(badFile));
      await malformed.customStatement('DROP TABLE warehouse_counts');
      await malformed.close();
      final payload = BackupPayload(
        createdAt: DateTime.utc(2026, 10, 20),
        sourceDeviceId: 'synthetic-source',
        sqliteBytes: Uint8List.fromList(badFile.readAsBytesSync()),
        photos: {
          'replacement.jpg': Uint8List.fromList([1, 2]),
        },
      );

      await expectLater(
        BackupStore(supportDir: destination).replaceWithPayload(
          payload: payload,
          reset: LocalDataReset(
            supportDir: destination,
            documentsDir: destination,
          ),
        ),
        throwsA(isA<BackupFormatException>()),
      );
      expect(liveFile.readAsBytesSync(), originalSqlite);
      expect(livePhoto.readAsBytesSync(), [8, 9]);
      expect(
        File(p.join(livePhotos.path, 'replacement.jpg')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'schema 12 backup with wrong warehouse columns refuses before live swap',
    () async {
      final destination = Directory.systemTemp.createTempSync(
        'wp-warehouse-live-columns-',
      );
      final bad = Directory.systemTemp.createTempSync(
        'wp-warehouse-bad-columns-',
      );
      addTearDown(() => destination.deleteSync(recursive: true));
      addTearDown(() => bad.deleteSync(recursive: true));
      final liveFile = await _createShop(destination);
      final originalSqlite = liveFile.readAsBytesSync();
      final badFile = await _createShop(bad);
      final raw = raw_sqlite.sqlite3.open(badFile.path);
      try {
        raw.execute('DROP TABLE warehouse_locations');
        raw.execute('CREATE TABLE warehouse_locations (id TEXT PRIMARY KEY)');
      } finally {
        raw.dispose();
      }
      final payload = BackupPayload(
        createdAt: DateTime.utc(2026, 10, 20),
        sourceDeviceId: 'synthetic-source',
        sqliteBytes: Uint8List.fromList(badFile.readAsBytesSync()),
        photos: const {},
      );

      await expectLater(
        BackupStore(supportDir: destination).replaceWithPayload(
          payload: payload,
          reset: LocalDataReset(
            supportDir: destination,
            documentsDir: destination,
          ),
        ),
        throwsA(isA<BackupFormatException>()),
      );
      expect(liveFile.readAsBytesSync(), originalSqlite);
    },
  );

  for (final malformedIdentity in ['location-id', 'count-id']) {
    test(
      'schema 12 backup refuses duplicate warehouse $malformedIdentity before live swap',
      () async {
        final destination = Directory.systemTemp.createTempSync(
          'wp-warehouse-live-duplicate-',
        );
        final bad = Directory.systemTemp.createTempSync(
          'wp-warehouse-bad-duplicate-',
        );
        addTearDown(() => destination.deleteSync(recursive: true));
        addTearDown(() => bad.deleteSync(recursive: true));
        final liveFile = await _createShop(destination);
        final originalSqlite = liveFile.readAsBytesSync();
        final livePhotos = Directory(p.join(destination.path, 'part_photos'))
          ..createSync();
        final livePhoto = File(p.join(livePhotos.path, 'keep.jpg'))
          ..writeAsBytesSync([8, 9]);
        final badFile = await _createShop(bad);
        final raw = raw_sqlite.sqlite3.open(badFile.path);
        final now = DateTime.utc(2026, 10, 20, 12).millisecondsSinceEpoch;
        try {
          raw.execute('DROP TABLE warehouse_counts');
          raw.execute('DROP TABLE warehouse_locations');
          raw.execute('''
            CREATE TABLE warehouse_locations (
              id TEXT, origin_device_id TEXT, created_at INTEGER,
              modified_at INTEGER, revision INTEGER, deleted_at INTEGER,
              name TEXT, name_key TEXT
            )
          ''');
          raw.execute('''
            CREATE TABLE warehouse_counts (
              id TEXT, location_id TEXT, part_id TEXT, prior_count_id TEXT,
              ordinal INTEGER, quantity REAL, uom TEXT, observed_at INTEGER,
              recorded_at INTEGER, origin_device_id TEXT, note TEXT
            )
          ''');
          raw.execute(
            'INSERT INTO warehouse_locations VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [
              'loc-1',
              'synthetic-device',
              now,
              now,
              1,
              null,
              'Front counter',
              'front counter',
            ],
          );
          if (malformedIdentity == 'location-id') {
            raw.execute(
              'INSERT INTO warehouse_locations VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
              [
                'loc-1',
                'synthetic-device',
                now,
                now,
                1,
                null,
                'Back room',
                'back room',
              ],
            );
          } else {
            raw.execute(
              'INSERT INTO warehouse_counts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              [
                'count-1',
                'loc-1',
                'part-1',
                null,
                1,
                8.0,
                'ea',
                now,
                now,
                'synthetic-device',
                'opening',
              ],
            );
            raw.execute(
              'INSERT INTO warehouse_counts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              [
                'count-1',
                'loc-1',
                'part-1',
                'count-1',
                2,
                6.0,
                'ea',
                now + 1000,
                now + 1000,
                'synthetic-device',
                'recount',
              ],
            );
          }
        } finally {
          raw.dispose();
        }
        final payload = BackupPayload(
          createdAt: DateTime.utc(2026, 10, 20),
          sourceDeviceId: 'synthetic-source',
          sqliteBytes: Uint8List.fromList(badFile.readAsBytesSync()),
          photos: {
            'replacement.jpg': Uint8List.fromList([1, 2]),
          },
        );

        Object? replacementFailure;
        try {
          await BackupStore(supportDir: destination).replaceWithPayload(
            payload: payload,
            reset: LocalDataReset(
              supportDir: destination,
              documentsDir: destination,
            ),
          );
        } catch (error) {
          replacementFailure = error;
        }
        final liveChanged =
            liveFile.readAsBytesSync().join(',') != originalSqlite.join(',');
        expect(
          replacementFailure,
          isA<BackupFormatException>(),
          reason:
              'Expected duplicate identity refusal; actual error: '
              '$replacementFailure; live SQLite changed: $liveChanged; '
              'live keep photo exists: ${livePhoto.existsSync()}; replacement '
              'photo exists: ${File(p.join(livePhotos.path, 'replacement.jpg')).existsSync()}',
        );
        expect(liveFile.readAsBytesSync(), originalSqlite);
        expect(livePhoto.readAsBytesSync(), [8, 9]);
        expect(
          File(p.join(livePhotos.path, 'replacement.jpg')).existsSync(),
          isFalse,
        );
      },
    );
  }

  test('malformed warehouse causal history refuses before live swap', () async {
    final destination = Directory.systemTemp.createTempSync(
      'wp-warehouse-live-chain-',
    );
    final bad = Directory.systemTemp.createTempSync('wp-warehouse-bad-chain-');
    addTearDown(() => destination.deleteSync(recursive: true));
    addTearDown(() => bad.deleteSync(recursive: true));
    final liveFile = await _createShop(destination);
    final originalSqlite = liveFile.readAsBytesSync();
    final badFile = await _createShop(bad, includeWarehouse: true);
    final raw = raw_sqlite.sqlite3.open(badFile.path);
    try {
      raw.execute(
        "UPDATE warehouse_counts SET prior_count_id = 'missing-parent' WHERE id = 'count-2'",
      );
    } finally {
      raw.dispose();
    }
    final payload = BackupPayload(
      createdAt: DateTime.utc(2026, 10, 20),
      sourceDeviceId: 'synthetic-source',
      sqliteBytes: Uint8List.fromList(badFile.readAsBytesSync()),
      photos: const {},
    );

    await expectLater(
      BackupStore(supportDir: destination).replaceWithPayload(
        payload: payload,
        reset: LocalDataReset(
          supportDir: destination,
          documentsDir: destination,
        ),
      ),
      throwsA(isA<BackupFormatException>()),
    );
    expect(liveFile.readAsBytesSync(), originalSqlite);
  });

  test(
    'count cannot continue a prior observation from a different location',
    () async {
      final destination = Directory.systemTemp.createTempSync(
        'wp-warehouse-live-pair-',
      );
      final bad = Directory.systemTemp.createTempSync('wp-warehouse-bad-pair-');
      addTearDown(() => destination.deleteSync(recursive: true));
      addTearDown(() => bad.deleteSync(recursive: true));
      final liveFile = await _createShop(destination);
      final originalSqlite = liveFile.readAsBytesSync();
      final badFile = await _createShop(bad, includeWarehouse: true);
      final malformed = AppDatabase.forTesting(NativeDatabase(badFile));
      final now = DateTime.utc(2026, 10, 20, 12);
      await malformed
          .into(malformed.warehouseLocations)
          .insert(
            WarehouseLocationsCompanion.insert(
              id: 'loc-2',
              originDeviceId: 'synthetic-device',
              createdAt: now,
              modifiedAt: now,
              name: 'Back room',
              nameKey: 'back room',
            ),
          );
      await malformed.close();
      final raw = raw_sqlite.sqlite3.open(badFile.path);
      try {
        raw.execute(
          "UPDATE warehouse_counts SET location_id = 'loc-2' WHERE id = 'count-2'",
        );
      } finally {
        raw.dispose();
      }
      final payload = BackupPayload(
        createdAt: DateTime.utc(2026, 10, 20),
        sourceDeviceId: 'synthetic-source',
        sqliteBytes: Uint8List.fromList(badFile.readAsBytesSync()),
        photos: const {},
      );

      await expectLater(
        BackupStore(supportDir: destination).replaceWithPayload(
          payload: payload,
          reset: LocalDataReset(
            supportDir: destination,
            documentsDir: destination,
          ),
        ),
        throwsA(isA<BackupFormatException>()),
      );
      expect(liveFile.readAsBytesSync(), originalSqlite);
    },
  );
}

Future<File> _createShop(Directory dir, {bool includeWarehouse = false}) async {
  final file = File(p.join(dir.path, kSqliteFileName));
  final db = AppDatabase.forTesting(NativeDatabase(file));
  final now = DateTime.utc(2026, 10, 20, 12);
  await db
      .into(db.parts)
      .insert(
        PartsCompanion.insert(
          id: 'part-1',
          name: 'Synthetic filter',
          originDeviceId: 'synthetic-device',
          createdAt: now,
          modifiedAt: now,
        ),
      );
  if (includeWarehouse) {
    await db
        .into(db.warehouseLocations)
        .insert(
          WarehouseLocationsCompanion.insert(
            id: 'loc-1',
            originDeviceId: 'synthetic-device',
            createdAt: now,
            modifiedAt: now,
            name: 'Front counter',
            nameKey: 'front counter',
          ),
        );
    await db
        .into(db.warehouseCounts)
        .insert(
          WarehouseCountsCompanion.insert(
            id: 'count-1',
            locationId: 'loc-1',
            partId: 'part-1',
            ordinal: 1,
            quantity: 8.5,
            uom: 'ea',
            observedAt: now,
            recordedAt: now,
            originDeviceId: 'synthetic-device',
            note: const Value('opening count'),
          ),
        );
    await db
        .into(db.warehouseCounts)
        .insert(
          WarehouseCountsCompanion.insert(
            id: 'count-2',
            locationId: 'loc-1',
            partId: 'part-1',
            priorCountId: const Value('count-1'),
            ordinal: 2,
            quantity: 6,
            uom: 'ea',
            observedAt: now.add(const Duration(hours: 1)),
            recordedAt: now.add(const Duration(hours: 1)),
            originDeviceId: 'synthetic-device',
            note: const Value('after sale'),
          ),
        );
  }
  await db.close();
  return file;
}
