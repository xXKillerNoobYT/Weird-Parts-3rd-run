import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import 'backup_test_support.dart';

AppDatabase _open(Directory dir) {
  return AppDatabase.forTesting(
    NativeDatabase(File(p.join(dir.path, kSqliteFileName))),
  );
}

class _ThrowingDocsReset extends LocalDataReset {
  const _ThrowingDocsReset({
    super.supportDir,
    super.documentsDir,
    super.photosDir,
  });

  @override
  Future<void> clearDocumentsLeftover() async {
    throw StateError('leftover cleanup');
  }
}

void main() {
  test('restore swap then reopen keeps dest device id after leftover cleanup fails',
      () async {
    final srcDir = Directory.systemTemp.createTempSync('wp-app-src-');
    final destDir = Directory.systemTemp.createTempSync('wp-app-dst-');
    addTearDown(() {
      srcDir.deleteSync(recursive: true);
      destDir.deleteSync(recursive: true);
    });

    final srcDb = _open(srcDir);
    final sourceId = await srcDb.settingsDao.ensureDeviceId();
    await srcDb.settingsDao.setSetting('marker', 'from-backup');
    await srcDb.close();

    final payload = await BackupStore(supportDir: srcDir).collect(
      sourceDeviceId: sourceId,
      createdAt: DateTime.utc(2026, 9, 13, 18),
      sqliteBytes: Uint8List.fromList(
        File(p.join(srcDir.path, kSqliteFileName)).readAsBytesSync(),
      ),
    );

    const destId = 'dest-device-keep';
    final destDb = _open(destDir);
    await destDb.settingsDao.keepLocalDeviceId(destId);
    await destDb.settingsDao.setSetting('marker', 'local-shop');
    await destDb.close();

    await BackupStore(supportDir: destDir).replaceWithPayload(
      payload: payload,
      reset: _ThrowingDocsReset(
        supportDir: destDir,
        documentsDir: Directory(p.join(destDir.path, 'docs'))..createSync(),
        photosDir: Directory(p.join(destDir.path, 'part_photos')),
      ),
    );

    final next = _open(destDir);
    addTearDown(next.close);
    await next.settingsDao.keepLocalDeviceId(destId);
    expect(await next.settingsDao.ensureDeviceId(), destId);
    expect(await next.settingsDao.getSetting('marker'), 'from-backup');
  });

  test('failed swap after close leaves the original sqlite, not an empty db',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-app-fail-');
    addTearDown(() => dest.deleteSync(recursive: true));

    const destId = 'dest-device-keep';
    final destDb = _open(dest);
    await destDb.settingsDao.keepLocalDeviceId(destId);
    await destDb.settingsDao.setSetting('marker', 'local-shop');
    await destDb.close();

    await expectLater(
      BackupStore(supportDir: dest, failSidecarDelete: true).replaceWithPayload(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13),
          sourceDeviceId: 'source',
          sqliteBytes: await sqliteBytesWithSetting(key: 'marker', value: 'new'),
          photos: const {},
        ),
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(File(p.join(dest.path, kSqliteFileName)).existsSync(), isTrue);
    final next = _open(dest);
    addTearDown(next.close);
    expect(await next.settingsDao.ensureDeviceId(), destId);
    expect(await next.settingsDao.getSetting('marker'), 'local-shop');
  });
}
