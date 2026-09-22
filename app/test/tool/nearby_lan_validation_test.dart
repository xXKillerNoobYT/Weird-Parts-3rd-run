import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/catalog/part_photo_store.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import '../../tool/nearby_lan_validation.dart';
import '../../tool/nearby_lan_workspace.dart';

void main() {
  late Directory temp;
  late PathProviderPlatform previous;
  ValidationWorkspace? workspace;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('lan-workspace-test-');
    previous = PathProviderPlatform.instance;
  });
  tearDown(() {
    workspace?.close();
    workspace = null;
    PathProviderPlatform.instance = previous;
    temp.deleteSync(recursive: true);
  });

  test(
    'rejects path injection and foreign roots without changing their data',
    () {
      expect(
        () => ValidationWorkspace.open(
          run: '../real',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        ),
        throwsArgumentError,
      );
      final root = Directory(p.join(temp.path, 'wired-parts-lan-test-sender'))
        ..createSync();
      final sentinel = File(p.join(root.path, 'real-shop'))
        ..writeAsStringSync('preserve');
      expect(
        () => ValidationWorkspace.open(
          run: 'test',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        ),
        throwsStateError,
      );
      expect(sentinel.readAsStringSync(), 'preserve');
      expect(root.listSync().length, 1);
    },
  );

  test(
    'rejects root and nested symlinks before opening shop storage',
    () {
      final foreign = Directory(p.join(temp.path, 'foreign'))..createSync();
      final link = Link(p.join(temp.path, 'wired-parts-lan-test-sender'));
      link.createSync(foreign.path);
      expect(
        () => ValidationWorkspace.open(
          run: 'test',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        ),
        throwsStateError,
      );
      link.deleteSync();
      workspace = ValidationWorkspace.open(
        run: 'test',
        role: ValidationRole.sender,
        temporaryDirectory: temp,
      );
      workspace!.markInitialized();
      workspace!.close();
      Link(p.join(workspace!.support.path, 'escape')).createSync(foreign.path);
      expect(
        () => ValidationWorkspace.open(
          run: 'test',
          role: ValidationRole.sender,
          temporaryDirectory: temp,
        ),
        throwsStateError,
      );
      expect(foreign.listSync(), isEmpty);
    },
    skip: Platform.isWindows
        ? 'Creating symlinks requires an elevated Windows test account'
        : false,
  );

  test(
    'all production storage defaults use the isolated directories',
    () async {
      workspace = ValidationWorkspace.open(
        run: 'paths',
        role: ValidationRole.receiver,
        temporaryDirectory: temp,
      );
      PathProviderPlatform.instance = workspace!;
      expect(
        (await const BackupStore().sqliteFile()).path,
        p.join(workspace!.support.path, kSqliteFileName),
      );
      expect(
        (await const PartPhotoStore().photosDirectory()).path,
        workspace!.photos.path,
      );
      final external = File(p.join(temp.path, 'unrelated.sqlite'))
        ..writeAsStringSync('preserve');
      final legacy = File(p.join(workspace!.documents.path, kSqliteFileName))
        ..writeAsStringSync('synthetic');
      await const LocalDataReset().wipeFiles();
      expect(legacy.existsSync(), false);
      expect(external.readAsStringSync(), 'preserve');
    },
  );

  test(
    'fixture survives reopen and receipt records actual persisted content',
    () async {
      workspace = ValidationWorkspace.open(
        run: 'persist',
        role: ValidationRole.receiver,
        temporaryDirectory: temp,
      );
      final file = File(p.join(workspace!.support.path, kSqliteFileName));
      var db = AppDatabase.forTesting(NativeDatabase(file));
      await seedValidationShop(db, workspace!);
      workspace!.markInitialized();
      final before = await validationReceipt(db, workspace!);
      await db.jobsDao.insertJob(
        id: 'copied-job',
        name: 'received after seed',
        deviceId: 'sender',
      );
      await db.close();
      workspace!.close();
      workspace = ValidationWorkspace.open(
        run: 'persist',
        role: ValidationRole.receiver,
        temporaryDirectory: temp,
      );
      expect(workspace!.initialized, true);
      db = AppDatabase.forTesting(NativeDatabase(file));
      final after = await validationReceipt(db, workspace!);
      expect(
        (after['jobs'] as List).map((e) => (e as Map)['id']),
        contains('copied-job'),
      );
      expect(after['deviceIds'], ['lan-persist-receiver']);
      expect(after['photos'], before['photos']);
      expect(
        (after['photos'] as List).single['sha256'],
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
      expect(after['categoryIds'], ['persist-receiver-category']);
      expect(after['typeIds'], ['persist-receiver-type']);
      expect(after['variantIds'], ['persist-receiver-variant']);
      await db.close();
    },
  );
}
