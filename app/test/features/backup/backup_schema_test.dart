import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import '../../../tool/backup_recovery_scenario.dart';
import '../../../tool/nearby_lan_validation.dart';
import 'backup_test_support.dart';

void main() {
  test('unknown SQLite schemas reject before live recovery, directory creation or file changes', () async {
    final temp = Directory.systemTemp.createTempSync('backup-schema-reject-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final sqlite = await sqliteBytesWithSetting(
      key: 'marker',
      value: 'preserve',
    );
    final live = Directory(p.join(temp.path, 'live'))..createSync();
    final file = File(p.join(live.path, kSqliteFileName))
      ..writeAsBytesSync(sqlite);
    final photos = Directory(p.join(live.path, 'part_photos'))..createSync();
    final photo = File(p.join(photos.path, 'preserve.png'))
      ..writeAsBytesSync([7, 8, 9]);
    final marker = File(p.join(live.path, kRestoreSwapMarkerName))
      ..writeAsStringSync('leave this marker alone');
    for (final version in [0, kAppSchemaVersion + 1]) {
      final unsupported = Uint8List.fromList(sqlite);
      ByteData.sublistView(unsupported).setUint32(60, version, Endian.big);
      final payload = BackupPayload(
        createdAt: DateTime.utc(2026, 10, 7),
        sourceDeviceId: 'synthetic',
        sqliteBytes: unsupported,
        photos: const {},
      );
      for (final destination in [
        live,
        Directory(p.join(temp.path, 'absent')),
      ]) {
        await expectLater(
          BackupStore(
            supportDir: destination,
            afterParkLive: () async => fail('Must not begin swap'),
          ).replaceWithPayload(
            payload: payload,
            reset: LocalDataReset(
              supportDir: destination,
              documentsDir: destination,
            ),
          ),
          throwsA(
            isA<BackupFormatException>().having(
              (e) => e.message,
              'message',
              'Unsupported backup database schema: $version',
            ),
          ),
        );
      }
      expect(file.readAsBytesSync(), sqlite);
      expect(photo.readAsBytesSync(), [7, 8, 9]);
      expect(marker.readAsStringSync(), 'leave this marker alone');
      expect(Directory(p.join(temp.path, 'absent')).existsSync(), isFalse);
      expect(
        Directory(p.join(live.path, kRestoreStagingName)).existsSync(),
        isFalse,
      );
    }
  });

  test('schema 1 migrates only in staging and preserves all fixture IDs and relationships', () async {
    final temp = Directory.systemTemp.createTempSync('backup-schema-one-');
    final scenario = RecoveryScenario.open(
      run: 'schema-one',
      action: RecoveryAction.exercise,
      temporaryDirectory: temp,
    );
    addTearDown(() {
      scenario.close();
      temp.deleteSync(recursive: true);
    });
    await scenario.seed();
    final source = scenario.openDatabase(scenario.source);
    await source.customStatement(
      "UPDATE brand_versions SET variance_name = '', is_main = 0",
    );
    final expected = await validationReceipt(source, scenario.source);
    await source.customStatement(
      'ALTER TABLE brand_versions DROP COLUMN variance_name',
    );
    await source.customStatement(
      'ALTER TABLE brand_versions DROP COLUMN is_main',
    );
    await source.customStatement('PRAGMA user_version = 1');
    await source.close();
    final original = File(p.join(scenario.source.support.path, kSqliteFileName))
        .readAsBytesSync();
    expect(backupSqliteSchemaVersion(original), 1);
    final payload =
        await BackupStore(
          supportDir: scenario.source.support,
          photosDir: scenario.source.photos,
        ).collect(
          sourceDeviceId: scenario.source.deviceId,
          createdAt: DateTime.utc(2026, 10, 7),
          sqliteBytes: original,
        );
    await BackupStore(
      supportDir: scenario.receiver.support,
      photosDir: scenario.receiver.photos,
    ).replaceWithPayload(
      payload: payload,
      reset: LocalDataReset(
        supportDir: scenario.receiver.support,
        documentsDir: scenario.receiver.documents,
        photosDir: scenario.receiver.photos,
      ),
    );
    expect(
      File(p.join(scenario.source.support.path, kSqliteFileName))
          .readAsBytesSync(),
      original,
    );
    final restored = scenario.openDatabase(scenario.receiver);
    try {
      final actual = await validationReceipt(restored, scenario.receiver);
      expect(actual['content'], expected['content']);
      expect(actual['photos'], expected['photos']);
      final version = await restored
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.data.values.single, kAppSchemaVersion);
    } finally {
      await restored.close();
    }
  });
}
