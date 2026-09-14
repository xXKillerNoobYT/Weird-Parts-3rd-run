import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/sqlite_file.dart';

/// Deletes the on-disk sqlite file (plus WAL/SHM) and part photos.
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
