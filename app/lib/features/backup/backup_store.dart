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

  Future<void> replaceWithPayload({
    required BackupPayload payload,
    LocalDataReset reset = const LocalDataReset(),
  }) async {
    await reset.wipeFiles();
    await writePayload(payload);
  }
}
