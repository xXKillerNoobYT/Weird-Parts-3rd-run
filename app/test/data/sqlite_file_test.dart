import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/sqlite_file.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('wp-sqlite-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('copies Documents sqlite into empty Application Support', () {
    final docs = Directory(p.join(tmp.path, 'docs'))..createSync();
    final support = Directory(p.join(tmp.path, 'support'));
    File(p.join(docs.path, kSqliteFileName)).writeAsStringSync('phase1-db');
    File(p.join(docs.path, '$kSqliteFileName-wal')).writeAsStringSync('wal');

    final dest = resolveSqliteFile(supportDir: support, documentsDir: docs);
    expect(dest.existsSync(), isTrue);
    expect(dest.readAsStringSync(), 'phase1-db');
    expect(File('${dest.path}-wal').readAsStringSync(), 'wal');
  });

  test('does not overwrite an existing Application Support database', () {
    final docs = Directory(p.join(tmp.path, 'docs'))..createSync();
    final support = Directory(p.join(tmp.path, 'support'))..createSync();
    File(p.join(docs.path, kSqliteFileName)).writeAsStringSync('old');
    File(p.join(support.path, kSqliteFileName)).writeAsStringSync('current');

    final dest = resolveSqliteFile(supportDir: support, documentsDir: docs);
    expect(dest.readAsStringSync(), 'current');
  });
}
