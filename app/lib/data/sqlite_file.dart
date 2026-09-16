import 'dart:io';

import 'package:path/path.dart' as p;

const kSqliteFileName = 'wired_parts.sqlite';
const kRestoreSwapMarkerName = 'restore_swap.marker';
const kRestoreSwapMarkerInProgress = 'in-progress';
const kRestoreSwapMarkerNoPhotos = 'in-progress-no-photos';
const kRestoreSwapMarkerRollback = 'rolling-back';
const kSqliteRestoreBakName = '$kSqliteFileName.restore-bak';
const kPhotosRestoreBakName = 'part_photos.restore-bak';
const kRestoreStagingName = 'restore_staging';
const kRestoreStagingNextName = 'restore_staging.next';
const kRestoreRecoverRetryMessage =
    'Restore did not finish. Restart the app to retry.';
const _sqliteSidecarSuffixes = ['-wal', '-shm', '-journal'];

/// Set when [resolveSqliteFile] catches a recover failure after live sqlite
/// is already present. Cleared when recover finishes. Launch must still start.
Object? restoreRecoverError;

/// Prefer Application Support. If that file is missing, copy a Phase 1
/// Documents DB (and WAL/SHM sidecars) so an upgrade does not look empty.
///
/// Recovers an interrupted restore swap first so a missing live sqlite is
/// not replaced by an empty file or an obsolete Documents copy.
File resolveSqliteFile({
  required Directory supportDir,
  Directory? documentsDir,
  String fileName = kSqliteFileName,
}) {
  supportDir.createSync(recursive: true);
  try {
    recoverInterruptedRestore(supportDir: supportDir);
    restoreRecoverError = null;
  } catch (e) {
    final dest = File(p.join(supportDir.path, fileName));
    if (!dest.existsSync()) rethrow;
    // Live shop is already on disk. Do not brick launch; keep marker/staging
    // and surface [restoreRecoverError] in the UI.
    restoreRecoverError = e;
  }
  final dest = File(p.join(supportDir.path, fileName));
  if (dest.existsSync()) return dest;

  final marker = File(p.join(supportDir.path, kRestoreSwapMarkerName));
  if (marker.existsSync()) {
    // Incomplete restore: do not invent a shop from Documents.
    return dest;
  }

  if (documentsDir != null) {
    final src = File(p.join(documentsDir.path, fileName));
    if (src.existsSync()) {
      src.copySync(dest.path);
      for (final suffix in const ['-wal', '-shm']) {
        final side = File('${src.path}$suffix');
        if (side.existsSync()) {
          side.copySync('${dest.path}$suffix');
        }
      }
    }
  }
  return dest;
}

/// Finish or roll back a restore that crashed between live/bak/staging
/// renames. Safe to call when no marker is present.
///
/// Marker and staging are removed only after live sqlite is in place and
/// nothing remains to promote from staging. A failed rename keeps both so
/// the next startup can retry.
void recoverInterruptedRestore({
  required Directory supportDir,
  void Function()? beforeReplaceLivePhotos,
  void Function()? beforeDeleteSqliteSidecars,
}) {
  final marker = File(p.join(supportDir.path, kRestoreSwapMarkerName));
  if (!marker.existsSync()) return;

  final liveSqlite = File(p.join(supportDir.path, kSqliteFileName));
  final livePhotos = Directory(p.join(supportDir.path, 'part_photos'));
  final bakSqlite = File(p.join(supportDir.path, kSqliteRestoreBakName));
  final bakPhotos = Directory(p.join(supportDir.path, kPhotosRestoreBakName));
  final staging = Directory(p.join(supportDir.path, kRestoreStagingName));
  final stagedSqlite = File(p.join(staging.path, kSqliteFileName));
  final stagedPhotos = Directory(p.join(staging.path, 'part_photos'));
  // Capture before promoting sqlite: a photo backup onto a shop with no
  // folder looks like leftover live photos once staging is gone.
  final hadStagedSqlite = stagedSqlite.existsSync();
  final hadStagedPhotos = stagedPhotos.existsSync();
  final hadLiveSqlite = liveSqlite.existsSync();
  final rollingBack = _markerSaysRollback(marker);
  final noPhotoBackup =
      _markerSaysNoPhotos(marker) || (hadStagedSqlite && !hadStagedPhotos);

  // Marker was written but live sqlite was never parked. Staged files are a
  // never-started swap; keep the live shop and drop the restore. Skip this
  // during rollback: live sqlite may already be the restored bak while
  // staging still holds the failed restore.
  if (!rollingBack && hadLiveSqlite && hadStagedSqlite) {
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    } catch (_) {}
    try {
      if (marker.existsSync()) marker.deleteSync();
    } catch (_) {}
    return;
  }

  var sqliteFromBak = false;
  Object? error;
  try {
    if (rollingBack && bakSqlite.existsSync()) {
      if (liveSqlite.existsSync()) {
        try {
          liveSqlite.deleteSync();
        } catch (_) {}
      }
      bakSqlite.renameSync(liveSqlite.path);
      sqliteFromBak = true;
    } else if (stagedSqlite.existsSync()) {
      if (!liveSqlite.existsSync()) {
        stagedSqlite.renameSync(liveSqlite.path);
      }
    } else if (!liveSqlite.existsSync() && bakSqlite.existsSync()) {
      bakSqlite.renameSync(liveSqlite.path);
      sqliteFromBak = true;
    }

    // Only strip leftover WAL/SHM from the previous shop after this recover
    // placed sqlite. Live-shop sidecars must stay: export and later startups
    // can see a leftover marker while the connection is already open.
    // Rollback replaces live sqlite at the same path, so its WAL is the
    // failed restore's, not the bak shop's.
    if (liveSqlite.existsSync() && (!hadLiveSqlite || sqliteFromBak)) {
      beforeDeleteSqliteSidecars?.call();
      _deleteSqliteSidecarsSync(liveSqlite);
    }

    if (rollingBack && bakPhotos.existsSync()) {
      if (livePhotos.existsSync()) {
        try {
          livePhotos.deleteSync(recursive: true);
        } catch (_) {}
      }
      if (!livePhotos.existsSync() && bakPhotos.existsSync()) {
        bakPhotos.renameSync(livePhotos.path);
      }
    } else if (stagedPhotos.existsSync() && !sqliteFromBak) {
      // Staged photos belong to the new shop. Do not apply them after
      // rolling sqlite back from bak.
      if (!livePhotos.existsSync()) {
        stagedPhotos.renameSync(livePhotos.path);
      } else if (!stagedSqlite.existsSync() && liveSqlite.existsSync()) {
        // Sqlite swap already committed; finish replacing photos. Live photos
        // may still be the pre-restore folder if park happened after sqlite.
        beforeReplaceLivePhotos?.call();
        if (!bakPhotos.existsSync()) {
          livePhotos.renameSync(bakPhotos.path);
        } else {
          try {
            livePhotos.deleteSync(recursive: true);
          } catch (_) {}
        }
        if (!livePhotos.existsSync() && stagedPhotos.existsSync()) {
          stagedPhotos.renameSync(livePhotos.path);
        }
      }
    } else if (!sqliteFromBak &&
        noPhotoBackup &&
        liveSqlite.existsSync() &&
        !stagedSqlite.existsSync() &&
        !stagedPhotos.existsSync() &&
        livePhotos.existsSync() &&
        bakSqlite.existsSync() &&
        !bakPhotos.existsSync()) {
      // No-photo backup: leftover live photos were never parked and belong
      // to the previous shop. Do not park when staging is already gone and
      // the marker does not say the backup had no photos — those images
      // are the restored backup.
      beforeReplaceLivePhotos?.call();
      livePhotos.renameSync(bakPhotos.path);
    } else if (!livePhotos.existsSync() && bakPhotos.existsSync()) {
      // Only roll bak photos when this recovery also rolled sqlite back.
      // A committed sqlite swap with missing live photos must not attach
      // the previous shop's images.
      if (sqliteFromBak || !liveSqlite.existsSync()) {
        bakPhotos.renameSync(livePhotos.path);
      }
    }
  } catch (e) {
    error = e;
  }

  final liveOk = liveSqlite.existsSync();
  // Staged photos are unfinished even when the old live folder is still
  // sitting in the way. Deleting staging here would drop the backup images
  // and leave no marker for the next startup to retry. Rollback leftover
  // staging is the failed restore, not photos to finish.
  final photosUnfinished =
      !rollingBack && stagedPhotos.existsSync() && !sqliteFromBak;
  final rollbackPhotosPending = rollingBack && bakPhotos.existsSync();
  final pendingStaging =
      (stagedSqlite.existsSync() && !liveOk) || photosUnfinished;
  if (hadLiveSqlite && liveOk && !pendingStaging) {
    try {
      _deleteStaleSqliteSidecarsSync(liveSqlite);
    } catch (e) {
      error ??= e;
    }
  }
  // Sidecars only block completing this recover if we just placed sqlite,
  // or leftover WAL/SHM from that place is still older than the live file.
  // Newer sidecars belong to an already-open shop and must stay.
  final sidecarsPending =
      liveOk &&
      ((!hadLiveSqlite && _sqliteSidecarsExist(liveSqlite)) ||
          (hadLiveSqlite &&
              !pendingStaging &&
              _staleSqliteSidecarsExist(liveSqlite)));

  if (liveOk && !pendingStaging && !sidecarsPending && !rollbackPhotosPending) {
    try {
      if (marker.existsSync()) marker.deleteSync();
    } catch (_) {}
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    } catch (_) {}
  }

  if (error != null &&
      (!liveOk || pendingStaging || sidecarsPending || rollbackPhotosPending)) {
    throw error;
  }
}

bool _markerSaysNoPhotos(File marker) {
  try {
    return marker.readAsStringSync().trim() == kRestoreSwapMarkerNoPhotos;
  } catch (_) {
    return false;
  }
}

bool _markerSaysRollback(File marker) {
  try {
    return marker.readAsStringSync().trim() == kRestoreSwapMarkerRollback;
  } catch (_) {
    return false;
  }
}

bool _sqliteSidecarsExist(File sqlite) {
  for (final suffix in _sqliteSidecarSuffixes) {
    if (File('${sqlite.path}$suffix').existsSync()) return true;
  }
  return false;
}

void _deleteSqliteSidecarsSync(File sqlite) {
  for (final suffix in _sqliteSidecarSuffixes) {
    final side = File('${sqlite.path}$suffix');
    if (side.existsSync()) side.deleteSync();
  }
}

bool _staleSqliteSidecarsExist(File sqlite) {
  if (!sqlite.existsSync()) return false;
  final sqliteMtime = sqlite.lastModifiedSync();
  for (final suffix in _sqliteSidecarSuffixes) {
    final side = File('${sqlite.path}$suffix');
    if (side.existsSync() && side.lastModifiedSync().isBefore(sqliteMtime)) {
      return true;
    }
  }
  return false;
}

void _deleteStaleSqliteSidecarsSync(File sqlite) {
  if (!sqlite.existsSync()) return;
  final sqliteMtime = sqlite.lastModifiedSync();
  for (final suffix in _sqliteSidecarSuffixes) {
    final side = File('${sqlite.path}$suffix');
    if (!side.existsSync()) continue;
    if (!side.lastModifiedSync().isBefore(sqliteMtime)) continue;
    side.deleteSync();
  }
}
