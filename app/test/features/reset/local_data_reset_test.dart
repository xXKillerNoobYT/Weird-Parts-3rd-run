import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

void main() {
  test('wipeFiles deletes sqlite sidecars and photos', () async {
    final dir = Directory.systemTemp.createTempSync('wp-wipe-');
    addTearDown(() => dir.deleteSync(recursive: true));

    final sqlite = File(p.join(dir.path, kSqliteFileName))
      ..writeAsStringSync('db');
    final wal = File(p.join(dir.path, '$kSqliteFileName-wal'))
      ..writeAsStringSync('wal');
    final photos = Directory(p.join(dir.path, 'part_photos'))
      ..createSync();
    File(p.join(photos.path, 'part-1.jpg')).writeAsStringSync('jpg');

    await LocalDataReset(supportDir: dir, documentsDir: dir).wipeFiles();

    expect(sqlite.existsSync(), isFalse);
    expect(wal.existsSync(), isFalse);
    expect(photos.existsSync(), isFalse);
  });

  test('wipeFiles deletes restore leftovers so recover cannot resurrect',
      () async {
    final dir = Directory.systemTemp.createTempSync('wp-wipe-restore-');
    addTearDown(() => dir.deleteSync(recursive: true));

    File(p.join(dir.path, kSqliteFileName)).writeAsStringSync('live');
    File(p.join(dir.path, kSqliteRestoreBakName)).writeAsStringSync('bak-db');
    File(p.join(dir.path, kRestoreSwapMarkerName)).writeAsStringSync('in-progress');
    Directory(p.join(dir.path, 'part_photos')).createSync();
    File(p.join(dir.path, 'part_photos', 'live.jpg')).writeAsStringSync('jpg');
    Directory(p.join(dir.path, kPhotosRestoreBakName)).createSync();
    File(p.join(dir.path, kPhotosRestoreBakName, 'bak.jpg'))
        .writeAsStringSync('bak');
    Directory(p.join(dir.path, kRestoreStagingName)).createSync();
    File(p.join(dir.path, kRestoreStagingName, kSqliteFileName))
        .writeAsStringSync('staged');
    Directory(p.join(dir.path, kRestoreStagingName, 'part_photos')).createSync();
    File(p.join(dir.path, kRestoreStagingName, 'part_photos', 'new.jpg'))
        .writeAsStringSync('new');
    Directory(p.join(dir.path, kRestoreStagingNextName)).createSync();

    await LocalDataReset(supportDir: dir, documentsDir: dir).wipeFiles();

    expect(File(p.join(dir.path, kSqliteFileName)).existsSync(), isFalse);
    expect(File(p.join(dir.path, kSqliteRestoreBakName)).existsSync(), isFalse);
    expect(File(p.join(dir.path, kRestoreSwapMarkerName)).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, 'part_photos')).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, kPhotosRestoreBakName)).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, kRestoreStagingName)).existsSync(), isFalse);
    expect(
      Directory(p.join(dir.path, kRestoreStagingNextName)).existsSync(),
      isFalse,
    );

    resolveSqliteFile(supportDir: dir);
    expect(File(p.join(dir.path, kSqliteFileName)).existsSync(), isFalse);
    expect(File(p.join(dir.path, kSqliteRestoreBakName)).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, kRestoreStagingName)).existsSync(), isFalse);
  });

  test('wipeFiles deletes Documents leftover so it cannot be copied back',
      () async {
    final tmp = Directory.systemTemp.createTempSync('wp-wipe-docs-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final support = Directory(p.join(tmp.path, 'support'))..createSync();
    final docs = Directory(p.join(tmp.path, 'docs'))..createSync();
    File(p.join(support.path, kSqliteFileName)).writeAsStringSync('support-db');
    File(p.join(docs.path, kSqliteFileName)).writeAsStringSync('docs-db');
    File(p.join(docs.path, '$kSqliteFileName-wal')).writeAsStringSync('wal');

    await LocalDataReset(supportDir: support, documentsDir: docs).wipeFiles();

    expect(File(p.join(support.path, kSqliteFileName)).existsSync(), isFalse);
    expect(File(p.join(docs.path, kSqliteFileName)).existsSync(), isFalse);
    expect(
      File(p.join(docs.path, '$kSqliteFileName-wal')).existsSync(),
      isFalse,
    );
  });
}
