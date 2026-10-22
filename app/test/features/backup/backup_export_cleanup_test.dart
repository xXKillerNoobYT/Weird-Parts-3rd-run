import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

void main() {
  for (final outcome in [
    'completed bytes',
    'primary read error',
    'company-history rejection',
  ]) {
    final failRead = outcome == 'primary read error';
    final companyHistory = outcome == 'company-history rejection';
    test('export preserves $outcome when temporary cleanup fails', () async {
      final source = Directory.systemTemp.createTempSync(
        'export-cleanup-source-',
      );
      final scratch = Directory.systemTemp.createTempSync(
        'export-cleanup-scratch-',
      );
      addTearDown(() => source.deleteSync(recursive: true));
      addTearDown(() => scratch.deleteSync(recursive: true));
      final photos = Directory(p.join(source.path, 'part_photos'))
        ..createSync();
      final photo = File(p.join(photos.path, 'synthetic.jpg'))
        ..writeAsBytesSync([7, 8, 9]);
      final sourceFile = File(p.join(source.path, kSqliteFileName));
      final db = AppDatabase.forTesting(NativeDatabase(sourceFile));
      await db.settingsDao.setSetting('marker', 'synthetic business data');
      await db.settingsDao.setSetting(
        kInstallationBindingKey,
        'synthetic local binding',
      );
      if (companyHistory) {
        await db.customStatement(
          'INSERT INTO company_authority_facts (company_id, commitment, signed_bytes) VALUES (?, ?, ?)',
          ['synthetic company', 'synthetic commitment', 'synthetic facts'],
        );
      }
      await db.close();
      final original = sourceFile.readAsBytesSync();
      final io = _ExportCleanupIo(scratch, failRead: failRead);
      final store = BackupStore(supportDir: source);
      Future<Uint8List> collect() async {
        final payload = await store.collect(
          sourceDeviceId: 'synthetic',
          createdAt: DateTime.utc(2026, 10, 20),
          sqliteBytes: original,
        );
        expect(payload.photos, {
          'synthetic.jpg': [7, 8, 9],
        });
        return payload.sqliteBytes;
      }

      final companyRejection = throwsA(
        isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('Company history requires a compatible authorized backup'),
        ),
      );
      if (companyHistory) {
        await expectLater(
          IOOverrides.runWithIOOverrides(collect, io),
          companyRejection,
        );
      } else if (failRead) {
        await expectLater(
          IOOverrides.runWithIOOverrides(collect, io),
          throwsA(same(io.readError)),
        );
      } else {
        final bytes = await IOOverrides.runWithIOOverrides(collect, io);
        _expectBusinessSnapshot(scratch, bytes);
      }
      expect(io.deleteAttempts, 1);
      expect(io.staging!.existsSync(), isTrue);
      expect(
        File(p.join(io.staging!.path, kSqliteFileName)).existsSync(),
        isTrue,
      );
      expect(sourceFile.readAsBytesSync(), original);
      expect(photo.readAsBytesSync(), [7, 8, 9]);
      final sourceDb = sqlite.sqlite3.open(sourceFile.path);
      try {
        expect(
          sourceDb.select('PRAGMA integrity_check').single.values.single,
          'ok',
        );
        expect(
          sourceDb.select('SELECT value FROM app_settings WHERE key = ?', [
            kInstallationBindingKey,
          ]).single['value'],
          'synthetic local binding',
        );
        if (companyHistory) {
          expect(
            sourceDb
                .select('SELECT signed_bytes FROM company_authority_facts')
                .single['signed_bytes'],
            'synthetic facts',
          );
        }
      } finally {
        sourceDb.dispose();
      }
      if (companyHistory) {
        await expectLater(collect(), companyRejection);
      } else {
        _expectBusinessSnapshot(scratch, await collect());
      }
      expect(sourceFile.readAsBytesSync(), original);
    });
  }
}

void _expectBusinessSnapshot(Directory scratch, Uint8List bytes) {
  expect(backupSqliteSchemaVersion(bytes), kAppSchemaVersion);
  final file = File(p.join(scratch.path, 'verified.sqlite'))
    ..writeAsBytesSync(bytes);
  final db = sqlite.sqlite3.open(file.path);
  try {
    expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(
      db
          .select("SELECT value FROM app_settings WHERE key = 'marker'")
          .single['value'],
      'synthetic business data',
    );
    expect(
      db.select('SELECT value FROM app_settings WHERE key = ?', [
        kInstallationBindingKey,
      ]),
      isEmpty,
    );
  } finally {
    db.dispose();
  }
}

final class _ExportCleanupIo extends IOOverrides {
  _ExportCleanupIo(this.scratch, {required this.failRead});

  final Directory scratch;
  final bool failRead;
  final readError = const FileSystemException(
    'Synthetic snapshot read failure',
  );
  Directory? staging;
  int deleteAttempts = 0;

  @override
  Directory getSystemTempDirectory() => _ExportTempDirectory(this);

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (failRead && staging != null && p.dirname(path) == staging!.path) {
      return _UnreadableSnapshot(file, readError);
    }
    return file;
  }
}

class _ExportTempDirectory implements Directory {
  _ExportTempDirectory(this.io);
  final _ExportCleanupIo io;

  @override
  Future<Directory> createTemp([String? prefix]) async {
    io.staging = await io.scratch.createTemp(prefix);
    return _UndeletableExportDirectory(io);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UndeletableExportDirectory implements Directory {
  _UndeletableExportDirectory(this.io);
  final _ExportCleanupIo io;

  @override
  String get path => io.staging!.path;

  @override
  Future<Directory> delete({bool recursive = false}) async {
    io.deleteAttempts++;
    throw const FileSystemException('Synthetic temporary cleanup failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnreadableSnapshot implements File {
  _UnreadableSnapshot(this.file, this.error);
  final File file;
  final FileSystemException error;

  @override
  String get path => file.path;

  @override
  Directory get parent => file.parent;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => file.writeAsBytes(bytes, mode: mode, flush: flush);

  @override
  Future<Uint8List> readAsBytes() async => throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
