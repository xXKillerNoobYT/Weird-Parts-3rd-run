import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/app_database.dart';
import '../../data/sqlite_file.dart';
import '../reset/local_data_reset.dart';
import 'backup_codec.dart';

const kLastBackupAtKey = 'last_backup_at';
const kLastBackupSourceKey = 'last_backup_source_device';
const kBackupAlreadyInProgressMessage = 'Backup already in progress';

const _sqliteMagic = [
  0x53,
  0x51,
  0x4c,
  0x69,
  0x74,
  0x65,
  0x20,
  0x66,
  0x6f,
  0x72,
  0x6d,
  0x61,
  0x74,
  0x20,
  0x33,
  0x00,
];

/// App-level export/restore lock. Page `_busy` dies with [BackupPage]; this
/// does not, so a second Backup route cannot race the same write.
class BackupIo {
  BackupIo._();

  static var _busy = false;

  static bool get isBusy => _busy;

  static bool tryStart() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  static void end() {
    _busy = false;
  }

  /// Wait until a backup/restore is not running, then hold the lock for
  /// [body]. Photo mutations use this so export's sqlite-then-photos snapshot
  /// cannot race a replace.
  static Future<T> waitAndRun<T>(Future<T> Function() body) async {
    while (!tryStart()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      return await body();
    } finally {
      end();
    }
  }
}

/// Write [bytes] in app-controlled staging, then replace [dest]. Never write
/// `${dest}.tmp` / `${dest}.old`: the macOS sandbox only allows the user-picked
/// file. Never delete [dest] until the new file is actually there. A failed
/// or truncated place restores the parked backup even when [dest] still exists.
///
/// If a previous attempt died mid-replace, [recoverParkedAtomicWrite] puts a
/// complete file back at [dest] first.
Future<void> writeBytesAtomically(
  File dest,
  List<int> bytes, {
  Directory? stagingDir,
  Future<void> Function()? beforeReplace,
  Future<void> Function()? afterParkCopy,
  Future<void> Function()? afterPlace,
}) async {
  await recoverParkedAtomicWrite(dest, stagingDir: stagingDir);
  final staging = await _backupWriteStaging(stagingDir);
  final tmp = _backupWriteTmp(staging, dest);
  final bak = _backupWriteBak(staging, dest);
  final bakPart = _backupWriteBakPartial(staging, dest);
  await tmp.writeAsBytes(bytes, flush: true);
  var parked = false;
  try {
    if (await dest.exists()) {
      if (await bak.exists()) {
        await bak.delete();
      }
      if (await bakPart.exists()) {
        await bakPart.delete();
      }
      final destLen = await dest.length();
      await dest.copy(bakPart.path);
      await afterParkCopy?.call();
      if (!await bakPart.exists() || await bakPart.length() != destLen) {
        try {
          if (await bakPart.exists()) await bakPart.delete();
        } catch (_) {}
        throw const FileSystemException('Failed to park the previous backup');
      }
      await bakPart.rename(bak.path);
      parked = true;
    }
    await beforeReplace?.call();
    await _placeBackupWrite(tmp, dest);
    await afterPlace?.call();
    if (!await _destHasLength(dest, bytes.length)) {
      throw const FileSystemException(
        'Backup replace did not produce a complete file',
      );
    }
    if (parked) {
      try {
        if (await bak.exists()) await bak.delete();
      } catch (_) {}
    }
  } catch (e) {
    if (parked && await bak.exists()) {
      try {
        await bak.copy(dest.path);
      } catch (_) {}
    }
    rethrow;
  }
}

/// If a crash left [dest] missing or truncated, finish from staging `.tmp` or
/// restore the previous file from `.old`. Also recovers leftover sibling
/// `${dest}.tmp` / `${dest}.old` from older builds.
Future<void> recoverParkedAtomicWrite(
  File dest, {
  Directory? stagingDir,
}) async {
  final staging = await _backupWriteStaging(stagingDir);
  final tmp = _backupWriteTmp(staging, dest);
  final bak = _backupWriteBak(staging, dest);
  final bakPart = _backupWriteBakPartial(staging, dest);
  if (await bakPart.exists()) {
    try {
      await bakPart.delete();
    } catch (_) {}
  }
  final tmpExists = await tmp.exists();
  final bakExists = await bak.exists();
  final destExists = await dest.exists();

  if (tmpExists) {
    final tmpLen = await tmp.length();
    if (destExists && await dest.length() == tmpLen) {
      try {
        await tmp.delete();
      } catch (_) {}
      try {
        if (bakExists) await bak.delete();
      } catch (_) {}
      return;
    }
    if (bakExists) {
      await bak.copy(dest.path);
      return;
    }
    await _placeBackupWrite(tmp, dest);
    return;
  }

  if (!destExists && bakExists) {
    await bak.copy(dest.path);
    try {
      await bak.delete();
    } catch (_) {}
    return;
  }

  if (destExists) {
    if (bakExists) {
      try {
        await bak.delete();
      } catch (_) {}
    }
    return;
  }

  final legacyTmp = File('${dest.path}.tmp');
  final legacyBak = File('${dest.path}.old');
  if (await legacyTmp.exists()) {
    await legacyTmp.rename(dest.path);
    return;
  }
  if (await legacyBak.exists()) {
    await legacyBak.rename(dest.path);
  }
}

String backupWriteKey(String destPath) =>
    sha256.convert(utf8.encode(destPath)).toString().substring(0, 24);

bool walCheckpointIsBusy(Map<String, Object?> row) {
  final busy = row['busy'] ?? (row.isEmpty ? 1 : row.values.first);
  if (busy is int) return busy != 0;
  if (busy is BigInt) return busy != BigInt.zero;
  return '$busy' != '0';
}

/// Flush WAL into the main sqlite file before export reads it. A nonzero
/// `busy` result is not an exception; retry, then fail so the backup cannot
/// omit recent commits.
Future<void> checkpointWalForExport(AppDatabase db) async {
  for (var attempt = 0; attempt < 8; attempt++) {
    final rows = await db.customSelect('PRAGMA wal_checkpoint(FULL)').get();
    if (rows.isEmpty || !walCheckpointIsBusy(rows.first.data)) return;
    await Future<void>.delayed(Duration(milliseconds: 25 * (attempt + 1)));
  }
  throw const BackupFormatException(
    'Database is busy; could not flush WAL for export',
  );
}

Future<Directory> _backupWriteStaging(Directory? stagingDir) async {
  if (stagingDir != null) {
    await stagingDir.create(recursive: true);
    return stagingDir;
  }
  try {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  } catch (_) {
    final dir = Directory(
      p.join(Directory.systemTemp.path, 'wired_parts_backup_write'),
    );
    await dir.create(recursive: true);
    return dir;
  }
}

File _backupWriteTmp(Directory staging, File dest) =>
    File(p.join(staging.path, 'backup_write_${backupWriteKey(dest.path)}.tmp'));

File _backupWriteBak(Directory staging, File dest) =>
    File(p.join(staging.path, 'backup_write_${backupWriteKey(dest.path)}.old'));

File _backupWriteBakPartial(Directory staging, File dest) => File(
  p.join(staging.path, 'backup_write_${backupWriteKey(dest.path)}.old.part'),
);

Future<void> _placeBackupWrite(File tmp, File dest) async {
  try {
    await tmp.rename(dest.path);
  } on FileSystemException {
    await tmp.copy(dest.path);
    if (!await _destHasLength(dest, await tmp.length())) {
      throw const FileSystemException(
        'Backup replace did not produce a complete file',
      );
    }
    try {
      await tmp.delete();
    } catch (_) {}
  }
}

Future<bool> _destHasLength(File dest, int length) async {
  if (!await dest.exists()) return false;
  return await dest.length() == length;
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

  /// Live sqlite path for export. Does not recover: recover is a closed-DB
  /// startup path, and the shop connection is already open.
  Future<File> sqliteFile() async {
    final dir = await _support();
    return File(p.join(dir.path, kSqliteFileName));
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
    final leftoverPhotos = Directory(
      p.join(leftoverStaging.path, 'part_photos'),
    );
    final leftoverSqlite = File(p.join(leftoverStaging.path, kSqliteFileName));
    final liveSqlite = File(p.join(live.path, kSqliteFileName));
    final swapMarker = File(p.join(live.path, kRestoreSwapMarkerName));
    // Only a live marker means photos still belong to an in-progress restore.
    // Rollback already deletes the marker; leftover staging after that is junk
    // and must not block a later Restore.
    final keepUnfinishedPhotos =
        swapMarker.existsSync() &&
        leftoverPhotos.existsSync() &&
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
    final header = await sqlite.openRead(0, 16).fold<List<int>>(<int>[], (
      out,
      chunk,
    ) {
      out.addAll(chunk);
      return out;
    });
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
      final tables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get();
      final names = {for (final row in tables) '${row.data['name']}'};
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
      // Persist which files this swap parked so a crash after sqlite is
      // back, before bakPhotos rename, still restores those photos — and so
      // leftover bak from an earlier committed restore is not trusted.
      final phase = rollbackSwapMarker(
        parkedSqlite: parkedSqlite,
        parkedPhotos: parkedPhotos,
      );
      if (phase == null) return;
      await marker.writeAsString(phase, flush: true);
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

    await marker.writeAsString(
      await stagedPhotos.exists()
          ? kRestoreSwapMarkerInProgress
          : kRestoreSwapMarkerNoPhotos,
      flush: true,
    );
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
        final rollbackPending =
            (parkedSqlite && await bakSqlite.exists()) ||
            (parkedPhotos && await bakPhotos.exists());
        if (!rollbackPending) {
          try {
            if (await marker.exists()) await marker.delete();
          } catch (_) {}
        }
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
