import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/sqlite_file.dart';

/// Deletes the on-disk sqlite file (plus WAL/SHM), part photos, and restore
/// leftovers (marker, staging, `.restore-bak`) so reopen cannot promote a
/// wiped shop back into place.
///
/// Caller must close [AppDatabase] first, then open a new database.
/// Also clears a Phase 1 Documents leftover so [resolveSqliteFile] cannot
/// copy the old shop back into Application Support.
class LocalDataReset {
  const LocalDataReset({this.supportDir, this.documentsDir, this.photosDir});

  final Directory? supportDir;
  final Directory? documentsDir;
  final Directory? photosDir;

  static const sqliteSidecars = [
    kSqliteFileName,
    '$kSqliteFileName-wal',
    '$kSqliteFileName-shm',
    '$kSqliteFileName-journal',
  ];

  Future<Directory> _support() async =>
      supportDir ?? await getApplicationSupportDirectory();

  Future<Directory?> _documents() async {
    if (documentsDir != null) return documentsDir;
    try {
      return await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      return null;
    }
  }

  Future<void> _deleteSqliteIn(Directory dir) async {
    for (final name in sqliteSidecars) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> wipeFiles() async {
    final dir = await _support();
    final marker = File(p.join(dir.path, kRestoreSwapMarkerName));
    if (await marker.exists()) {
      await marker.delete();
    }
    for (final name in [kRestoreStagingName, kRestoreStagingNextName]) {
      final staging = Directory(p.join(dir.path, name));
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
    final bakSqlite = File(p.join(dir.path, kSqliteRestoreBakName));
    if (await bakSqlite.exists()) {
      await bakSqlite.delete();
    }
    final bakPhotos = Directory(p.join(dir.path, kPhotosRestoreBakName));
    if (await bakPhotos.exists()) {
      await bakPhotos.delete(recursive: true);
    }
    await _deleteSqliteIn(dir);
    await clearDocumentsLeftover();
    final photos =
        photosDir ?? Directory(p.join(dir.path, 'part_photos'));
    if (await photos.exists()) {
      await photos.delete(recursive: true);
    }
  }

  Future<void> clearDocumentsLeftover() async {
    final docs = await _documents();
    if (docs == null) return;
    final support = await _support();
    if (p.canonicalize(docs.path) == p.canonicalize(support.path)) return;
    await _deleteSqliteIn(docs);
  }
}
