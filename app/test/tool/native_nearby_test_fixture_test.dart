import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:wired_parts/data/app_database.dart';

import '../../tool/nearby_lan_validation.dart';
import '../../tool/nearby_lan_workspace.dart';
import '../../tool/native_nearby_test_crypto.dart';
import '../../tool/native_nearby_test_fixture.dart';

void main() {
  late Directory temp;
  ValidationWorkspace? workspace;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('native-fixture-unit-');
  });
  tearDown(() {
    workspace?.close();
    workspace = null;
    temp.deleteSync(recursive: true);
  });

  test(
    'resident refuses an absent fixture without creating a root or lock',
    () {
      expect(
        () => openExistingNativeFixture(
          run: 'unit',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        ),
        throwsA(isA<NativeTestFailure>()),
      );
      expect(temp.listSync(), isEmpty);
    },
  );

  test('locked existing-only workspace cannot initialize an absent root', () {
    expect(
      () => ValidationWorkspace.open(
        run: 'unit',
        role: ValidationRole.sender,
        temporaryDirectory: temp,
        requireExisting: true,
      ),
      throwsStateError,
    );
    expect(
      Directory(p.join(temp.path, 'wired-parts-lan-unit-sender')).existsSync(),
      false,
    );
  });

  test(
    'missing database and altered owner are rejected before storage opens',
    () {
      workspace = ValidationWorkspace.open(
        run: 'unit',
        role: ValidationRole.sender,
        temporaryDirectory: temp,
      );
      workspace!.markInitialized();
      workspace!.close();
      expect(
        () => openExistingNativeFixture(
          run: 'unit',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        ),
        throwsA(isA<NativeTestFailure>()),
      );
      File(p.join(workspace!.support.path, 'wired_parts.sqlite'))
          .writeAsStringSync('untouched');
      File(p.join(workspace!.root.path, 'validation-owner.json'))
          .writeAsStringSync(
            jsonEncode({
              'format': 1,
              'run': 'unit',
              'role': 'receiver',
              'root': workspace!.root.path,
              'initialized': true,
            }),
          );
      expect(
        () => openExistingNativeFixture(
          run: 'unit',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        ),
        throwsA(isA<NativeTestFailure>()),
      );
      expect(
        File(p.join(workspace!.support.path, 'wired_parts.sqlite'))
            .readAsStringSync(),
        'untouched',
      );
    },
  );

  test(
    'capture retains tombstones and catches broken references and live edits',
    () async {
      workspace = ValidationWorkspace.open(
        run: 'unit',
        role: ValidationRole.sender,
        temporaryDirectory: temp,
      );
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedValidationShop(db, workspace!);
      final baseline = await NativeFixtureSnapshot.capture(db, workspace!);
      expect(baseline.schemaVersion, 2);
      expect(baseline.rowCount, 14);
      expect(baseline.referenceCount, 16);
      expect(baseline.referencesValid, true);
      expect(baseline.integrityValid, true);
      expect(baseline.assets.length, 1);
      expect(
        baseline.domain['jobs']!.where((r) => r['deleted_at'] != null).length,
        1,
      );
      await db.customStatement(
        'UPDATE job_lines SET notes = ?, revision = revision+1',
        ['synthetic-marker'],
      );
      final edited = await NativeFixtureSnapshot.capture(db, workspace!);
      expect(edited.digest, isNot(baseline.digest));
      expect(edited.profileDigest, baseline.profileDigest);
      await db.customStatement('UPDATE job_lines SET part_id = ?', [
        'missing-part',
      ]);
      expect(
        (await NativeFixtureSnapshot.capture(db, workspace!)).referencesValid,
        false,
      );
    },
  );

  for (final mutation in [
    'empty',
    'malformed',
    'schema',
    'missing-profile',
    'wrong-profile',
    'missing-table',
    'missing-column',
  ]) {
    test(
      'preflight rejects $mutation database without modifying its bytes',
      () async {
        workspace = ValidationWorkspace.open(
          run: 'unit',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        );
        final file = File(
          p.join(workspace!.support.path, 'wired_parts.sqlite'),
        );
        final db = AppDatabase.forTesting(NativeDatabase(file));
        await seedValidationShop(db, workspace!);
        workspace!.markInitialized();
        await db.close();
        if (mutation == 'empty') {
          file.writeAsBytesSync([]);
        } else if (mutation == 'malformed') {
          file.writeAsStringSync('not a SQLite database');
        } else {
          final corrupt = raw.sqlite3.open(file.path);
          try {
            if (mutation == 'schema') {
              corrupt.execute('PRAGMA user_version = 1');
            } else if (mutation == 'missing-profile') {
              corrupt.execute('DELETE FROM device_profiles');
            } else if (mutation == 'missing-table') {
              corrupt.execute('DROP TABLE styles');
            } else if (mutation == 'missing-column') {
              corrupt.execute('ALTER TABLE job_lines DROP COLUMN notes');
            } else {
              corrupt.execute("UPDATE device_profiles SET id = 'other-device'");
            }
          } finally {
            corrupt.dispose();
          }
        }
        final before = file.readAsBytesSync();
        workspace!.close();
        expect(
          () => openExistingNativeFixture(
            run: 'unit',
            role: ValidationRole.sender,
            temporaryDirectory: temp,
          ),
          throwsA(isA<NativeTestFailure>()),
        );
        expect(file.readAsBytesSync(), before);
        // Reacquisition proves the rejected preflight released its owned lock.
        workspace = ValidationWorkspace.open(
          run: 'unit',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
          requireExisting: true,
        );
      },
    );
  }

  test(
    'preflight accepts the existing schema and exact device profile',
    () async {
      workspace = ValidationWorkspace.open(
        run: 'unit',
        role: ValidationRole.sender,
        temporaryDirectory: temp,
      );
      final file = File(p.join(workspace!.support.path, 'wired_parts.sqlite'));
      final db = AppDatabase.forTesting(NativeDatabase(file));
      await seedValidationShop(db, workspace!);
      workspace!.markInitialized();
      await db.close();
      final before = file.readAsBytesSync();
      workspace!.close();
      workspace = openExistingNativeFixture(
        run: 'unit',
        role: ValidationRole.sender,
        temporaryDirectory: temp,
      );
      expect(file.readAsBytesSync(), before);
      expect(workspace!.deviceId, 'lan-unit-sender');
    },
  );

  test(
    'public settings digest excludes PIN while private comparisons retain it',
    () async {
      workspace = ValidationWorkspace.open(
        run: 'unit',
        role: ValidationRole.sender,
        temporaryDirectory: temp,
      );
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedValidationShop(db, workspace!);
      final baseline = await NativeFixtureSnapshot.capture(db, workspace!);
      await db.settingsDao.setSetting(
        'editor_pin_hash',
        'synthetic-verifier-canary',
      );
      final changed = await NativeFixtureSnapshot.capture(db, workspace!);
      expect(changed.sharedSettingsDigest, baseline.sharedSettingsDigest);
      expect(
        changed.privateSharedSettingsDigest,
        isNot(baseline.privateSharedSettingsDigest),
      );
      expect(changed.privatePinDigest, isNot(baseline.privatePinDigest));
      expect(
        changed.completeSettingsDigest,
        isNot(baseline.completeSettingsDigest),
      );
    },
  );
}
