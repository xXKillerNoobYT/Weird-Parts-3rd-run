import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/sqlite_file.dart';
import '../reset/local_data_reset.dart';
import 'backup_codec.dart';

const kLastBackupAtKey = 'last_backup_at';
const kLastBackupSourceKey = 'last_backup_source_device';

class BackupStore {
  const BackupStore({this.supportDir, this.photosDir});

  final Directory? supportDir;
  final Directory? photosDir;

  Future<Directory> _support() async =>
      supportDir ?? await getApplicationSupportDirectory();

  Future<Directory> _photos() async {
    if (photosDir != null) return photosDir!;
    final dir = await _support();
    return Directory(p.join(dir.path, 'part_photos'));
  }

  Future<File> sqliteFile() async {
    final dir = await _support();
    return resolveSqliteFile(supportDir: dir);
  }

  Future<BackupPayload> collect({
    required String sourceDeviceId,
    required DateTime createdAt,
    required Uint8List sqliteBytes,
  }) async {
    final photos = <String, Uint8List>{};
    final dir = await _photos();
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        photos[name] = await entity.readAsBytes();
      }
    }
    return BackupPayload(
      createdAt: createdAt.toUtc(),
      sourceDeviceId: sourceDeviceId,
      sqliteBytes: sqliteBytes,
      photos: photos,
    );
  }

  Future<void> writePayload(BackupPayload payload) async {
    final dir = await _support();
    await dir.create(recursive: true);
    final sqlite = File(p.join(dir.path, kSqliteFileName));
    await sqlite.writeAsBytes(payload.sqliteBytes, flush: true);
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final side = File('${sqlite.path}$suffix');
      if (await side.exists()) await side.delete();
    }
    final photos = await _photos();
    if (await photos.exists()) {
      await photos.delete(recursive: true);
    }
    if (payload.photos.isNotEmpty) {
      await photos.create(recursive: true);
      for (final entry in payload.photos.entries) {
        await File(p.join(photos.path, entry.key))
            .writeAsBytes(entry.value, flush: true);
      }
    }
  }

  /// Write the backup to a staging folder, then swap into place so a failed
  /// write cannot leave the live shop wiped.
  Future<void> replaceWithPayload({
    required BackupPayload payload,
    LocalDataReset reset = const LocalDataReset(),
  }) async {
    final live = await _support();
    await live.create(recursive: true);
    final staging = Directory(p.join(live.path, 'restore_staging'));
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    try {
      await BackupStore(
        supportDir: staging,
        photosDir: Directory(p.join(staging.path, 'part_photos')),
      ).writePayload(payload);
      await _swapStagingIntoLive(live: live, staging: staging);
      await reset.clearDocumentsLeftover();
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<void> _swapStagingIntoLive({
    required Directory live,
    required Directory staging,
  }) async {
    final liveSqlite = File(p.join(live.path, kSqliteFileName));
    final stagedSqlite = File(p.join(staging.path, kSqliteFileName));
    final livePhotos = Directory(p.join(live.path, 'part_photos'));
    final stagedPhotos = Directory(p.join(staging.path, 'part_photos'));
    final bakSqlite = File(p.join(live.path, '$kSqliteFileName.restore-bak'));
    final bakPhotos = Directory(p.join(live.path, 'part_photos.restore-bak'));

    Future<void> rollback() async {
      if (await bakSqlite.exists()) {
        if (await liveSqlite.exists()) await liveSqlite.delete();
        await bakSqlite.rename(liveSqlite.path);
      }
      if (await bakPhotos.exists()) {
        if (await livePhotos.exists()) {
          await livePhotos.delete(recursive: true);
        }
        await bakPhotos.rename(livePhotos.path);
      }
    }

    try {
      if (await bakSqlite.exists()) await bakSqlite.delete();
      if (await bakPhotos.exists()) await bakPhotos.delete(recursive: true);
      if (await liveSqlite.exists()) await liveSqlite.rename(bakSqlite.path);
      if (await livePhotos.exists()) await livePhotos.rename(bakPhotos.path);
      await stagedSqlite.rename(liveSqlite.path);
      if (await stagedPhotos.exists()) {
        await stagedPhotos.rename(livePhotos.path);
      }
      if (await bakSqlite.exists()) await bakSqlite.delete();
      if (await bakPhotos.exists()) await bakPhotos.delete(recursive: true);
    } catch (_) {
      await rollback();
      rethrow;
    }
  }
}
