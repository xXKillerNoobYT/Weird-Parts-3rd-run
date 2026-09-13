import 'dart:io';

import 'package:path/path.dart' as p;

const kSqliteFileName = 'wired_parts.sqlite';

/// Prefer Application Support. If that file is missing, copy a Phase 1
/// Documents DB (and WAL/SHM sidecars) so an upgrade does not look empty.
File resolveSqliteFile({
  required Directory supportDir,
  Directory? documentsDir,
  String fileName = kSqliteFileName,
}) {
  supportDir.createSync(recursive: true);
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
