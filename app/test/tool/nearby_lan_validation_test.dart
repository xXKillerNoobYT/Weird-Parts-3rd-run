import 'dart:io';
import 'dart:convert';

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
    'competing process cannot initialize or rewrite a locked workspace',
    () async {
      for (final initialized in [false, true]) {
        final run = initialized ? 'existing' : 'new';
        final root = Directory(
          p.join(temp.path, 'wired-parts-lan-$run-sender'),
        );
        final marker = File(p.join(root.path, 'validation-owner.json'));
        if (initialized) {
          workspace = ValidationWorkspace.open(
            run: run,
            role: ValidationRole.sender,
            temporaryDirectory: temp,
          );
          workspace!.markInitialized();
          workspace!.close();
        }
        final before = initialized ? marker.readAsStringSync() : null;
        final child = await Process.start(
          Platform.isWindows ? 'python' : 'python3',
          [
            '-u',
            '-c',
            "import os,sys; f=open(sys.argv[1], 'a+b'); "
                "exec('import msvcrt; msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)' if os.name == 'nt' else 'import fcntl; fcntl.lockf(f, fcntl.LOCK_EX)'); "
                "print('locked', flush=True); sys.stdin.read()",
            '${root.path}.lock',
          ],
        );
        try {
          expect(
            await child.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first
                .timeout(const Duration(seconds: 10)),
            'locked',
          );
          expect(
            () => ValidationWorkspace.open(
              run: run,
              role: ValidationRole.sender,
              temporaryDirectory: temp,
            ),
            throwsA(isA<FileSystemException>()),
          );
          if (initialized) {
            expect(marker.readAsStringSync(), before);
          } else {
            expect(root.existsSync(), isFalse);
          }
        } finally {
          await child.stdin.close();
          await child.exitCode.timeout(const Duration(seconds: 10));
        }
      }
    },
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
      expect((before['jobs'] as List).single['id'], 'persist-receiver-job');
      final tombstone = ((before['content'] as Map)['jobs'] as List)
          .singleWhere((row) => row['id'] == 'persist-receiver-deleted-job');
      expect(tombstone['name'], 'Synthetic deleted job');
      expect(tombstone['origin_device_id'], 'lan-persist-receiver');
      expect(tombstone['created_at'], 1700000000);
      expect(tombstone['modified_at'], 1700000060);
      expect(tombstone['deleted_at'], 1700000060);
      expect(tombstone['revision'], 7);

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
      final content = after['content'] as Map;
      expect(
        (content['jobs'] as List).singleWhere(
          (row) => row['id'] == 'persist-receiver-deleted-job',
        ),
        tombstone,
      );
      expect(
        (after['jobs'] as List).map((row) => row['id']),
        isNot(contains('persist-receiver-deleted-job')),
      );

      expect(
        (content['jobs'] as List).firstWhere(
          (row) => row['id'] == 'persist-receiver-job',
        )['job_number'],
        'LAN-42',
      );
      expect((content['job_lines'] as List).single['needed_qty'], 7.0);
      expect((content['supplier_listings'] as List).single['last_price'], 12.5);
      expect((content['order_splits'] as List).single['quantity'], 5.0);
      expect(content.containsKey('app_settings'), isFalse);
      expect(content.containsKey('device_profiles'), isFalse);
      await db.close();
    },
  );
}
