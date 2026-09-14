import 'dart:io';

import 'package:path/path.dart' as p;

const kSqliteFileName = 'wired_parts.sqlite';
const kRestoreSwapMarkerName = 'restore_swap.marker';
const kSqliteRestoreBakName = '$kSqliteFileName.restore-bak';
const kPhotosRestoreBakName = 'part_photos.restore-bak';
const kRestoreStagingName = 'restore_staging';

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
  recoverInterruptedRestore(supportDir: supportDir);
  final dest = File(p.join(supportDir.path, fileName));
  if (dest.existsSync()) return dest;

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
void recoverInterruptedRestore({required Directory supportDir}) {
  final marker = File(p.join(supportDir.path, kRestoreSwapMarkerName));
  if (!marker.existsSync()) return;

  final liveSqlite = File(p.join(supportDir.path, kSqliteFileName));
  final livePhotos = Directory(p.join(supportDir.path, 'part_photos'));
  final bakSqlite = File(p.join(supportDir.path, kSqliteRestoreBakName));
  final bakPhotos = Directory(p.join(supportDir.path, kPhotosRestoreBakName));
  final staging = Directory(p.join(supportDir.path, kRestoreStagingName));
  final stagedSqlite = File(p.join(staging.path, kSqliteFileName));
  final stagedPhotos = Directory(p.join(staging.path, 'part_photos'));

  try {
    if (stagedSqlite.existsSync()) {
      if (!liveSqlite.existsSync()) {
        stagedSqlite.renameSync(liveSqlite.path);
        _deleteSqliteSidecarsSync(liveSqlite);
      }
    } else if (!liveSqlite.existsSync() && bakSqlite.existsSync()) {
      bakSqlite.renameSync(liveSqlite.path);
    }

    if (stagedPhotos.existsSync()) {
      if (!livePhotos.existsSync()) {
        stagedPhotos.renameSync(livePhotos.path);
      } else if (!stagedSqlite.existsSync() && bakSqlite.existsSync()) {
        // Sqlite swap already committed; finish replacing photos.
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
    } else if (!livePhotos.existsSync() && bakPhotos.existsSync()) {
      bakPhotos.renameSync(livePhotos.path);
    }
  } finally {
    try {
      if (marker.existsSync()) marker.deleteSync();
    } catch (_) {}
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void _deleteSqliteSidecarsSync(File sqlite) {
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    final side = File('${sqlite.path}$suffix');
    if (side.existsSync()) {
      try {
        side.deleteSync();
      } catch (_) {}
    }
  }
}
