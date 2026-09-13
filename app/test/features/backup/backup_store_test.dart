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
}
