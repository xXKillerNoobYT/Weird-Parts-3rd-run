import 'dart:async';
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
import 'package:wired_parts/features/nearby/nearby_controller.dart';

import '../../tool/nearby_lan_validation.dart';
import '../../tool/nearby_lan_workspace.dart';

enum _LockChildMode { normal, delayedReadiness, delayedShutdown }

const _lockChildDeadline = Duration(seconds: 10);

Future<void> _withLockedWorkspaceChild({
  required String lockPath,
  required _LockChildMode mode,
  required FutureOr<void> Function() whileLocked,
  void Function(Process child)? onStarted,
}) async {
  const normalProgram =
      "import os,sys; f=open(sys.argv[1], 'a+b'); "
      "exec('import msvcrt; msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)' if os.name == 'nt' else 'import fcntl; fcntl.lockf(f, fcntl.LOCK_EX)'); "
      "print('locked', flush=True); sys.stdin.read()";
  const controlledProgram = '''
import os,sys,time,threading
f=open(sys.argv[1], 'a+b')
exec('import msvcrt; msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)' if os.name == 'nt' else 'import fcntl; fcntl.lockf(f, fcntl.LOCK_EX)')
mode=sys.argv[2]
print('lock-acquired', file=sys.stderr, flush=True)
if mode == 'readiness':
    closed=threading.Event()
    def watch_stdin():
        sys.stdin.read()
        closed.set()
    threading.Thread(target=watch_stdin, daemon=True).start()
    deadline=time.monotonic()+45
    while time.monotonic()<deadline and not closed.wait(0.02):
        pass
    if closed.is_set():
        sys.exit(0)
    print('locked', flush=True)
    sys.stdin.read()
elif mode == 'shutdown':
    print('locked', flush=True)
    sys.stdin.read()
    time.sleep(45)
''';

  final args = <String>[
    '-u',
    '-c',
    mode == _LockChildMode.normal ? normalProgram : controlledProgram,
    lockPath,
    if (mode != _LockChildMode.normal)
      mode == _LockChildMode.delayedReadiness ? 'readiness' : 'shutdown',
  ];
  Process? child;
  var bodyFailed = false;
  try {
    child = await Process.start(
      Platform.isWindows ? 'python' : 'python3',
      args,
    );
    onStarted?.call(child);
    if (mode != _LockChildMode.normal) {
      expect(
        await child.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(_lockChildDeadline),
        'lock-acquired',
      );
    }
    if (mode == _LockChildMode.delayedReadiness) await whileLocked();
    expect(
      await child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(_lockChildDeadline),
      'locked',
    );
    if (mode != _LockChildMode.delayedReadiness) await whileLocked();
  } catch (_) {
    bodyFailed = true;
    rethrow;
  } finally {
    final owned = child;
    if (owned != null) {
      try {
        await owned.stdin.close();
        await owned.exitCode.timeout(_lockChildDeadline);
      } catch (cleanupError, stackTrace) {
        try {
          owned.kill();
        } catch (_) {}
        try {
          await owned.exitCode.timeout(_lockChildDeadline);
        } catch (_) {}
        if (!bodyFailed) {
          Error.throwWithStackTrace(cleanupError, stackTrace);
        }
      }
    }
  }
}

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

  Future<void> runTimeoutCase({
    required bool initialized,
    required _LockChildMode mode,
  }) async {
    final stage = mode == _LockChildMode.delayedReadiness
        ? 'readiness'
        : 'shutdown';
    final run = '$stage-${initialized ? 'existing' : 'new'}';
    final root = Directory(p.join(temp.path, 'wired-parts-lan-$run-sender'));
    final marker = File(p.join(root.path, 'validation-owner.json'));
    final storage = File(p.join(root.path, 'support', kSqliteFileName));
    List<int>? markerBefore;
    List<int>? storageBefore;
    if (initialized) {
      workspace = ValidationWorkspace.open(
        run: run,
        role: ValidationRole.sender,
        temporaryDirectory: temp,
      );
      workspace!.markInitialized();
      markerBefore = marker.readAsBytesSync();
      storage.createSync(recursive: true);
      storage.writeAsBytesSync(utf8.encode('known shop storage'));
      storageBefore = storage.readAsBytesSync();
      workspace!.close();
    }

    Process? child;
    var childExited = false;
    var whileLockedChecksCompleted = false;
    void expectUnchanged() {
      if (initialized) {
        expect(marker.readAsBytesSync(), markerBefore);
        expect(storage.readAsBytesSync(), storageBefore);
      } else {
        expect(root.existsSync(), isFalse);
        expect(marker.existsSync(), isFalse);
        expect(storage.existsSync(), isFalse);
      }
    }

    try {
      await _withLockedWorkspaceChild(
        lockPath: '${root.path}.lock',
        mode: mode,
        onStarted: (started) {
          child = started;
          unawaited(started.exitCode.then((_) => childExited = true));
        },
        whileLocked: () {
          expect(
            () => ValidationWorkspace.open(
              run: run,
              role: ValidationRole.sender,
              temporaryDirectory: temp,
            ),
            throwsA(isA<FileSystemException>()),
          );
          expectUnchanged();
          whileLockedChecksCompleted = true;
        },
      );
      fail('Expected the $stage deadline to expire');
    } on TimeoutException {
      await Future<void>.delayed(Duration.zero);
      expect(
        whileLockedChecksCompleted,
        isTrue,
        reason: 'the competing-open and unchanged-state checks must run',
      );
      expectUnchanged();
      expect(child, isNotNull);
      expect(
        childExited,
        isTrue,
        reason: 'the owned child must exit on timeout',
      );
    } finally {
      final owned = child;
      if (owned != null) {
        if (!childExited) owned.kill();
        await owned.exitCode.timeout(_lockChildDeadline);
      }
    }
  }

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
        NearbyController factory(String alias) =>
            throw StateError('Join was not requested');
        app = await tester.runAsync(
          () => validationApplication(
            workspace!,
            createCompanyJoinController: factory,
          ),
        );
        final first = app!;
        final namespace = validationInstallationNamespace(
          run: 'startup',
          roleName: 'receiver',
        );
        expect(first.installation!.namespace, namespace);
        expect(first.installation!.store, isA<NativeInstallationSecureStore>());
        expect(first.installation!.readiness, InstallationReadiness.ready);
        expect(first.enableCompanyBootstrap, isTrue);
        expect(first.createCompanyJoinController, same(factory));
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
        expect(
          tester
              .widget<CompanyBootstrapGate>(find.byType(CompanyBootstrapGate))
              .createJoinController,
          same(factory),
        );
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
        expect(reopened.createCompanyJoinController, isNull);
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
        final storage = File(p.join(root.path, 'support', kSqliteFileName));
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
        await _withLockedWorkspaceChild(
          lockPath: '${root.path}.lock',
          mode: _LockChildMode.normal,
          whileLocked: () {
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
            expect(storage.existsSync(), isFalse);
          },
        );
      }
    },
  );

  for (final initialized in [false, true]) {
    test(
      'competing process readiness timeout preserves ${initialized ? 'initialized' : 'new'} workspace and exits child',
      () => runTimeoutCase(
        initialized: initialized,
        mode: _LockChildMode.delayedReadiness,
      ),
    );
    test(
      'competing process shutdown timeout preserves ${initialized ? 'initialized' : 'new'} workspace and exits child',
      () => runTimeoutCase(
        initialized: initialized,
        mode: _LockChildMode.delayedShutdown,
      ),
    );
  }

  test(
    'delayed shutdown cleanup preserves the original locked assertion',
    () async {
      Process? child;
      var childExited = false;
      Object? thrown;
      try {
        try {
          await _withLockedWorkspaceChild(
            lockPath: p.join(temp.path, 'primary-error.lock'),
            mode: _LockChildMode.delayedShutdown,
            onStarted: (started) {
              child = started;
              unawaited(started.exitCode.then((_) => childExited = true));
            },
            whileLocked: () {
              throw StateError('sentinel locked-workspace assertion');
            },
          );
        } catch (error) {
          thrown = error;
        }

        final owned = child;
        expect(owned, isNotNull);
        await owned!.exitCode.timeout(_lockChildDeadline);
        expect(
          childExited,
          isTrue,
          reason: 'the captured child must settle before rescue',
        );
        expect(
          thrown,
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'sentinel locked-workspace assertion',
          ),
        );
      } finally {
        final owned = child;
        if (owned != null) {
          if (!childExited) owned.kill();
          await owned.exitCode.timeout(_lockChildDeadline);
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
