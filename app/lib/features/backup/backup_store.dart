import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/app_database.dart';
import '../../data/sqlite_file.dart';
import '../reset/local_data_reset.dart';
import 'backup_codec.dart';

const kLastBackupAtKey = 'last_backup_at';
const kLastBackupSourceKey = 'last_backup_source_device';

const _sqliteMagic = [
  0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
  0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
];

/// Write [bytes] to a sibling temp file, then replace [dest] by parking the
/// previous file. Never delete the old copy until the new file is at [dest],
/// and never delete the temp copy on failure.
Future<void> writeBytesAtomically(
  File dest,
  List<int> bytes, {
  Future<void> Function()? beforeReplace,
}) async {
  final tmp = File('${dest.path}.tmp');
  final bak = File('${dest.path}.old');
  await tmp.writeAsBytes(bytes, flush: true);
  var parked = false;
  try {
    if (await dest.exists()) {
      if (await bak.exists()) {
        await bak.delete();
      }
      await dest.rename(bak.path);
      parked = true;
    }
    await beforeReplace?.call();
    await tmp.rename(dest.path);
    if (parked) {
      try {
        if (await bak.exists()) await bak.delete();
      } catch (_) {}
    }
  } catch (e) {
    if (parked && await bak.exists() && !await dest.exists()) {
      try {
        await bak.rename(dest.path);
      } catch (_) {}
    }
    rethrow;
  }
}

class BackupStore {
  const BackupStore({
    this.supportDir,
    this.photosDir,
    this.afterLiveSwap,
    this.afterParkLive,
    this.beforeReplaceLivePhotos,
    this.failSidecarDelete = false,
    this.failStagingDelete = false,
  });

  final Directory? supportDir;
  final Directory? photosDir;

  /// Test hook: runs after the restored files are live, before bak cleanup.
  final Future<void> Function()? afterLiveSwap;

  /// Test hook: runs after live files are parked to bak, before staged rename.
  final Future<void> Function()? afterParkLive;

  /// Test hook: passed to [recoverInterruptedRestore] before replacing live photos.
  final void Function()? beforeReplaceLivePhotos;

  /// Test hook: pretend WAL/SHM delete failed.
  final bool failSidecarDelete;

  /// Test hook: pretend staging-dir delete failed after the swap.
  final bool failStagingDelete;

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
    await _deleteSqliteSidecars(sqlite);
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
  ///
  /// After the live swap commits, leftover Documents sqlite, `.restore-bak`
  /// copies, and the staging directory are best-effort. Those failures must
  /// not roll the restored shop back or report Restore failed.
  Future<void> replaceWithPayload({
    required BackupPayload payload,
    LocalDataReset reset = const LocalDataReset(),
  }) async {
    final live = await _support();
    await live.create(recursive: true);
    recoverInterruptedRestore(
      supportDir: live,
      beforeReplaceLivePhotos: beforeReplaceLivePhotos,
    );

    final leftoverStaging = Directory(p.join(live.path, kRestoreStagingName));
    final leftoverPhotos = Directory(p.join(leftoverStaging.path, 'part_photos'));
    final leftoverSqlite = File(p.join(leftoverStaging.path, kSqliteFileName));
    final liveSqlite = File(p.join(live.path, kSqliteFileName));
    // Sqlite is already live; leftover photos still match it. Do not delete
    // them to make room for a new restore — a later failure would leave that
    // shop without images.
    final keepUnfinishedPhotos = leftoverPhotos.existsSync() &&
        !leftoverSqlite.existsSync() &&
        liveSqlite.existsSync();
    if (keepUnfinishedPhotos) {
      throw const BackupFormatException(
        'Previous restore photos are still applying. Restart the app and try again.',
      );
    }

    final staging = leftoverStaging;
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    try {
      await BackupStore(
        supportDir: staging,
        photosDir: Directory(p.join(staging.path, 'part_photos')),
      ).writePayload(payload);
      await _validateStagedSqlite(File(p.join(staging.path, kSqliteFileName)));
      await _swapStagingIntoLive(live: live, staging: staging);
    } finally {
      try {
        if (failStagingDelete) {
          throw const FileSystemException('Failed to delete restore staging');
        }
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } catch (_) {
        // Swap may already have committed. Leftover staging is disk junk.
      }
    }
    try {
      await reset.clearDocumentsLeftover();
    } catch (_) {
      // Restored sqlite is already in Application Support, so a leftover
      // Documents copy cannot be copied over it.
    }
  }

  Future<void> _validateStagedSqlite(File sqlite) async {
    if (!await sqlite.exists()) {
      throw const BackupFormatException('Backup database is missing');
    }
    final header = await sqlite.openRead(0, 16).fold<List<int>>(
      <int>[],
      (out, chunk) {
        out.addAll(chunk);
        return out;
      },
    );
    if (header.length < 16) {
      throw const BackupFormatException('Backup database is damaged');
    }
    for (var i = 0; i < 16; i++) {
      if (header[i] != _sqliteMagic[i]) {
        throw const BackupFormatException('Backup database is damaged');
      }
    }

    final db = AppDatabase.forTesting(NativeDatabase(sqlite));
    try {
      final rows = await db.customSelect('PRAGMA integrity_check').get();
      final ok = rows.isNotEmpty && '${rows.first.data.values.first}' == 'ok';
      if (!ok) {
        throw const BackupFormatException('Backup database is damaged');
      }
      final tables = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final names = {
        for (final row in tables) '${row.data['name']}',
      };
      const requiredTables = [
        'device_profiles',
        'app_settings',
        'categories',
        'styles',
        'types',
        'devices',
        'brands',
        'suppliers',
        'parts',
        'part_devices',
        'brand_versions',
        'supplier_listings',
        'jobs',
        'job_lines',
        'order_splits',
      ];
      for (final name in requiredTables) {
        if (!names.contains(name)) {
          throw const BackupFormatException(
            'Backup database is missing shop tables',
          );
        }
      }
    } on BackupFormatException {
      rethrow;
    } catch (e) {
      throw BackupFormatException('Backup database cannot be opened: $e');
    } finally {
      await db.close();
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
    final bakSqlite = File(p.join(live.path, kSqliteRestoreBakName));
    final bakPhotos = Directory(p.join(live.path, kPhotosRestoreBakName));
    final marker = File(p.join(live.path, kRestoreSwapMarkerName));

    var parkedSqlite = false;
    var parkedPhotos = false;
    var committed = false;

    Future<void> rollback() async {
      // Only restore bak files this swap parked. Leftover `.restore-bak`
      // from a previous committed swap is not this shop's backup.
      if (parkedSqlite && await bakSqlite.exists()) {
        if (await liveSqlite.exists()) {
          try {
            await liveSqlite.delete();
          } catch (_) {}
        }
        try {
          await _deleteSqliteSidecars(liveSqlite);
        } catch (_) {}
        await bakSqlite.rename(liveSqlite.path);
      }
      if (parkedPhotos && await bakPhotos.exists()) {
        if (await livePhotos.exists()) {
          try {
            await livePhotos.delete(recursive: true);
          } catch (_) {}
        }
        await bakPhotos.rename(livePhotos.path);
      }
    }

    await marker.writeAsString('in-progress', flush: true);
    try {
      if (await bakSqlite.exists()) await bakSqlite.delete();
      if (await bakPhotos.exists()) await bakPhotos.delete(recursive: true);
      if (await liveSqlite.exists()) {
        await liveSqlite.rename(bakSqlite.path);
        parkedSqlite = true;
      }
      // Rename does not move WAL/SHM; leftover sidecars would attach to the
      // restored file and can look corrupt when Drift reopens in WAL mode.
      await _deleteSqliteSidecars(liveSqlite);
      if (await livePhotos.exists()) {
        await livePhotos.rename(bakPhotos.path);
        parkedPhotos = true;
      }
      await afterParkLive?.call();
      await stagedSqlite.rename(liveSqlite.path);
      await _deleteSqliteSidecars(liveSqlite);
      if (await stagedPhotos.exists()) {
        await stagedPhotos.rename(livePhotos.path);
      }
      committed = true;
      try {
        if (await marker.exists()) await marker.delete();
      } catch (_) {}
    } catch (e) {
      if (!committed) {
        await rollback();
        try {
          if (await marker.exists()) await marker.delete();
        } catch (_) {}
      }
      rethrow;
    }

    try {
      await afterLiveSwap?.call();
      if (await bakSqlite.exists()) await bakSqlite.delete();
      if (await bakPhotos.exists()) await bakPhotos.delete(recursive: true);
    } catch (_) {
      // Swap already committed. Leftover bak files are leftover disk.
    }
  }

  Future<void> _deleteSqliteSidecars(File sqlite) async {
    if (failSidecarDelete) {
      throw const FileSystemException('Failed to delete sqlite sidecars');
    }
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final side = File('${sqlite.path}$suffix');
      if (await side.exists()) await side.delete();
    }
  }
}
