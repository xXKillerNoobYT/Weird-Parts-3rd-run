import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:wired_parts/data/app_database.dart';

import 'warehouse_test_support.dart';

void main() {
  test(
    'fresh shop contains persistent warehouse locations and counts',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get();
      final names = rows.map((row) => row.read<String>('name')).toSet();
      expect(names, containsAll(['warehouse_locations', 'warehouse_counts']));
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        kAppSchemaVersion,
      );
    },
  );

  test(
    'schema11 upgrade preserves the complete populated legacy shop',
    () async {
      final dir = Directory.systemTemp.createTempSync('warehouse-upgrade-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/shop.sqlite');
      final fixture = await WarehouseFixture.create(file: file);
      final before = await fixture.snapshot();
      await fixture.db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE warehouse_counts');
      raw.execute('DROP TABLE warehouse_locations');
      raw.execute('DROP TABLE company_user_events');
      raw.execute('DROP TABLE company_user_deliveries');
      raw.execute('PRAGMA user_version = 11');
      raw.dispose();
      final db = AppDatabase.forTesting(NativeDatabase(file));
      try {
        expect(await db.select(db.warehouseCounts).get(), isEmpty);
        expect(await db.select(db.warehouseLocations).get(), isEmpty);
        for (final entry in before.entries) {
          if (entry.key.startsWith('warehouse_') ||
              entry.key.startsWith('company_user_')) {
            continue;
          }
          expect(
            (await db
                    .customSelect('SELECT * FROM "${entry.key}" ORDER BY rowid')
                    .get())
                .map((r) => r.data)
                .toList(),
            entry.value,
            reason: entry.key,
          );
        }
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          kAppSchemaVersion,
        );
      } finally {
        await db.close();
      }
    },
  );

  test(
    'second-table migration failure rolls back first table and schema version',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'warehouse-upgrade-failure-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/shop.sqlite');
      final fixture = await WarehouseFixture.create(file: file);
      final part = await fixture.catalog.getPart(fixture.partId);
      await fixture.db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE warehouse_counts');
      raw.execute('DROP TABLE warehouse_locations');
      raw.execute('DROP TABLE company_user_events');
      raw.execute('DROP TABLE company_user_deliveries');
      raw.execute('CREATE TABLE migration_blocker (id INTEGER)');
      raw.execute('CREATE INDEX warehouse_counts ON migration_blocker(id)');
      raw.execute('PRAGMA user_version = 11');
      raw.dispose();
      final db = AppDatabase.forTesting(NativeDatabase(file));
      try {
        await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
      } finally {
        await db.close();
      }
      final check = sqlite.sqlite3.open(file.path);
      try {
        expect(check.select('PRAGMA user_version').single['user_version'], 11);
        expect(
          check.select(
            "SELECT name FROM sqlite_master WHERE name='warehouse_locations'",
          ),
          isEmpty,
        );
        expect(check.select('SELECT id, name FROM parts').single, {
          'id': part!.id,
          'name': part.name,
        });
      } finally {
        check.dispose();
      }
    },
  );
}
