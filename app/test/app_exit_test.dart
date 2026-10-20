import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import 'features/backup/backup_test_support.dart';
import 'features/company/company_job_test_support.dart';

class _ObservedDatabase extends AppDatabase {
  _ObservedDatabase([File? file])
    : super.forTesting(
        file == null ? NativeDatabase.memory() : NativeDatabase(file),
      );

  _ObservedDatabase.failOnOpen()
    : super.forTesting(
        NativeDatabase.memory(
          setup: (_) => throw StateError('Synthetic reopen failure'),
        ),
      );

  Completer<void>? closeGate;
  Future<void> Function()? beforeClose;
  Future<void> Function()? afterClose;
  var closeCalls = 0;
  var failNextClose = false;
  var closed = false;

  @override
  Future<void> close() async {
    closeCalls++;
    await closeGate?.future;
    await beforeClose?.call();
    if (failNextClose) {
      failNextClose = false;
      throw StateError('Synthetic close failure');
    }
    await super.close();
    closed = true;
    await afterClose?.call();
  }

  Future<void> cleanUp() async {
    if (!closed) {
      await super.close();
      closed = true;
    }
  }
}

class _ControlledReset extends LocalDataReset {
  _ControlledReset([this.gate]);
  final Completer<void>? gate;
  @override
  Future<void> preflight() async {}
  @override
  Future<void> wipeFiles() async => await gate?.future;
}

class _FailingReset extends LocalDataReset {
  _FailingReset(this.error);
  final StateError error;
  @override
  Future<void> preflight() async {}
  @override
  Future<void> wipeFiles() async => throw error;
}

Future<String> _mount(
  WidgetTester tester,
  _ObservedDatabase db, {
  LocalDataReset reset = const LocalDataReset(),
  AppDatabase Function()? reopenDatabase,
  Future<void> Function()? beforeRestore,
  InstallationSecurity? installation,
}) async {
  final deviceId = (await tester.runAsync(db.settingsDao.ensureDeviceId))!;
  await tester.pumpWidget(
    WiredPartsApp(
      db: db,
      pin: PinService(db.settingsDao),
      deviceId: deviceId,
      reset: reset,
      reopenDatabase: reopenDatabase,
      beforeRestore: beforeRestore,
      installation: installation,
    ),
  );
  await tester.pumpAndSettle();
  return deviceId;
}

void main() {
  setUp(BackupIo.end);
  tearDown(BackupIo.end);

  testWidgets('exit awaits the live database and coalesces repeated requests', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    db.closeGate = Completer<void>();
    var resolved = false;
    final first = tester.binding.handleRequestAppExit().then((value) {
      resolved = true;
      return value;
    });
    final second = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(db.closeCalls, 1);
    expect(resolved, isFalse);
    await expectLater(
      scope.wipeLocalData(),
      throwsA(isA<RestoreBusyException>()),
    );
    await expectLater(
      scope.restoreFromBackup([1], 'invalid-development-archive'),
      throwsA(isA<RestoreBusyException>()),
    );
    db.closeGate!.complete();
    await tester.runAsync(() async {
      expect(await first, AppExitResponse.exit);
      expect(await second, AppExitResponse.exit);
    });
    expect(db.closed, isTrue);
    expect(db.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('exit closes the replacement database after an actual restore', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('wp-exit-after-restore-');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    final documents = Directory(p.join(root.path, 'documents'))..createSync();
    final photos = Directory(p.join(root.path, 'photos'));
    final file = File(p.join(support.path, kSqliteFileName));
    final original = _ObservedDatabase(file);
    _ObservedDatabase? replacement;
    addTearDown(() async {
      await original.cleanUp();
      await replacement?.cleanUp();
      root.deleteSync(recursive: true);
    });
    await _mount(
      tester,
      original,
      reset: LocalDataReset(
        supportDir: support,
        documentsDir: documents,
        photosDir: photos,
      ),
      reopenDatabase: () => replacement = _ObservedDatabase(file),
    );
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final payload = BackupPayload(
      sourceDeviceId: 'synthetic-source',
      createdAt: DateTime.utc(2026, 10, 9),
      sqliteBytes: (await tester.runAsync(
        () => sqliteBytesWithSetting(key: 'marker', value: 'restored'),
      ))!,
      photos: const {},
    );
    await tester.runAsync(() => scope.restoreFromPayload!(payload));
    await tester.pumpAndSettle();
    final live = tester.widget<AppScope>(find.byType(AppScope)).db;
    expect(live, same(replacement));
    expect(original.closed, isTrue);
    expect(original.closeCalls, 1);
    expect(
      await tester.runAsync(() => live.settingsDao.getSetting('marker')),
      'restored',
    );
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.exit,
    );
    expect(replacement!.closed, isTrue);
    expect(replacement!.closeCalls, 1);
    expect(original.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failureMode in [
    'before-close',
    'binding-mismatch',
    'after-close',
  ]) {
    final retainedBinding = failureMode != 'binding-mismatch';
    final closedBeforeFailure = failureMode == 'after-close';
    testWidgets(
      switch (failureMode) {
        'before-close' => 'restore close failure aborts its intent, retains current floors and permits retry',
        'binding-mismatch' => 'restore close failure retains pending intent when original binding cannot be proved',
        _ => 'restore close failure after SQLite closes retains pending intent and original error',
      },
      (tester) async {
        final root = Directory.systemTemp.createTempSync('wp-restore-close-');
        final support = Directory(p.join(root.path, 'support'))..createSync();
        final documents = Directory(p.join(root.path, 'documents'))
          ..createSync();
        final photos = Directory(p.join(root.path, 'photos'));
        final file = File(p.join(support.path, kSqliteFileName));
        final original = _ObservedDatabase(file);
        _ObservedDatabase? replacement;
        addTearDown(() async {
          await original.cleanUp();
          await replacement?.cleanUp();
          root.deleteSync(recursive: true);
        });
        final store = JobTestStore();
        final installation = InstallationSecurity(
          store: store,
          namespace: 'synthetic.restore-close',
        );
        late JobsRepository jobs;
        late String jobId;
        late Job businessBefore;
        await tester.runAsync(() async {
          await installation.start(original);
          await original.settingsDao.setSetting('marker', 'local-shop');
          jobs = JobsRepository(
            original,
            await original.settingsDao.ensureDeviceId(),
          );
          jobId = await jobs.createJob('Existing offline job');
          businessBefore = (await jobs.getJob(jobId))!;
        });
        final identity = installation.identity!;
        final binding = await tester.runAsync(
          () => original.settingsDao.getSetting(kInstallationBindingKey),
        );
        final protectedBefore = jsonDecode(
          utf8.decode(store.states[installation.namespace]!.bytes),
        ) as Map<String, dynamic>;
        await _mount(
          tester,
          original,
          installation: installation,
          reset: LocalDataReset(
            supportDir: support,
            documentsDir: documents,
            photosDir: photos,
          ),
          reopenDatabase: () => replacement = _ObservedDatabase(file),
        );
        final scope = tester.widget<AppScope>(find.byType(AppScope));
        final payload = BackupPayload(
          sourceDeviceId: 'synthetic-source',
          createdAt: DateTime.utc(2026, 10, 20),
          sqliteBytes: (await tester.runAsync(
            () => sqliteBytesWithSetting(key: 'marker', value: 'restored-shop'),
          ))!,
          photos: const {},
        );
        final closeFailure = StateError('Synthetic restore close failure');
        ProtectedInstallationState? pending;
        original.beforeClose = () async {
          original.beforeClose = null;
          final current = store.states[installation.namespace]!;
          final record =
              jsonDecode(utf8.decode(current.bytes)) as Map<String, dynamic>;
          expect(record['activation'], 'pending');
          expect(record['previousStore'], protectedBefore['store']);
          record['floors'] = {
            'authority.test-company': 8,
            'revocation.test-device': 12,
          };
          await store.compareAndSwapState(
            installation.namespace,
            expectedRevision: current.revision,
            nextRevision: 'synthetic-floors-after-restore-intent',
            bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
          );
          pending = store.states[installation.namespace]!;
          if (!retainedBinding) {
            await original.settingsDao.setSetting(
              kInstallationBindingKey,
              'synthetic-unproven-binding',
            );
          }
          if (!closedBeforeFailure) throw closeFailure;
        };
        if (closedBeforeFailure) {
          original.afterClose = () async => throw closeFailure;
        }
        await tester.runAsync(
          () => expectLater(
            scope.restoreFromPayload!(payload),
            throwsA(same(closeFailure)),
          ),
        );
        await tester.pumpAndSettle();
        expect(original.closeCalls, 1);
        if (closedBeforeFailure) {
          expect(original.closed, isTrue);
          expect(replacement, isNull);
          expect(
            tester.widget<AppScope>(find.byType(AppScope)).db,
            same(original),
          );
          expect(store.states[installation.namespace], same(pending));
          final retained =
              jsonDecode(utf8.decode(pending!.bytes)) as Map<String, dynamic>;
          expect(retained['activation'], 'pending');
          expect(retained['previousStore'], protectedBefore['store']);
          expect(retained['floors'], {
            'authority.test-company': 8,
            'revocation.test-device': 12,
          });
          expect(installation.readiness, InstallationReadiness.needsRecovery);
          expect(installation.canUseCompanyOperations, isFalse);
          expect(BackupIo.isBusy, isFalse);
          await tester.pumpWidget(const SizedBox.shrink());
          return;
        }
        expect(original.closed, isFalse);
        expect(replacement, isNull);
        expect(
          tester.widget<AppScope>(find.byType(AppScope)).db,
          same(original),
        );
        expect(
          await tester.runAsync(
            () => original.settingsDao.getSetting('marker'),
          ),
          'local-shop',
        );
        expect(
          await tester.runAsync(original.settingsDao.ensureDeviceId),
          scope.deviceId,
        );
        final retainedJob = await tester.runAsync(() => jobs.getJob(jobId));
        expect(retainedJob, businessBefore);
        expect(retainedJob!.name, 'Existing offline job');
        final protectedAfter = jsonDecode(
          utf8.decode(store.states[installation.namespace]!.bytes),
        ) as Map<String, dynamic>;
        for (final key in ['id', 'generation', 'key', 'public']) {
          expect(protectedAfter[key], protectedBefore[key], reason: key);
        }
        expect(
          protectedAfter['seed'] == protectedBefore['seed'],
          isTrue,
          reason: 'Protected signing material is retained',
        );
        expect(protectedAfter['floors'], {
          'authority.test-company': 8,
          'revocation.test-device': 12,
        });
        expect(installation.identity!.id, identity.id);
        expect(installation.identity!.publicKey, identity.publicKey);
        expect(BackupIo.isBusy, isFalse);
        if (retainedBinding) {
          expect(protectedAfter['activation'], 'active');
          expect(protectedAfter['previousStore'], isNull);
          expect(protectedAfter['store'], protectedBefore['store']);
          expect(installation.readiness, InstallationReadiness.ready);
          expect(installation.knownSecurityFloors, protectedAfter['floors']);
          expect(
            await tester.runAsync(
              () => original.settingsDao.getSetting(kInstallationBindingKey),
            ),
            binding,
          );
          await tester.runAsync(() => scope.restoreFromPayload!(payload));
          await tester.pumpAndSettle();
          final live = tester.widget<AppScope>(find.byType(AppScope)).db;
          expect(live, same(replacement));
          expect(original.closed, isTrue);
          expect(original.closeCalls, 2);
          expect(
            await tester.runAsync(() => live.settingsDao.getSetting('marker')),
            'restored-shop',
          );
          expect(installation.readiness, InstallationReadiness.ready);
          expect(installation.identity!.id, identity.id);
          expect(installation.identity!.publicKey, identity.publicKey);
          expect(installation.knownSecurityFloors, protectedAfter['floors']);
        } else {
          expect(store.states[installation.namespace], same(pending));
          expect(protectedAfter['activation'], 'pending');
          expect(protectedAfter['previousStore'], protectedBefore['store']);
          expect(installation.readiness, InstallationReadiness.needsRecovery);
          expect(installation.canUseCompanyOperations, isFalse);
          await tester.runAsync(
            () => expectLater(
              scope.restoreFromPayload!(payload),
              throwsA(isA<StateError>()),
            ),
          );
          expect(original.closeCalls, 1);
          expect(store.states[installation.namespace], same(pending));
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'reset before-close failure retains the original identity and permits retry',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('wp-reset-close-');
      final support = Directory(p.join(root.path, 'support'))..createSync();
      final documents = Directory(p.join(root.path, 'documents'))..createSync();
      final photos = Directory(p.join(support.path, 'part_photos'))
        ..createSync();
      final photo = File(p.join(photos.path, 'retained.jpg'))
        ..writeAsStringSync('synthetic existing photo');
      final file = File(p.join(support.path, kSqliteFileName));
      final original = _ObservedDatabase(file);
      _ObservedDatabase? replacement;
      addTearDown(() async {
        await original.cleanUp();
        await replacement?.cleanUp();
        root.deleteSync(recursive: true);
      });
      final store = JobTestStore();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.reset-close',
      );
      late Job businessBefore;
      late DeviceProfile profileBefore;
      late String jobId;
      late JobsRepository jobs;
      await tester.runAsync(() async {
        await installation.start(original);
        await original.settingsDao.setSetting('marker', 'local-shop');
        jobs = JobsRepository(
          original,
          await original.settingsDao.ensureDeviceId(),
        );
        jobId = await jobs.createJob('Existing offline job');
        businessBefore = (await jobs.getJob(jobId))!;
        profileBefore = await original
            .select(original.deviceProfiles)
            .getSingle();
      });
      final protectedBefore = jsonDecode(
        utf8.decode(store.states[installation.namespace]!.bytes),
      ) as Map<String, dynamic>;
      final bindingBefore = await tester.runAsync(
        () => original.settingsDao.getSetting(kInstallationBindingKey),
      );
      await _mount(
        tester,
        original,
        installation: installation,
        reset: LocalDataReset(
          supportDir: support,
          documentsDir: documents,
          photosDir: photos,
        ),
        reopenDatabase: () => replacement = _ObservedDatabase(file),
      );
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      final closeFailure = StateError('Synthetic reset close failure');
      original.beforeClose = () async {
        original.beforeClose = null;
        final current = store.states[installation.namespace]!;
        final record =
            jsonDecode(utf8.decode(current.bytes)) as Map<String, dynamic>;
        expect(installation.readiness, InstallationReadiness.needsRecovery);
        record['floors'] = {
          'authority.test-company': 8,
          'revocation.test-device': 12,
        };
        await store.compareAndSwapState(
          installation.namespace,
          expectedRevision: current.revision,
          nextRevision: 'synthetic-reset-newer-floors',
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
        );
        throw closeFailure;
      };
      await tester.runAsync(
        () => expectLater(scope.wipeLocalData(), throwsA(same(closeFailure))),
      );
      await tester.pumpAndSettle();
      expect(original.closed, isFalse);
      expect(original.closeCalls, 1);
      expect(replacement, isNull);
      expect(tester.widget<AppScope>(find.byType(AppScope)).db, same(original));
      expect(BackupIo.isBusy, isFalse);
      expect(await tester.runAsync(() => jobs.getJob(jobId)), businessBefore);
      expect(photo.readAsStringSync(), 'synthetic existing photo');
      expect(
        await tester.runAsync(original.settingsDao.ensureDeviceId),
        scope.deviceId,
      );
      expect(
        await tester.runAsync(
          () => original.settingsDao.getSetting(kInstallationBindingKey),
        ),
        bindingBefore,
      );
      expect(
        await tester.runAsync(
          () => original.select(original.deviceProfiles).getSingle(),
        ),
        profileBefore,
      );
      expect(installation.readiness, InstallationReadiness.ready);
      final protectedAfter = jsonDecode(
        utf8.decode(store.states[installation.namespace]!.bytes),
      ) as Map<String, dynamic>;
      for (final key in ['id', 'generation', 'key', 'public', 'store']) {
        expect(protectedAfter[key], protectedBefore[key], reason: key);
      }
      expect(protectedAfter['seed'] == protectedBefore['seed'], isTrue);
      expect(protectedAfter['activation'], protectedBefore['activation']);
      expect(protectedAfter['floors'], {
        'authority.test-company': 8,
        'revocation.test-device': 12,
      });
      await tester.runAsync(scope.wipeLocalData);
      await tester.pumpAndSettle();
      final live = tester.widget<AppScope>(find.byType(AppScope));
      expect(live.db, same(replacement));
      expect(installation.readiness, InstallationReadiness.ready);
      expect(installation.identity!.id.value, isNot(protectedBefore['id']));
      expect(installation.knownSecurityFloors, protectedAfter['floors']);
      expect(photo.existsSync(), isFalse);
      expect(
        await tester.runAsync(() => live.db.settingsDao.getSetting('marker')),
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in [
    'after-close',
    'preflight',
    'partial',
    'preflight-cleanup',
    'preflight-marker',
    'preflight-missing-live',
    'preflight-gate-error',
  ]) {
    testWidgets(
      'reset $mode failure preserves the primary error and correct fence',
      (tester) async {
        final root = Directory.systemTemp.createTempSync('wp-reset-phase-');
        final support = Directory(p.join(root.path, 'support'))..createSync();
        final documents = Directory(p.join(root.path, 'documents'))
          ..createSync();
        final file = File(p.join(support.path, kSqliteFileName));
        final photo = File(p.join(support.path, 'part_photos', 'kept.jpg'));
        photo.parent.createSync();
        photo.writeAsStringSync('existing photo');
        final staging = Directory(p.join(support.path, kRestoreStagingName))
          ..createSync();
        final staged = File(p.join(staging.path, 'kept.txt'))
          ..writeAsStringSync('staged data');
        final hasMarker = [
          'after-close',
          'partial',
          'preflight-marker',
        ].contains(mode);
        final marker = File(p.join(support.path, kRestoreSwapMarkerName));
        if (hasMarker) marker.writeAsStringSync('restore marker');
        final backup = File(p.join(support.path, kSqliteRestoreBakName))
          ..writeAsStringSync('backup data');
        final original = _ObservedDatabase(file);
        final handles = <_ObservedDatabase>[original];
        addTearDown(() async {
          for (final db in handles) {
            await db.cleanUp();
          }
          root.deleteSync(recursive: true);
        });
        final store = JobTestStore();
        final installation = InstallationSecurity(
          store: store,
          namespace: 'synthetic.reset-phase',
        );
        late Job oldJob;
        late String oldBinding;
        late String device;
        await tester.runAsync(() async {
          await installation.start(original);
          device = await original.settingsDao.ensureDeviceId();
          final jobs = JobsRepository(original, device);
          final id = await jobs.createJob('Retained phase job');
          oldJob = (await jobs.getJob(id))!;
          oldBinding = (await original.settingsDao.getSetting(
            kInstallationBindingKey,
          ))!;
          final docs = _ObservedDatabase(
            File(p.join(documents.path, kSqliteFileName)),
          );
          await docs.settingsDao.setSetting('marker', 'Documents old shop');
          await docs.close();
        });
        final documentsFile = File(p.join(documents.path, kSqliteFileName));
        final documentsBefore = documentsFile.readAsBytesSync();
        Uint8List? sqliteBefore;
        final before = jsonDecode(
          utf8.decode(store.states[installation.namespace]!.bytes),
        ) as Map;
        final io = _ResetFailureIo(
          file.path,
          preflight: mode.startsWith('preflight'),
          failReopenCheck: mode == 'preflight-gate-error',
        );
        final closeError = StateError('SQLite closed before reporting failure');
        original.afterClose = () async {
          sqliteBefore = file.readAsBytesSync();
          if (mode == 'preflight-missing-live') file.deleteSync();
          io.armed = true;
          if (mode == 'after-close') throw closeError;
        };
        var reopens = 0;
        _ObservedDatabase? replacement;
        await _mount(
          tester,
          original,
          installation: installation,
          reset: LocalDataReset(supportDir: support, documentsDir: documents),
          reopenDatabase: () {
            reopens++;
            final db = mode == 'preflight-cleanup'
                ? _ObservedDatabase.failOnOpen()
                : _ObservedDatabase(
                    resolveSqliteFile(
                      supportDir: support,
                      documentsDir: documents,
                    ),
                  );
            if (mode == 'preflight-cleanup') {
              db.beforeClose = () async =>
                  throw StateError('cleanup also failed');
            }
            handles.add(db);
            return replacement = db;
          },
        );
        final scope = tester.widget<AppScope>(find.byType(AppScope));
        await tester.runAsync(
          () => IOOverrides.runWithIOOverrides(
            () => expectLater(
              scope.wipeLocalData(),
              throwsA(same(mode == 'after-close' ? closeError : io.error)),
            ),
            io,
          ),
        );
        await tester.pumpAndSettle();
        expect(original.closed, isTrue);
        expect(original.closeCalls, 1);
        expect(BackupIo.isBusy, isFalse);
        expect(photo.readAsStringSync(), 'existing photo');
        final knownNoEffect = mode == 'preflight';
        expect(
          reopens,
          ['preflight', 'preflight-cleanup'].contains(mode) ? 1 : 0,
        );
        expect(staged.existsSync(), mode != 'partial');
        expect(marker.existsSync(), hasMarker && mode != 'partial');
        if (marker.existsSync()) {
          expect(marker.readAsStringSync(), 'restore marker');
        }
        if (staged.existsSync()) {
          expect(staged.readAsStringSync(), 'staged data');
        }
        if (backup.existsSync()) {
          expect(backup.readAsStringSync(), 'backup data');
        }
        expect(documentsFile.readAsBytesSync(), documentsBefore);
        if (mode == 'preflight-missing-live') {
          expect(file.existsSync(), isFalse);
        } else {
          expect(file.readAsBytesSync(), sqliteBefore);
        }
        expect(backup.existsSync(), mode != 'partial');
        expect(
          File(p.join(documents.path, kSqliteFileName)).existsSync(),
          isTrue,
        );
        final after = jsonDecode(
          utf8.decode(store.states[installation.namespace]!.bytes),
        ) as Map;
        for (final key in [
          'id',
          'generation',
          'key',
          'public',
          'seed',
          'floors',
        ]) {
          expect(after[key], before[key], reason: key);
        }
        if (knownNoEffect) {
          expect(installation.readiness, InstallationReadiness.ready);
          expect(after['store'], before['store']);
          expect(after['previousStore'], isNull);
          final live = tester.widget<AppScope>(find.byType(AppScope));
          expect(live.db, same(replacement));
          await tester.runAsync(() async {
            expect(
              await live.db.settingsDao.getSetting(kInstallationBindingKey),
              oldBinding,
            );
            expect(
              await JobsRepository(live.db, device).getJob(oldJob.id),
              oldJob,
            );
            expect(await live.db.settingsDao.ensureDeviceId(), device);
            await live.wipeLocalData();
          });
          await tester.pumpAndSettle();
          expect(installation.readiness, InstallationReadiness.ready);
          expect(installation.identity!.id.value, isNot(before['id']));
          expect(
            base64Encode(installation.identity!.publicKey),
            isNot(before['public']),
          );
          expect(photo.existsSync(), isFalse);
          expect(staged.existsSync(), isFalse);
          expect(
            File(p.join(documents.path, kSqliteFileName)).existsSync(),
            isFalse,
          );
          expect(reopens, 2);
        } else {
          expect(after['activation'], 'needsRecovery');
          expect(after['previousStore'], before['store']);
          expect(after['store'], isNot(before['store']));
          expect(installation.readiness, InstallationReadiness.needsRecovery);
          expect(
            tester.widget<AppScope>(find.byType(AppScope)).db,
            same(original),
          );
          expect(
            tester
                .widget<AbsorbPointer>(find.byType(AbsorbPointer).first)
                .absorbing,
            isTrue,
          );
          await expectLater(
            scope.wipeLocalData(),
            throwsA(isA<RestoreBusyException>()),
          );
          final inspected = mode == 'preflight-missing-live'
              ? _ObservedDatabase()
              : _ObservedDatabase(file);
          handles.add(inspected);
          await tester.runAsync(() async {
            if (mode != 'preflight-missing-live') {
              expect(
                await inspected.settingsDao.getSetting(kInstallationBindingKey),
                oldBinding,
              );
              expect(
                await JobsRepository(inspected, device).getJob(oldJob.id),
                oldJob,
              );
            }
            final restarted = InstallationSecurity(
              store: store,
              namespace: installation.namespace,
            );
            await restarted.start(inspected);
            expect(restarted.readiness, InstallationReadiness.needsRecovery);
            await expectLater(
              restarted.prepareReset(inspected),
              throwsStateError,
            );
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('exit during restore is cancelled without closing storage', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    final gate = Completer<void>();
    await _mount(tester, db, beforeRestore: () => gate.future);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final restore = scope.restoreFromBackup([1], 'invalid-development-archive');
    await tester.pump();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(db.closeCalls, 0);
    gate.complete();
    await expectLater(restore, throwsA(isA<BackupFormatException>()));
    expect(
      await tester.runAsync(db.settingsDao.ensureDeviceId),
      scope.deviceId,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('exit during backup is cancelled without closing storage', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    expect(BackupIo.tryStart(), isTrue);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(db.closeCalls, 0);
    BackupIo.end();
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.exit,
    );
    expect(db.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed database close cancels exit and permits a fresh retry', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    db.failNextClose = true;
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.cancel,
    );
    expect(db.closed, isFalse);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    await expectLater(
      scope.wipeLocalData(),
      throwsA(isA<RestoreBusyException>()),
    );
    await tester.pump();
    expect(
      find.textContaining('Could not close local storage'),
      findsOneWidget,
    );
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.exit,
    );
    expect(db.closed, isTrue);
    expect(db.closeCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('timed out exit retains the one pending shutdown for retry', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    db.closeGate = Completer<void>();
    final first = tester.binding.handleRequestAppExit();
    await tester.pump(const Duration(seconds: 6));
    expect(await first, AppExitResponse.cancel);
    expect(db.closeCalls, 1);
    final second = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(db.closeCalls, 1);
    db.closeGate!.complete();
    expect(await tester.runAsync(() => second), AppExitResponse.exit);
    expect(db.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final surface in ['route', 'dialog']) {
    testWidgets('shutdown blocks buttons and keyboard on an open $surface', (
      tester,
    ) async {
      final db = _ObservedDatabase();
      addTearDown(db.cleanUp);
      await _mount(tester, db);
      final text = TextEditingController(text: 'original');
      addTearDown(text.dispose);
      var writes = 0;
      final editor = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(key: const ValueKey('synthetic-editor'), controller: text),
          FilledButton(
            onPressed: () => writes++,
            child: const Text('Write synthetic change'),
          ),
        ],
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      if (surface == 'route') {
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => Scaffold(body: editor)),
          ),
        );
      } else {
        unawaited(
          showDialog<void>(
            context: navigator.context,
            builder: (_) => AlertDialog(content: editor),
          ),
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('synthetic-editor')));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      db.closeGate = Completer<void>();
      db.failNextClose = true;
      final exit = tester.binding.handleRequestAppExit();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.tap(
        find.text('Write synthetic change'),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(writes, 0);
      db.closeGate!.complete();
      expect(await tester.runAsync(() => exit), AppExitResponse.cancel);
      await tester.pump();
      await tester.tap(
        find.text('Write synthetic change'),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(writes, 0);
      expect(text.text, 'original');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed replacement initialization closes the unbound database', (
    tester,
  ) async {
    final original = _ObservedDatabase();
    final next = _ObservedDatabase.failOnOpen();
    var reopenCalls = 0;
    addTearDown(original.cleanUp);
    addTearDown(next.cleanUp);
    await _mount(
      tester,
      original,
      reset: _ControlledReset(),
      reopenDatabase: () {
        reopenCalls++;
        return next;
      },
    );
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    await tester.runAsync(
      () => expectLater(scope.wipeLocalData(), throwsA(isA<StateError>())),
    );
    expect(reopenCalls, 1);
    expect(original.closed, isTrue);
    expect(original.closeCalls, 1);
    expect(next.closed, isTrue);
    expect(next.closeCalls, 1);
    expect(tester.widget<AppScope>(find.byType(AppScope)).db, same(original));
    expect(BackupIo.isBusy, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unknown file wipe failure blocks editing and retry without reopening',
    (tester) async {
      final original = _ObservedDatabase();
      final next = _ObservedDatabase();
      final failure = StateError('Synthetic file wipe failure');
      var reopenCalls = 0;
      addTearDown(original.cleanUp);
      addTearDown(next.cleanUp);
      await _mount(
        tester,
        original,
        reset: _FailingReset(failure),
        reopenDatabase: () {
          reopenCalls++;
          return next;
        },
      );
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      await tester.runAsync(
        () => expectLater(scope.wipeLocalData(), throwsA(same(failure))),
      );
      await tester.pumpAndSettle();
      expect(reopenCalls, 0);
      expect(original.closed, isTrue);
      expect(original.closeCalls, 1);
      expect(next.closeCalls, 0);
      expect(tester.widget<AppScope>(find.byType(AppScope)).db, same(original));
      expect(
        tester
            .widget<AbsorbPointer>(find.byType(AbsorbPointer).first)
            .absorbing,
        isTrue,
      );
      await expectLater(
        scope.wipeLocalData(),
        throwsA(isA<RestoreBusyException>()),
      );
      expect(BackupIo.isBusy, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unmounted wipe closes the newly opened replacement once', (
    tester,
  ) async {
    final original = _ObservedDatabase();
    final next = _ObservedDatabase();
    addTearDown(original.cleanUp);
    addTearDown(next.cleanUp);
    final gate = Completer<void>();
    await _mount(
      tester,
      original,
      reset: _ControlledReset(gate),
      reopenDatabase: () => next,
    );
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final wipe = scope.wipeLocalData();
    await tester.pumpAndSettle();
    expect(original.closed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.runAsync(() => wipe);
    expect(next.closed, isTrue);
    expect(next.closeCalls, 1);
    expect(BackupIo.isBusy, isFalse);
  });
}

final class _ResetFailureIo extends IOOverrides {
  _ResetFailureIo(
    this.sqlitePath, {
    required this.preflight,
    this.failReopenCheck = false,
  });
  final String sqlitePath;
  final bool preflight;
  final bool failReopenCheck;
  final error = const FileSystemException('Synthetic base reset IO failure');
  bool armed = false;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == sqlitePath ||
            (failReopenCheck && p.basename(path) == kRestoreSwapMarkerName)
        ? _ResetFailureFile(file, this)
        : file;
  }
}

final class _ResetFailureFile implements File {
  _ResetFailureFile(this.file, this.io);
  final File file;
  final _ResetFailureIo io;

  @override
  String get path => file.path;

  @override
  Directory get parent => file.parent;

  @override
  bool existsSync() {
    if (io.armed && io.preflight) {
      io.armed = false;
      throw io.error;
    }
    return file.existsSync();
  }

  @override
  Future<bool> exists() async {
    if (io.failReopenCheck && p.basename(path) == kRestoreSwapMarkerName) {
      throw const FileSystemException(
        'Synthetic reopen eligibility read failure',
      );
    }
    return file.exists();
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (io.armed && !io.preflight) throw io.error;
    return file.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
