import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

void main() {
  test('replaceWithPayload restores sqlite and photos onto a wiped dir',
      () async {
    final src = Directory.systemTemp.createTempSync('wp-bak-src-');
    final dest = Directory.systemTemp.createTempSync('wp-bak-dst-');
    addTearDown(() {
      src.deleteSync(recursive: true);
      dest.deleteSync(recursive: true);
    });

    File(p.join(src.path, kSqliteFileName)).writeAsBytesSync([9, 9, 9]);
    final srcPhotos = Directory(p.join(src.path, 'part_photos'))..createSync();
    File(p.join(srcPhotos.path, 'part-1-1.jpg')).writeAsBytesSync([7, 8]);

    final payload = await BackupStore(supportDir: src).collect(
      sourceDeviceId: 'dev-a',
      createdAt: DateTime.utc(2026, 9, 13, 18),
      sqliteBytes: File(p.join(src.path, kSqliteFileName)).readAsBytesSync(),
    );
    expect(payload.photos['part-1-1.jpg'], [7, 8]);

    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync([1]);
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([0]);
    File(p.join(dest.path, '$kSqliteFileName-wal')).writeAsBytesSync([2, 2]);
    File(p.join(dest.path, '$kSqliteFileName-shm')).writeAsBytesSync([3]);

    await BackupStore(supportDir: dest).replaceWithPayload(
      payload: payload,
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(
      File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(),
      [9, 9, 9],
    );
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

  test('failed staging write leaves the live shop', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-keep-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync([1, 2, 3]);

    final store = BackupStore(supportDir: dest);
    final payload = BackupPayload(
      createdAt: DateTime.utc(2026, 9, 13),
      sourceDeviceId: 'dev-a',
      sqliteBytes: Uint8List.fromList([9, 9, 9]),
      photos: const {},
    );
    // Staging is a subfolder of dest; a missing parent after delete is the
    // failure case. Replace still succeeds on a normal dir.
    await store.replaceWithPayload(
      payload: payload,
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );
    expect(File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(), [9, 9, 9]);
    expect(
      Directory(p.join(dest.path, 'restore_staging')).existsSync(),
      isFalse,
    );
  });

  test('leftover WAL sidecars are deleted around the live swap', () async {
    final dest = Directory.systemTemp.createTempSync('wp-bak-wal-');
    addTearDown(() => dest.deleteSync(recursive: true));
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync([1, 2, 3]);
    File(p.join(dest.path, '$kSqliteFileName-wal')).writeAsBytesSync([4]);
    File(p.join(dest.path, '$kSqliteFileName-shm')).writeAsBytesSync([5]);
    File(p.join(dest.path, '$kSqliteFileName-journal')).writeAsBytesSync([6]);

    await BackupStore(supportDir: dest).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-a',
        sqliteBytes: Uint8List.fromList([9, 9, 9]),
        photos: const {},
      ),
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(), [9, 9, 9]);
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
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync([1, 2, 3]);
    Directory(p.join(dest.path, 'part_photos')).createSync();
    File(p.join(dest.path, 'part_photos', 'old.jpg')).writeAsBytesSync([0]);

    await BackupStore(
      supportDir: dest,
      afterLiveSwap: () async {
        throw StateError('bak cleanup');
      },
    ).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-a',
        sqliteBytes: Uint8List.fromList([9, 9, 9]),
        photos: {'part-1-1.jpg': Uint8List.fromList([7, 8])},
      ),
      reset: LocalDataReset(supportDir: dest, documentsDir: dest),
    );

    expect(File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(), [9, 9, 9]);
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
    File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync([1]);

    await BackupStore(supportDir: dest).replaceWithPayload(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13),
        sourceDeviceId: 'dev-source',
        sqliteBytes: Uint8List.fromList([9, 9, 9]),
        photos: const {},
      ),
      reset: _ThrowingDocsReset(supportDir: dest, documentsDir: dest),
    );

    expect(File(p.join(dest.path, kSqliteFileName)).readAsBytesSync(), [9, 9, 9]);
  });
}

class _ThrowingDocsReset extends LocalDataReset {
  const _ThrowingDocsReset({super.supportDir, super.documentsDir, super.photosDir});

  @override
  Future<void> clearDocumentsLeftover() async {
    throw StateError('leftover cleanup');
  }
}
