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

void main() {
  test('replaceWithPayload restores sqlite and photos onto a wiped dir',
      () async {
    final src = Directory.systemTemp.createTempSync('wp-bak-src-');
    final dest = Directory.systemTemp.createTempSync('wp-bak-dst-');
    addTearDown(() {
      src.deleteSync(recursive: true);
      dest.deleteSync(recursive: true);
    });

    final sqlite = await sqliteBytesWithSetting(key: 'marker', value: 'src');
    File(p.join(src.path, kSqliteFileName)).writeAsBytesSync(sqlite);
    final srcPhotos = Directory(p.join(src.path, 'part_photos'))..createSync();
    File(p.join(srcPhotos.path, 'part-1-1.jpg')).writeAsBytesSync([7, 8]);

    final payload = await BackupStore(supportDir: src).collect(
      sourceDeviceId: 'dev-a',
      createdAt: DateTime.utc(2026, 9, 13, 18),
      sqliteBytes: sqlite,
    );
    expect(payload.photos['part-1-1.jpg'], [7, 8]);

    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([0]);
    File(p.join(dest.path, '$kSqliteFileName-wal')).writeAsBytesSync([2, 2]);
    File(p.join(dest.path, '$kSqliteFileName-shm')).writeAsBytesSync([3]);

    await BackupStore(supportDir: dest).replaceWithPayload(
      payload: payload,
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'src');
    expect(
      File(p.join(dest.path, 'part_photos', 'part-1-1.jpg')).readAsBytesSync(),
      [7, 8],
    );
    expect(
      File(p.join(dest.path, 'part_photos', 'old.jpg')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(dest.path, '$kSqliteFileName-wal')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(dest.path, '$kSqliteFileName-shm')).existsSync(),
      isFalse,
    );
  });

  test('replaceWithPayload refuses a backup missing shop tables', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-schema-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );

    final badDir = Directory.systemTemp.createTempSync('wp-bak-bad-schema-');
    addTearDown(() => badDir.deleteSync(recursive: true));
    final sqlite = File(p.join(badDir.path, kSqliteFileName));
    final db = AppDatabase.forTesting(NativeDatabase(sqlite));
    await db.settingsDao.setSetting('marker', 'bad');
    await db.customStatement('DROP TABLE jobs');
    await db.close();

    await expectLater(
      BackupStore(supportDir: dest).replaceWithPayload(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13),
          sourceDeviceId: 'dev-a',
          sqliteBytes: Uint8List.fromList(sqlite.readAsBytesSync()),
          photos: const {},
        ),
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
      ),
      throwsA(
        isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('missing shop tables'),
        ),
      ),
    );
    expect(await readSqliteSetting(dest, 'marker'), 'old');
  });

  test('codec plus store round-trip a file backup', () async {
    final dir = Directory.systemTemp.createTempSync('wp-bak-rt-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, kSqliteFileName)).writeAsBytesSync([4, 5, 6]);

    final store = BackupStore(supportDir: dir);
    final codec = BackupCodec(iterations: 1000);
    final payload = await store.collect(
      sourceDeviceId: 'dev-b',
      createdAt: DateTime.utc(2026, 1, 2, 3, 4),
      sqliteBytes: Uint8List.fromList([4, 5, 6]),
    );
    final file = await codec.encrypt(payload, 'pw');
    final restored = await codec.decrypt(file, 'pw');
    expect(restored.sqliteBytes, [4, 5, 6]);
    expect(restored.sourceDeviceId, 'dev-b');
  });

  test('damaged staged sqlite leaves the live shop', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-keep-');
    addTearDown(() => dest.deleteSync(recursive: true));
    final original = await sqliteBytesWithSetting(key: 'marker', value: 'live');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(original);

    await expectLater(
      BackupStore(supportDir: dest).replaceWithPayload(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13),
          sourceDeviceId: 'dev-a',
          sqliteBytes: Uint8List.fromList([9, 9, 9]),
          photos: const {},
        ),
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
      ),
      throwsA(isA<BackupFormatException>()),
    );
    expect(File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(), original);
    expect(
      Directory(p.join(dest.path, kRestoreStagingName)).existsSync(),
      isFalse,
    );
  });

  test('leftover WAL sidecars are deleted around the live swap', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-wal-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );
    File(p.join(dest.path, '$kSqliteFileName-wal')).writeAsBytesSync([4]);
    File(p.join(dest.path, '$kSqliteFileName-shm')).writeAsBytesSync([5]);
    File(p.join(dest.path, '$kSqliteFileName-journal')).writeAsBytesSync([6]);

    final sqlite = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    await BackupStore(supportDir: dest).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-a',
        sqliteBytes: sqlite,
        photos: const {},
      ),
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'new');
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      expect(
        File(p.join(dest.path, '$kSqliteFileName$suffix')).existsSync(),
        isFalse,
      );
    }
  });

  test('bak cleanup failure does not roll the restored shop back', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-cleanup-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([0]);

    final sqlite = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    await BackupStore(
      supportDir: dest,
      afterLiveSwap: () async {
        throw StateError('bak cleanup');
      },
    ).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-a',
        sqliteBytes: sqlite,
        photos: {'part-1-1.jpg': Uint8List.fromList([7, 8])},
      ),
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'new');
    expect(
      File(p.join(dest.path, 'part_photos', 'part-1-1.jpg')).readAsBytesSync(),
      [7, 8],
    );
    expect(
      File(p.join(dest.path, 'part_photos', 'old.jpg')).existsSync(),
      isFalse,
    );
  });

  test('documents leftover cleanup failure still leaves the restored shop',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-docs-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );

    final sqlite = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    await BackupStore(supportDir: dest).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-source',
        sqliteBytes: sqlite,
        photos: const {},
      ),
      reset: _ThrowingDocsReset(supportDir: dest, documentsDir: dest),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'new');
  });

  test('leftover bak is not rolled back over the current shop', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-stale-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([0]);

    final first = await sqliteBytesWithSetting(key: 'marker', value: 'first');
    await BackupStore(
      supportDir: dest,
      afterLiveSwap: () async {
        throw StateError('leave bak');
      },
    ).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-a',
        sqliteBytes: first,
        photos: {'part-1-1.jpg': Uint8List.fromList([7, 8])},
      ),
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'first');
    final leftoverBak = File(p.join(dest.path, kSqliteRestoreBakName));
    expect(leftoverBak.existsSync(), isTrue);
    leftoverBak.deleteSync();
    Directory(leftoverBak.path).createSync();
    File(p.join(leftoverBak.path, 'blocked')).writeAsStringSync('nope');
    final leftoverPhotos = Directory(p.join(dest.path, kPhotosRestoreBakName));
    if (leftoverPhotos.existsSync()) {
      leftoverPhotos.deleteSync(recursive: true);
    }
    leftoverPhotos.createSync();
    File(p.join(leftoverPhotos.path, 'blocked')).writeAsStringSync('nope');

    await expectLater(
      BackupStore(supportDir: dest).replaceWithPayload(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13),
          sourceDeviceId: 'dev-b',
          sqliteBytes: await sqliteBytesWithSetting(key: 'marker', value: 'second'),
          photos: const {},
        ),
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'first');
    expect(
      File(p.join(dest.path, 'part_photos', 'part-1-1.jpg')).readAsBytesSync(),
      [7, 8],
    );
  });

  test('sidecar delete failure during rollback still restores parked sqlite',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-side-');
    addTearDown(() => dest.deleteSync(recursive: true));
    final original = await sqliteBytesWithSetting(key: 'marker', value: 'live');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(original);

    await expectLater(
      BackupStore(supportDir: dest, failSidecarDelete: true).replaceWithPayload(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13),
          sourceDeviceId: 'dev-a',
          sqliteBytes: await sqliteBytesWithSetting(key: 'marker', value: 'new'),
          photos: const {},
        ),
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(File(p.join(dest.path, kSqliteFileName)).existsSync(), isTrue);
    expect(File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(), original);
    expect(
      File(p.join(dest.path, kSqliteRestoreBakName)).existsSync(),
      isFalse,
    );
  });

  test('staging delete failure after swap still reports the restored shop',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-stage-del-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );

    final sqlite = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    await BackupStore(supportDir: dest, failStagingDelete: true).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-a',
        sqliteBytes: sqlite,
        photos: const {},
      ),
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'new');
  });

  test('startup recovers live sqlite parked mid-swap', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-crash-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final original = await sqliteBytesWithSetting(key: 'marker', value: 'old');
    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    File(p.join(dest.path, kSqliteRestoreBakName)).writeAsBytesSync(original);
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    File(p.join(staging.path, kSqliteFileName)).writeAsBytesSync(restored);
    Directory(p.join(staging.path, 'part_photos')).createSync();
    File(p.join(staging.path, 'part_photos', 'part-1-1.jpg'))
        .writeAsBytesSync([7, 8]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync('in-progress');

    final docs = Directory(p.join(dest.path, 'docs'))..createSync();
    File(p.join(docs.path, kSqliteFileName)).writeAsStringSync('obsolete');

    final live = resolveSqliteFile(supportDir: dest, documentsDir: docs);
    expect(live.readAsBytesSync(), restored);
    expect(
      File(p.join(dest.path, 'part_photos', 'part-1-1.jpg')).readAsBytesSync(),
      [7, 8],
    );
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
    expect(Directory(p.join(dest.path, kRestoreStagingName)).existsSync(), isFalse);
    expect(File(p.join(docs.path, kSqliteFileName)).readAsStringSync(), 'obsolete');
  });

  test('startup rolls bak back when staging is gone mid-swap', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-crash-bak-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final original = await sqliteBytesWithSetting(key: 'marker', value: 'old');
    File(p.join(dest.path, kSqliteRestoreBakName)).writeAsBytesSync(original);
    Directory(p.join(dest.path, kPhotosRestoreBakName)).createSync();
    File(p.join(dest.path, kPhotosRestoreBakName, 'old.jpg'))
        .writeAsBytesSync([1]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync('in-progress');

    final live = resolveSqliteFile(supportDir: dest);
    expect(live.readAsBytesSync(), original);
    expect(
      File(p.join(dest.path, 'part_photos', 'old.jpg')).readAsBytesSync(),
      [1],
    );
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
  });

  test('committed sqlite swap does not revive bak photos', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-photos-bak-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(restored);
    Directory(p.join(dest.path, kPhotosRestoreBakName)).createSync();
    File(p.join(dest.path, kPhotosRestoreBakName, 'old.jpg'))
        .writeAsBytesSync([1]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync('in-progress');

    resolveSqliteFile(supportDir: dest);
    expect(await readSqliteSetting(dest, 'marker'), 'new');
    expect(
      Directory(p.join(dest.path, 'part_photos')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(dest.path, kPhotosRestoreBakName, 'old.jpg')).existsSync(),
      isTrue,
    );
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
  });

  test('photo restore onto a shop without photos keeps live photos if marker remains',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-keep-restored-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, kSqliteRestoreBakName)).writeAsBytesSync([1]);
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'restored.jpg')).writeAsBytesSync([9]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync(kRestoreSwapMarkerInProgress);

    resolveSqliteFile(supportDir: dest);
    expect(await readSqliteSetting(dest, 'marker'), 'new');
    expect(
      File(p.join(dest.path, 'part_photos', 'restored.jpg')).readAsBytesSync(),
      [9],
    );
    expect(
      Directory(p.join(dest.path, kPhotosRestoreBakName)).existsSync(),
      isFalse,
    );
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
  });

  test('empty-photo recover parks leftover photos when marker says no photos',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-empty-photos-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, kSqliteRestoreBakName)).writeAsBytesSync([1]);
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([1]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync(kRestoreSwapMarkerNoPhotos);

    resolveSqliteFile(supportDir: dest);
    expect(await readSqliteSetting(dest, 'marker'), 'new');
    expect(
      File(p.join(dest.path, 'part_photos', 'old.jpg')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(dest.path, kPhotosRestoreBakName, 'old.jpg')).readAsBytesSync(),
      [1],
    );
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
  });

  test('empty-photo recover parks live photos after promoting staged sqlite',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-empty-staged-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    File(p.join(dest.path, kSqliteRestoreBakName)).writeAsBytesSync([1]);
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([1]);
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    File(p.join(staging.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync('in-progress');

    resolveSqliteFile(supportDir: dest);
    expect(await readSqliteSetting(dest, 'marker'), 'new');
    expect(
      File(p.join(dest.path, 'part_photos', 'old.jpg')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(dest.path, kPhotosRestoreBakName, 'old.jpg')).readAsBytesSync(),
      [1],
    );
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
  });

  test('failed photo replace keeps staged photos and marker', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-photo-keep-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, kSqliteRestoreBakName)).writeAsBytesSync([1]);
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([1]);
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    Directory(p.join(staging.path, 'part_photos')).createSync();
    File(p.join(staging.path, 'part_photos', 'new.jpg')).writeAsBytesSync([9]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync('in-progress');

    recoverInterruptedRestore(
      supportDir: dest,
      beforeReplaceLivePhotos: () {
        throw StateError('photo replace');
      },
    );

    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isTrue);
    expect(
      File(p.join(staging.path, 'part_photos', 'new.jpg')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(dest.path, 'part_photos', 'old.jpg')).readAsBytesSync(),
      [1],
    );
    expect(
      File(p.join(dest.path, 'part_photos', 'new.jpg')).existsSync(),
      isFalse,
    );

    recoverInterruptedRestore(supportDir: dest);
    expect(
      File(p.join(dest.path, 'part_photos', 'new.jpg')).readAsBytesSync(),
      [9],
    );
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
    expect(
      File(p.join(staging.path, 'part_photos', 'new.jpg')).existsSync(),
      isFalse,
    );
  });

  test('retry restore does not delete unfinished staged photos', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-retry-photos-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, kSqliteRestoreBakName)).writeAsBytesSync([1]);
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([1]);
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    Directory(p.join(staging.path, 'part_photos')).createSync();
    File(p.join(staging.path, 'part_photos', 'new.jpg')).writeAsBytesSync([9]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync('in-progress');

    await expectLater(
      BackupStore(
        supportDir: dest,
        beforeReplaceLivePhotos: () {
          throw StateError('photo replace');
        },
      ).replaceWithPayload(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13),
          sourceDeviceId: 'dev-a',
          sqliteBytes: await sqliteBytesWithSetting(key: 'marker', value: 'retry'),
          photos: const {},
        ),
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
      ),
      throwsA(isA<BackupFormatException>()),
    );

    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isTrue);
    expect(
      File(p.join(staging.path, 'part_photos', 'new.jpg')).readAsBytesSync(),
      [9],
    );
    expect(await readSqliteSetting(dest, 'marker'), 'new');
  });

  test('leftover staging without a swap marker does not block restore', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-junk-stage-');
    addTearDown(() => dest.deleteSync(recursive: true));

    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'old'),
    );
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    Directory(p.join(staging.path, 'part_photos')).createSync();
    File(p.join(staging.path, 'part_photos', 'junk.jpg')).writeAsBytesSync([9]);

    await BackupStore(supportDir: dest).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-a',
        sqliteBytes: await sqliteBytesWithSetting(key: 'marker', value: 'new'),
        photos: const {},
      ),
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(await readSqliteSetting(dest, 'marker'), 'new');
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
    expect(
      File(p.join(staging.path, 'part_photos', 'junk.jpg')).existsSync(),
      isFalse,
    );
  });

  test('failed recover rename keeps staging and marker', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-keep-stage-');
    addTearDown(() {
      try {
        dest.statSync();
        Process.runSync('chmod', ['u+w', dest.path]);
      } catch (_) {}
      dest.deleteSync(recursive: true);
    });

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    File(p.join(staging.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync('in-progress');
    Process.runSync('chmod', ['a-w', dest.path]);

    expect(
      () => recoverInterruptedRestore(supportDir: dest),
      throwsA(isA<FileSystemException>()),
    );
    Process.runSync('chmod', ['u+w', dest.path]);
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isTrue);
    expect(
      File(p.join(staging.path, kSqliteFileName)).existsSync(),
      isTrue,
    );
    expect(File(p.join(dest.path, kSqliteFileName)).existsSync(), isFalse);
  });

  test('recover keeps marker if sqlite sidecar delete fails after promote',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-wal-keep-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    File(p.join(staging.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, '$kSqliteFileName-wal')).writeAsBytesSync([2, 2]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync(kRestoreSwapMarkerInProgress);

    recoverInterruptedRestore(
      supportDir: dest,
      beforeDeleteSqliteSidecars: () {
        throw StateError('sidecar delete');
      },
    );

    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isTrue);
    expect(File(p.join(dest.path, kSqliteFileName)).existsSync(), isTrue);
    expect(
      File(p.join(dest.path, '$kSqliteFileName-wal')).existsSync(),
      isTrue,
    );

    recoverInterruptedRestore(supportDir: dest);
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
    expect(
      File(p.join(dest.path, '$kSqliteFileName-wal')).readAsBytesSync(),
      [2, 2],
    );
    expect(File(p.join(dest.path, kSqliteFileName)).existsSync(), isTrue);
  });

  test('leftover marker does not delete WAL of an already-live shop', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-live-wal-');
    addTearDown(() => dest.deleteSync(recursive: true));

    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
      await sqliteBytesWithSetting(key: 'marker', value: 'live'),
    );
    File(p.join(dest.path, '$kSqliteFileName-wal')).writeAsBytesSync([9, 9]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync(kRestoreSwapMarkerInProgress);

    resolveSqliteFile(supportDir: dest);
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
    expect(
      File(p.join(dest.path, '$kSqliteFileName-wal')).readAsBytesSync(),
      [9, 9],
    );
  });

  test('recover strips leftover WAL only after promoting staged sqlite',
      () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-wal-strip-');
    addTearDown(() => dest.deleteSync(recursive: true));

    final restored = await sqliteBytesWithSetting(key: 'marker', value: 'new');
    final staging = Directory(p.join(dest.path, kRestoreStagingName))
      ..createSync();
    File(p.join(staging.path, kSqliteFileName)).writeAsBytesSync(restored);
    File(p.join(dest.path, '$kSqliteFileName-wal')).writeAsBytesSync([2, 2]);
    File(p.join(dest.path, kRestoreSwapMarkerName))
        .writeAsStringSync(kRestoreSwapMarkerInProgress);

    recoverInterruptedRestore(supportDir: dest);
    expect(File(p.join(dest.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
    expect(
      File(p.join(dest.path, '$kSqliteFileName-wal')).existsSync(),
      isFalse,
    );
    expect(await readSqliteSetting(dest, 'marker'), 'new');
  });

  test('writeBytesAtomically replaces an existing backup without a leftover tmp',
      () async {
    final dir = Directory.systemTemp.createTempSync('wp-bak-atomic-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dest = File(p.join(dir.path, 'shop.wpbackup'))
      ..writeAsBytesSync([1, 2, 3]);

    await writeBytesAtomically(dest, [9, 9, 9, 9]);
    expect(dest.readAsBytesSync(), [9, 9, 9, 9]);
    expect(File('${dest.path}.tmp').existsSync(), isFalse);
    expect(File('${dest.path}.old').existsSync(), isFalse);
  });

  test('atomic write restores parked backup if replace fails', () async {
    final dir = Directory.systemTemp.createTempSync('wp-bak-atomic-fail-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dest = File(p.join(dir.path, 'shop.wpbackup'))
      ..writeAsBytesSync([1, 2, 3]);

    await expectLater(
      writeBytesAtomically(
        dest,
        [9, 9, 9, 9],
        beforeReplace: () async {
          throw StateError('replace');
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(dest.readAsBytesSync(), [1, 2, 3]);
    expect(File('${dest.path}.tmp').existsSync(), isTrue);
    expect(File('${dest.path}.tmp').readAsBytesSync(), [9, 9, 9, 9]);
    expect(File('${dest.path}.old').existsSync(), isFalse);
  });

  test('atomic write recovers dest from tmp after park-before-rename crash',
      () async {
    final dir = Directory.systemTemp.createTempSync('wp-bak-atomic-tmp-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dest = File(p.join(dir.path, 'shop.wpbackup'));
    File('${dest.path}.old').writeAsBytesSync([1, 2, 3]);
    File('${dest.path}.tmp').writeAsBytesSync([9, 9, 9, 9]);

    await recoverParkedAtomicWrite(dest);
    expect(dest.readAsBytesSync(), [9, 9, 9, 9]);
    expect(File('${dest.path}.tmp').existsSync(), isFalse);
    expect(File('${dest.path}.old').readAsBytesSync(), [1, 2, 3]);
  });

  test('atomic write recovers dest from old when tmp is gone', () async {
    final dir = Directory.systemTemp.createTempSync('wp-bak-atomic-old-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dest = File(p.join(dir.path, 'shop.wpbackup'));
    File('${dest.path}.old').writeAsBytesSync([1, 2, 3]);

    await recoverParkedAtomicWrite(dest);
    expect(dest.readAsBytesSync(), [1, 2, 3]);
    expect(File('${dest.path}.old').existsSync(), isFalse);
  });

  test('next export recovers a parked backup then replaces it', () async {
    final dir = Directory.systemTemp.createTempSync('wp-bak-atomic-next-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dest = File(p.join(dir.path, 'shop.wpbackup'));
    File('${dest.path}.old').writeAsBytesSync([1, 2, 3]);

    await writeBytesAtomically(dest, [7, 7]);
    expect(dest.readAsBytesSync(), [7, 7]);
    expect(File('${dest.path}.tmp').existsSync(), isFalse);
    expect(File('${dest.path}.old').existsSync(), isFalse);
  });

  test('in-process park crash rolls bak back to the live shop', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-park-');
    addTearDown(() => dest.deleteSync(recursive: true));
    final original = await sqliteBytesWithSetting(key: 'marker', value: 'old');
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(original);

    await expectLater(
      BackupStore(
        supportDir: dest,
        afterParkLive: () async {
          throw StateError('crash after park');
        },
      ).replaceWithPayload(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13),
          sourceDeviceId: 'dev-a',
          sqliteBytes: await sqliteBytesWithSetting(key: 'marker', value: 'new'),
          photos: const {},
        ),
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
      ),
      throwsA(isA<StateError>()),
    );

    expect(File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(), original);
    final db = AppDatabase.forTesting(
      NativeDatabase(File(p.join(dest.path, kSqliteFileName))),
    );
    addTearDown(db.close);
    expect(await db.settingsDao.getSetting('marker'), 'old');
  });
}

class _ThrowingDocsReset extends LocalDataReset {
  const _ThrowingDocsReset({super.supportDir, super.documentsDir});

  @override
  Future<void> clearDocumentsLeftover() async {
    throw StateError('leftover cleanup');
  }
}
