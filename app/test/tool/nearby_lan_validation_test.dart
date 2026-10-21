import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/catalog/part_photo_store.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/company/company_gate.dart';
import 'package:wired_parts/features/company/company_store_markers.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

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
    'run and role derive bounded distinct installation and custody namespaces',
    () {
      final names = <String>{};
      for (final run in ['x', 'a' * 48]) {
        for (final role in ['sender', 'receiver']) {
          final namespace = validationInstallationNamespace(
            run: run,
            roleName: role,
          );
          expect(names.add(namespace), isTrue);
          expect(namespace, startsWith('synthetic.lan.$role.'));
          expect(namespace.length, lessThanOrEqualTo(47));
          expect(
            companyCustodyNamespace(namespace).length,
            lessThanOrEqualTo(63),
          );
          expect(
            validationInstallationNamespace(run: run, roleName: role),
            namespace,
          );
        }
      }
      expect(
        validationInstallationNamespace(run: 'x', roleName: 'sender'),
        'synthetic.lan.sender.2d711642b726b04401627ca9',
      );
      expect(temp.listSync(), isEmpty);
    },
  );

  test(
    'invalid run and role fail namespace preflight without creating files',
    () {
      for (final run in ['', '../real', 'UPPER', 'a' * 49, 'bad_name']) {
        expect(
          () => validationInstallationNamespace(run: run, roleName: 'sender'),
          throwsArgumentError,
        );
      }
      for (final role in ['', 'production', 'Sender', '../receiver']) {
        expect(
          () =>
              validationInstallationNamespace(run: 'valid-run', roleName: role),
          throwsArgumentError,
        );
      }
      expect(temp.listSync(), isEmpty);
    },
  );

  testWidgets(
    'real startup uses only isolated protected state and preserves seeded local routing on reopen',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const channel = MethodChannel('wired_parts/installation_security');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final states = <String, Map<String, Object?>>{};
      final accessed = <String>[];
      WiredPartsApp? app;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        final namespace = args['namespace'] as String;
        accessed.add(namespace);
        if (call.method == 'readState') return states[namespace];
        if (call.method == 'compareAndSwapState') {
          if (states[namespace]?['revision'] != args['expectedRevision']) {
            throw PlatformException(code: 'installation_conflict');
          }
          states[namespace] = {
            'revision': args['nextRevision'],
            'bytes': args['bytes'],
          };
          return {'revision': args['nextRevision']};
        }
        throw UnsupportedError(call.method);
      });
      try {
        workspace = ValidationWorkspace.open(
          run: 'startup',
          role: ValidationRole.receiver,
          temporaryDirectory: temp,
        );
        PathProviderPlatform.instance = workspace!;
        final file = File(p.join(workspace!.support.path, kSqliteFileName));
        await tester.runAsync(() async {
          final seed = AppDatabase.forTesting(NativeDatabase(file));
          await seedValidationShop(seed, workspace!);
          workspace!.markInitialized();
          await seed.close();
        });
        app = await tester.runAsync(() => validationApplication(workspace!));
        final first = app!;
        final namespace = validationInstallationNamespace(
          run: 'startup',
          roleName: 'receiver',
        );
        expect(first.installation!.namespace, namespace);
        expect(first.installation!.store, isA<NativeInstallationSecureStore>());
        expect(first.installation!.readiness, InstallationReadiness.ready);
        expect(first.enableCompanyBootstrap, isTrue);
        expect(first.deviceId, workspace!.deviceId);
        await tester.pumpWidget(first);
        await tester.runAsync(() async {
          final timeout = Stopwatch()..start();
          while (find.byType(HomeShell).evaluate().isEmpty &&
              timeout.elapsed < const Duration(seconds: 5)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        expect(find.byType(CompanyBootstrapGate), findsOneWidget);
        expect(find.byType(HomeShell), findsOneWidget);
        expect(find.text('Continue local shop'), findsNothing);
        expect(
          await tester.runAsync(() => hasCompanyStoreMarkers(first.db)),
          isFalse,
        );
        final before = await tester.runAsync(
          () => validationReceipt(first.db, workspace!),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(first.db.close);
        app = null;
        final reopened = (await tester.runAsync(
          () => validationApplication(workspace!),
        ))!;
        app = reopened;
        expect(reopened.installation!.readiness, InstallationReadiness.ready);
        expect(reopened.installation!.namespace, namespace);
        expect(reopened.deviceId, first.deviceId);
        final after = (await tester.runAsync(
          () => validationReceipt(reopened.db, workspace!),
        ))!;
        expect(after['content'], before!['content']);
        expect(after['deviceIds'], before['deviceIds']);
        expect(accessed, isNotEmpty);
        expect(
          accessed.every(
            (key) =>
                key == namespace || key == companyCustodyNamespace(namespace),
          ),
          isTrue,
        );
        expect(states.keys, [namespace]);
        expect(accessed.any((key) => key.startsWith('production')), isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        final current = app;
        if (current != null) await tester.runAsync(current.db.close);
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

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
      final legacy = File(p.join(workspace!.documents.path, kSqliteFileName));
      final legacyDb = AppDatabase.forTesting(NativeDatabase(legacy));
      await legacyDb.customSelect('SELECT 1').get();
      await legacyDb.close();
      await const LocalDataReset().wipeFiles();
      expect(legacy.existsSync(), false);
      expect(external.readAsStringSync(), 'preserve');
    },
  );

  test('schema 11 receipt omits only schema 12 warehouse tables', () async {
    workspace = ValidationWorkspace.open(
      run: 'legacy-receipt',
      role: ValidationRole.receiver,
      temporaryDirectory: temp,
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement('DROP TABLE warehouse_counts');
    await db.customStatement('DROP TABLE warehouse_locations');
    await db.customStatement('PRAGMA user_version = 11');

    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      11,
    );
    final receipt = await validationReceipt(db, workspace!);
    final content = receipt['content']! as Map<String, Object?>;
    expect(content.containsKey('parts'), isTrue);
    expect(content.containsKey('warehouse_locations'), isFalse);
    expect(content.containsKey('warehouse_counts'), isFalse);
  });

  for (final missingTable in ['warehouse_locations', 'warehouse_counts']) {
    test('schema 12 receipt refuses missing $missingTable', () async {
      workspace = ValidationWorkspace.open(
        run: 'missing-${missingTable.replaceAll('_', '-')}',
        role: ValidationRole.receiver,
        temporaryDirectory: temp,
      );
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      expect(db.schemaVersion, kAppSchemaVersion);
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        kAppSchemaVersion,
      );
      await db.customStatement('DROP TABLE "$missingTable"');

      await expectLater(
        validationReceipt(db, workspace!),
        throwsA(
          predicate<Object>(
            (error) => '$error'.contains('no such table: $missingTable'),
          ),
        ),
      );
    });
  }

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
