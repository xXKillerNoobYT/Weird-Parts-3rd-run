import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/company/company_store_markers.dart';

void main() {
  test('schema6 mid-DDL upgrade failure rolls back new schema8 and enrollment tables', () async {
    final directory = Directory.systemTemp.createTempSync('join-ddl-rollback-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/shop.sqlite');
    final original = AppDatabase.forTesting(NativeDatabase(file));
    await original.jobsDao.insertJob(
      id: 'retained-job',
      name: 'Retained before failed migration',
      deviceId: 'retained-device',
    );
    await original.settingsDao.setSetting('migration-marker', 'kept');
    await original.close();
    final raw = sqlite.sqlite3.open(file.path);
    for (final table in {
      ...companyJoinTableColumns,
      ...companySyncTableColumns,
    }.keys) {
      raw.execute('DROP TABLE "$table"');
    }
    // Intentional fault: the second DDL must fail after the first CREATE.
    raw.execute('CREATE INDEX company_join_requests ON jobs(name)');
    raw.execute('PRAGMA user_version = 6');
    Map<String, Object?> snapshot(sqlite.Database database) => {
      'version': database.select('PRAGMA user_version').single['user_version'],
      'schema': database
          .select('SELECT name, sql FROM sqlite_master ORDER BY name')
          .map(Map<String, Object?>.from)
          .toList(),
      'jobs': database
          .select('SELECT * FROM jobs ORDER BY id')
          .map(Map<String, Object?>.from)
          .toList(),
      'settings': database
          .select('SELECT * FROM app_settings ORDER BY key')
          .map(Map<String, Object?>.from)
          .toList(),
    };
    final before = snapshot(raw);
    raw.dispose();
    final beforeBytes = base64Encode(file.readAsBytesSync());
    final upgrading = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await expectLater(
        upgrading.customSelect('SELECT 1').get(),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('index named') &&
                error.toString().contains('company_join_requests'),
          ),
        ),
      );
    } finally {
      await upgrading.close();
    }
    final after = sqlite.sqlite3.open(
      file.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      expect(snapshot(after), before);
      expect(
        after.select(
          "SELECT name FROM sqlite_master WHERE name='company_membership_certificates'",
        ),
        isEmpty,
      );
      expect(after.select('PRAGMA integrity_check').single.values.single, 'ok');
    } finally {
      after.dispose();
    }
    expect(
      base64Encode(file.readAsBytesSync()) == beforeBytes,
      isTrue,
      reason: 'failed additive migration preserves exact database bytes',
    );
  });
  for (final table in {
    ...companyJoinTableColumns,
    ...companySyncTableColumns,
  }.keys) {
    test('orphan $table refuses Create Join and legacy Jobs without mutation', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final columns = {
        ...companyJoinTableColumns,
        ...companySyncTableColumns,
      }[table]!.toList();
      await db.customStatement(
        'INSERT INTO "$table" (${columns.map((n) => '"$n"').join(',')}) VALUES (${columns.map((_) => '?').join(',')})',
        [
          for (final column in columns)
            {'ordinal', 'issuer_sequence'}.contains(column)
                ? 1
                : 'synthetic-orphan',
        ],
      );
      final before = (await db.customSelect('SELECT * FROM "$table"').get())
          .map((r) => r.data)
          .toList();
      await expectLater(
        CompanyBootstrap.preflightFreshShop(db),
        throwsA(anything),
      );
      await expectLater(
        db.jobsDao.insertJob(id: 'denied', name: 'denied', deviceId: 'legacy'),
        throwsA(anything),
      );
      expect(await db.select(db.jobs).get(), isEmpty);
      expect(
        (await db.customSelect('SELECT * FROM "$table"').get())
            .map((r) => r.data)
            .toList(),
        before,
      );
    });
    for (final malformed in ['missing', 'wrong columns']) {
      test(
        'schema8 $malformed $table refuses adoption and legacy writes',
        () async {
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(db.close);
          await db.customStatement('DROP TABLE "$table"');
          if (malformed == 'wrong columns') {
            await db.customStatement('CREATE TABLE "$table" (wrong TEXT)');
          }
          final before = await db
              .customSelect("SELECT name, sql FROM sqlite_master ORDER BY name")
              .get();
          final settings = await db.select(db.appSettings).get();
          await expectLater(
            CompanyBootstrap.preflightFreshShop(db),
            throwsA(anything),
          );
          await expectLater(
            db.jobsDao.insertJob(
              id: 'denied',
              name: 'denied',
              deviceId: 'legacy',
            ),
            throwsA(anything),
          );
          expect(await db.select(db.jobs).get(), isEmpty);
          expect(await db.select(db.appSettings).get(), settings);
          expect(
            (await db
                    .customSelect(
                      "SELECT name, sql FROM sqlite_master ORDER BY name",
                    )
                    .get())
                .map((r) => r.data),
            before.map((r) => r.data),
          );
        },
      );
    }
  }

  test('custody storage uses only a reserved companion namespace', () {
    expect(companyCustodyNamespace('production'), 'production.company-custody');
    expect(
      companyCustodyNamespace('synthetic.test'),
      'synthetic.test.company-custody',
    );
    expect(
      () => companyCustodyNamespace('production.other'),
      throwsArgumentError,
    );
  });

  test('bootstrap witness has its own downgrade-blocking schema', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 8);
    await db.customStatement(
      "INSERT INTO company_bootstrap_witnesses "
      "(company_id, bootstrap_id, facts_commitment, package_id, package_digest, status) "
      "VALUES ('company', 'intent', 'facts', 'package', NULL, 'pending')",
    );
    await expectLater(
      CompanyBootstrap.preflightFreshShop(db),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
  });

  test('Create Company admits only an empty, unadopted shop', () async {
    final empty = AppDatabase.forTesting(NativeDatabase.memory());
    await expectLater(CompanyBootstrap.preflightFreshShop(empty), completes);
    await empty.close();

    final legacy = AppDatabase.forTesting(NativeDatabase.memory());
    await legacy.customStatement(
      "INSERT INTO categories (id, origin_device_id, created_at, modified_at, revision, name) "
      "VALUES ('legacy-category', 'old-device', 1, 1, 1, 'Electrical')",
    );
    await expectLater(
      CompanyBootstrap.preflightFreshShop(legacy),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
    await legacy.close();

    final company = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(company.close);
    await company.customStatement(
      "INSERT INTO company_authority_facts (company_id, commitment, signed_bytes) "
      "VALUES ('existing', 'digest', 'bytes')",
    );
    await expectLater(
      CompanyBootstrap.preflightFreshShop(company),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
  });
  test(
    'orphan company Job journal blocks fresh adoption and legacy mutation',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement(
        "INSERT INTO company_jobs (job_id, company_id, shop_id, origin_generation, request_id, operation_commitment, command_commitment, operation_bytes, projection_bytes, receipt_key, receipt_bytes, audit_bytes, outgoing) VALUES ('orphan', 'company', 'shop', 'origin', 'request', 'op', 'command', '{}', '{}', 'receipt', '{}', '{}', 1)",
      );
      await expectLater(
        CompanyBootstrap.preflightFreshShop(db),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      await expectLater(
        db.jobsDao.insertJob(
          id: 'legacy',
          name: 'must refuse',
          deviceId: 'device',
        ),
        throwsA(isA<StateError>()),
      );
      expect(await db.select(db.jobs).get(), isEmpty);
    },
  );
}
