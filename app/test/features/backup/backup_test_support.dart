import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';

Future<Uint8List> sqliteBytesWithSetting({
  required String key,
  required String value,
}) async {
  final dir = Directory.systemTemp.createTempSync('wp-sql-bytes-');
  try {
    final file = File(p.join(dir.path, kSqliteFileName));
    final db = AppDatabase.forTesting(NativeDatabase(file));
    await db.settingsDao.setSetting(key, value);
    await db.close();
    return Uint8List.fromList(file.readAsBytesSync());
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Future<String?> readSqliteSetting(Directory dir, String key) async {
  final db = AppDatabase.forTesting(
    NativeDatabase(File(p.join(dir.path, kSqliteFileName))),
  );
  try {
    return db.settingsDao.getSetting(key);
  } finally {
    await db.close();
  }
}
