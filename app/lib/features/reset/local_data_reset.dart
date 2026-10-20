import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/sqlite_file.dart';
import '../backup/backup_store.dart' show requireLegacyBusinessFile;

final class LocalDataResetNoEffectFailure implements Exception {
  const LocalDataResetNoEffectFailure._(this.cause, this.stackTrace);
  final Object cause;
  final StackTrace stackTrace;
}

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

  /// Check every store reset may delete before rotating installation identity.
  Future<void> preflight() async {
    final dir = await _support();
    requireLegacyBusinessFile(File(p.join(dir.path, kSqliteFileName)));
    final documents = await _documents();
    if (documents != null) {
      requireLegacyBusinessFile(File(p.join(documents.path, kSqliteFileName)));
    }
  }

  Future<void> wipeFiles() async {
    late Directory dir;
    late Directory? documents;
    late Directory photos;
    try {
      dir = await _support();
      documents = await _documents();
      photos = photosDir ?? Directory(p.join(dir.path, 'part_photos'));
      requireLegacyBusinessFile(File(p.join(dir.path, kSqliteFileName)));
      if (documents != null) {
        requireLegacyBusinessFile(
          File(p.join(documents.path, kSqliteFileName)),
        );
      }
    } catch (error, stack) {
      throw LocalDataResetNoEffectFailure._(error, stack);
    }
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
    if (documents != null &&
        p.canonicalize(documents.path) != p.canonicalize(dir.path)) {
      await _deleteSqliteIn(documents);
    }
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
