import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

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
  testWidgets('restore keeps this device id after leftover cleanup fails',
      (tester) async {
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
    final fileBytes = await BackupCodec(iterations: 1000).encrypt(payload, 'pw');

    const destId = 'dest-device-keep';
    final destDb = _open(destDir);
    await destDb.settingsDao.keepLocalDeviceId(destId);
    await destDb.settingsDao.setSetting('marker', 'local-shop');

    await tester.pumpWidget(
      WiredPartsApp(
        db: destDb,
        pin: PinService(destDb.settingsDao),
        deviceId: destId,
        reopenDatabase: () => _open(destDir),
        reset: _ThrowingDocsReset(
          supportDir: destDir,
          documentsDir: Directory(p.join(destDir.path, 'docs'))..createSync(),
          photosDir: Directory(p.join(destDir.path, 'part_photos')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byType(HomeShell));
    await AppScope.of(ctx).restoreFromBackup(fileBytes, 'pw');
    await tester.pumpAndSettle();

    final scope = AppScope.of(tester.element(find.byType(HomeShell)));
    expect(scope.deviceId, destId);
    expect(await scope.db.settingsDao.ensureDeviceId(), destId);
    expect(await scope.db.settingsDao.getSetting('marker'), 'from-backup');
    await scope.db.close();
  });

  testWidgets('wrong password leaves the live shop and dest device id',
      (tester) async {
    final destDir = Directory.systemTemp.createTempSync('wp-app-wrong-');
    addTearDown(() => destDir.deleteSync(recursive: true));

    const destId = 'dest-device-keep';
    final destDb = _open(destDir);
    await destDb.settingsDao.keepLocalDeviceId(destId);
    await destDb.settingsDao.setSetting('marker', 'local-shop');

    final bogus = await BackupCodec(iterations: 1000).encrypt(
      BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'source',
        sqliteBytes: Uint8List.fromList([1, 2, 3]),
        photos: const {},
      ),
      'pw',
    );

    await tester.pumpWidget(
      WiredPartsApp(
        db: destDb,
        pin: PinService(destDb.settingsDao),
        deviceId: destId,
        reopenDatabase: () => _open(destDir),
        reset: LocalDataReset(supportDir: destDir, documentsDir: destDir),
      ),
    );
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byType(HomeShell));
    await expectLater(
      AppScope.of(ctx).restoreFromBackup(bogus, 'wrong'),
      throwsA(isA<BackupFormatException>()),
    );
    await tester.pumpAndSettle();

    final scope = AppScope.of(tester.element(find.byType(HomeShell)));
    expect(scope.deviceId, destId);
    expect(await scope.db.settingsDao.getSetting('marker'), 'local-shop');
    await scope.db.close();
  });

  testWidgets('failed restore after close reopens a live db with dest id',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('wp-app-fail-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final destDir = Directory(p.join(tmp.path, 'dest'))..createSync();
    final badSupport = File(p.join(tmp.path, 'support-is-file'))
      ..writeAsStringSync('x');

    const destId = 'dest-device-keep';
    final destDb = _open(destDir);
    await destDb.settingsDao.keepLocalDeviceId(destId);
    await destDb.settingsDao.setSetting('marker', 'local-shop');

    final fileBytes = await BackupCodec(iterations: 1000).encrypt(
      BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'source',
        sqliteBytes: Uint8List.fromList([9, 9, 9]),
        photos: const {},
      ),
      'pw',
    );

    await tester.pumpWidget(
      WiredPartsApp(
        db: destDb,
        pin: PinService(destDb.settingsDao),
        deviceId: destId,
        reopenDatabase: () => _open(destDir),
        reset: LocalDataReset(
          supportDir: Directory(badSupport.path),
          documentsDir: destDir,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byType(HomeShell));
    await expectLater(
      AppScope.of(ctx).restoreFromBackup(fileBytes, 'pw'),
      throwsA(isA<FileSystemException>()),
    );
    await tester.pumpAndSettle();

    final scope = AppScope.of(tester.element(find.byType(HomeShell)));
    expect(scope.deviceId, destId);
    expect(await scope.db.settingsDao.getSetting('marker'), 'local-shop');
    await scope.db.close();
  });
}
