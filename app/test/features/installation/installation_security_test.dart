import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

class FakeSecureStore implements InstallationSecureStore {
  final states = <String, ProtectedInstallationState>{};
  bool failNextWrite = false;
  bool failReads = false;
  int writeCalls = 0;
  Future<void> Function(String namespace, Uint8List bytes)? beforeCas;
  @override
  Future<ProtectedInstallationState?> readState(String namespace) async {
    if (failReads) throw PlatformException(code: 'installation_unavailable');
    return states[namespace];
  }

  @override
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  }) async {
    writeCalls++;
    if (failNextWrite) {
      failNextWrite = false;
      throw PlatformException(code: 'installation_unavailable');
    }
    await beforeCas?.call(namespace, bytes);
    final existing = states[namespace];
    if (existing?.revision == nextRevision) {
      if (base64Encode(existing!.bytes) != base64Encode(bytes)) {
        throw PlatformException(code: 'installation_integrity');
      }
      return nextRevision;
    }
    if (existing?.revision != expectedRevision) {
      throw PlatformException(code: 'installation_conflict');
    }
    states[namespace] = ProtectedInstallationState(nextRevision, bytes);
    return nextRevision;
  }
}

AppDatabase open(Directory directory) => AppDatabase.forTesting(
  NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
);

Directory temporary() {
  final directory = Directory.systemTemp.createTempSync('wp-identity-');
  addTearDown(() => directory.deleteSync(recursive: true));
  return directory;
}

InstallationSecurity security(
  FakeSecureStore store, [
  String namespace = 'synthetic.recipient',
]) => InstallationSecurity(store: store, namespace: namespace);

Future<void> addSecurityFloor(
  FakeSecureStore store,
  InstallationSecurity service,
  AppDatabase db,
) async {
  final current = store.states[service.namespace]!;
  final record = jsonDecode(utf8.decode(current.bytes)) as Map<String, dynamic>;
  record['floors'] = {
    'authority.test-company': 7,
    'revocation.test-device': 11,
  };
  await store.compareAndSwapState(
    service.namespace,
    expectedRevision: current.revision,
    nextRevision: const Uuid().v4(),
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
  );
  await service.reconcile(db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final unreadable in [false, true]) {
    testWidgets(
      'Documents ${unreadable ? 'unreadable database' : 'company history'} refuses app reset before identity or files change',
      (tester) async {
        final directory = temporary();
        final documents = temporary();
        final db = open(directory);
        final legacy = open(documents);
        final store = FakeSecureStore();
        final local = security(store);
        late String id;
        await tester.runAsync(() async {
          await legacy
              .into(legacy.companyAuthorityFacts)
              .insert(
                CompanyAuthorityFactsCompanion.insert(
                  companyId: 'synthetic-company',
                  commitment: 'synthetic-facts',
                  signedBytes: 'synthetic-signed-facts',
                ),
              );
          await legacy.close();
          if (unreadable) {
            File(p.join(documents.path, kSqliteFileName))
                .writeAsStringSync('unreadable sqlite');
          }
          await local.start(db);
          await db.settingsDao.setSetting('marker', 'preserve');
          id = await db.settingsDao.ensureDeviceId();
          await db.settingsDao.setDeviceDisplayName('Preserve profile');
          await checkpointWalForExport(db);
        });
        final photos = Directory(p.join(directory.path, 'part_photos'))
          ..createSync();
        File(p.join(photos.path, 'keep.jpg'))
            .writeAsStringSync('preserve photo');
        Future<Map<String, Object?>> rows(AppDatabase database) async => {
          for (final table in database.allTables)
            table.actualTableName:
                (await database
                        .customSelect('SELECT * FROM ${table.actualTableName}')
                        .get())
                    .map((r) => jsonEncode(r.data))
                    .toList()
                  ..sort(),
        };
        final beforeRows = await tester.runAsync(() => rows(db));
        final protected = store.states[local.namespace]!;
        final writes = store.writeCalls;
        final identity = local.identity;
        final files = <String, List<int>>{};
        for (final root in [directory, documents]) {
          for (final file in root.listSync(recursive: true).whereType<File>()) {
            files[file.path] = file.readAsBytesSync();
          }
        }
        var reopens = 0;
        await tester.pumpWidget(
          WiredPartsApp(
            db: db,
            pin: PinService(db.settingsDao),
            deviceId: id,
            installation: local,
            reset: LocalDataReset(
              supportDir: directory,
              documentsDir: documents,
            ),
            reopenDatabase: () {
              reopens++;
              return open(directory);
            },
          ),
        );
        await tester.pumpAndSettle();
        final scope = tester.widget<AppScope>(find.byType(AppScope));
        await tester.runAsync(
          () => expectLater(
            scope.wipeLocalData(),
            unreadable
                ? throwsA(isA<SqliteException>())
                : throwsA(isA<BackupFormatException>()),
          ),
        );
        await tester.pumpAndSettle();
        final live = tester.widget<AppScope>(find.byType(AppScope)).db;
        final afterRows = await tester.runAsync(() => rows(live));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(live.close);
        expect(store.states[local.namespace], same(protected));
        expect(store.states[local.namespace]!.revision, protected.revision);
        expect(store.states[local.namespace]!.bytes, protected.bytes);
        expect(store.writeCalls, writes);
        expect(local.identity, same(identity));
        expect(local.readiness, InstallationReadiness.ready);
        expect(reopens, 0);
        expect(live, same(db));
        expect(afterRows, beforeRows);
        for (final entry in files.entries) {
          // WAL/SHM lifecycle is owned by SQLite; compare persistent files after close.
          if (entry.key.endsWith('-wal') || entry.key.endsWith('-shm')) {
            continue;
          }
          expect(
            File(entry.key).readAsBytesSync(),
            entry.value,
            reason: entry.key,
          );
        }
        expect(BackupIo.isBusy, isFalse);
      },
    );
  }

  testWidgets(
    'legacy app reset removes files and activates a fresh bound identity',
    (tester) async {
      final directory = temporary();
      final documents = temporary();
      final db = open(directory);
      final legacy = open(documents);
      final store = FakeSecureStore();
      final local = security(store);
      late String oldDeviceId;
      await tester.runAsync(() async {
        await legacy.settingsDao.setSetting('marker', 'Documents legacy');
        await legacy.close();
        await local.start(db);
        await addSecurityFloor(store, local, db);
        oldDeviceId = await db.settingsDao.ensureDeviceId();
        await db.settingsDao.setSetting('marker', 'Support legacy');
      });
      final previous = store.states[local.namespace]!;
      final oldIdentity = local.identity!.id;
      final photo = File(p.join(directory.path, 'part_photos', 'remove.jpg'));
      photo.parent.createSync();
      photo.writeAsStringSync('remove');
      var reopens = 0;
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: oldDeviceId,
          installation: local,
          reset: LocalDataReset(supportDir: directory, documentsDir: documents),
          reopenDatabase: () {
            reopens++;
            return open(directory);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        tester.widget<AppScope>(find.byType(AppScope)).wipeLocalData,
      );
      await tester.pumpAndSettle();
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      expect(reopens, 1);
      expect(local.readiness, InstallationReadiness.ready);
      expect(local.identity!.id, isNot(oldIdentity));
      expect(store.states[local.namespace]!.revision, isNot(previous.revision));
      expect(scope.deviceId, isNot(oldDeviceId));
      expect(photo.existsSync(), isFalse);
      expect(
        File(p.join(documents.path, kSqliteFileName)).existsSync(),
        isFalse,
      );
      await tester.runAsync(() async {
        expect(await scope.db.settingsDao.getSetting('marker'), isNull);
        final record = jsonDecode(
          utf8.decode(store.states[local.namespace]!.bytes),
        ) as Map;
        final binding = jsonDecode(
          (await scope.db.settingsDao.getSetting(kInstallationBindingKey))!,
        ) as Map;
        expect(binding['id'], record['id']);
        expect(binding['generation'], record['generation']);
        expect(binding['public'], record['public']);
        expect(record['floors']['authority.test-company'], 7);
      });
      expect(BackupIo.isBusy, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(scope.db.close);
    },
  );

  testWidgets(
    'staged restore failure through app callback explicitly retains prior ready identity',
    (tester) async {
      final directory = temporary();
      final sourceDirectory = temporary();
      final source = open(sourceDirectory);
      final db = open(directory);
      final store = FakeSecureStore();
      final local = security(store);
      late BackupPayload payload;
      late InstallationId originalId;
      late String? originalBinding;
      late String id;
      await tester.runAsync(() async {
        await source.settingsDao.ensureDeviceId();
        await source.customStatement('DROP TABLE jobs');
        await source.close();
        payload = BackupPayload(
          createdAt: DateTime.utc(2026),
          sourceDeviceId: 'foreign',
          sqliteBytes: await File(p.join(sourceDirectory.path, kSqliteFileName))
              .readAsBytes(),
          photos: const {},
        );
        await local.start(db);
        originalId = local.identity!.id;
        originalBinding = await db.settingsDao.getSetting(
          kInstallationBindingKey,
        );
        await db.settingsDao.setSetting('marker', 'original');
        id = await db.settingsDao.ensureDeviceId();
      });
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: id,
          installation: local,
          reopenDatabase: () => open(directory),
          reset: LocalDataReset(supportDir: directory, documentsDir: directory),
        ),
      );
      await tester.pumpAndSettle();
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      await tester.runAsync(() async {
        await expectLater(
          scope.restoreFromPayload!(payload),
          throwsA(isA<BackupFormatException>()),
        );
      });
      await tester.pumpAndSettle();
      final nextScope = tester.widget<AppScope>(find.byType(AppScope));
      expect(local.readiness, InstallationReadiness.ready);
      expect(local.identity!.id, originalId);
      await tester.runAsync(() async {
        expect(
          await nextScope.db.settingsDao.getSetting(kInstallationBindingKey),
          originalBinding,
        );
        expect(await nextScope.db.settingsDao.getSetting('marker'), 'original');
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(nextScope.db.close);
    },
  );

  testWidgets(
    'native read outage blocks app restore and reset before business mutation',
    (tester) async {
      final directory = temporary();
      final db = open(directory);
      final store = FakeSecureStore();
      final local = security(store);
      late String id;
      late Uint8List bytes;
      await tester.runAsync(() async {
        await local.start(db);
        await db.settingsDao.setSetting('marker', 'original');
        id = await db.settingsDao.ensureDeviceId();
        await checkpointWalForExport(db);
        bytes = await File(p.join(directory.path, kSqliteFileName))
            .readAsBytes();
      });
      final photo = File(p.join(directory.path, 'keep-photo'))
        ..writeAsStringSync('preserve');
      store.failReads = true;
      await tester.runAsync(() => local.start(db));
      expect(local.readiness, InstallationReadiness.unavailable);
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: id,
          installation: local,
          reopenDatabase: () => open(directory),
          reset: LocalDataReset(supportDir: directory, documentsDir: directory),
        ),
      );
      await tester.pumpAndSettle();
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      final payload = BackupPayload(
        createdAt: DateTime.utc(2026),
        sourceDeviceId: 'foreign',
        sqliteBytes: bytes,
        photos: const {},
      );
      await tester.runAsync(() async {
        await expectLater(scope.restoreFromPayload!(payload), throwsStateError);
        await expectLater(scope.wipeLocalData(), throwsStateError);
      });
      await tester.runAsync(() async {
        expect(await db.settingsDao.getSetting('marker'), 'original');
        expect(await photo.readAsString(), 'preserve');
        expect(
          await File(p.join(directory.path, kSqliteFileName)).readAsBytes(),
          bytes,
        );
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(db.close);
    },
  );

  test('isolated installations differ and restart preserves identity without membership', () async {
    final store = FakeSecureStore();
    final firstDb = open(temporary());
    final secondDb = open(temporary());
    addTearDown(firstDb.close);
    addTearDown(secondDb.close);
    final first = security(store, 'synthetic.first');
    final second = security(store, 'synthetic.second');
    await first.start(firstDb);
    await second.start(secondDb);
    expect(first.readiness, InstallationReadiness.ready);
    expect(first.identity!.publicKey, isNot(second.identity!.publicKey));
    final restarted = security(store, 'synthetic.first');
    await restarted.start(firstDb);
    expect(restarted.identity!.id, first.identity!.id);
    expect(restarted.identity!.publicKey, first.identity!.publicKey);
    expect(restarted.canUseCompanyOperations, isFalse);
  });

  for (final foreign in [false, true]) {
    test(
      '${foreign ? 'foreign' : 'same-install stale'} restore retains key and security floors with new receiving generation',
      () async {
        final sourceDir = temporary();
        final recipientDir = temporary();
        final store = FakeSecureStore();
        final source = open(sourceDir);
        final recipient = open(recipientDir);
        final local = security(store);
        await local.start(recipient);
        final localId = local.identity!.id;
        final localKey = Uint8List.fromList(local.identity!.publicKey);
        final oldBinding = await recipient.settingsDao.getSetting(
          kInstallationBindingKey,
        );
        final sourceSecurity = foreign
            ? security(store, 'synthetic.sender')
            : local;
        if (foreign) {
          await sourceSecurity.start(source);
        } else {
          await source.settingsDao.setSetting(
            kInstallationBindingKey,
            oldBinding!,
          );
        }
        final sourceDevice = await source.settingsDao.ensureDeviceId();
        await source.settingsDao.setSetting('marker', 'snapshot-business-data');
        await source.close();
        final payload = await BackupStore(supportDir: sourceDir).collect(
          sourceDeviceId: sourceDevice,
          createdAt: DateTime.utc(2026, 10, 11),
          sqliteBytes: await File(p.join(sourceDir.path, kSqliteFileName))
              .readAsBytes(),
        );
        expect(
          utf8.decode(payload.sqliteBytes, allowMalformed: true),
          isNot(contains(kInstallationBindingKey)),
        );
        final nativeBefore = jsonDecode(
          utf8.decode(store.states[local.namespace]!.bytes),
        ) as Map<String, dynamic>;
        expect(
          utf8.decode(payload.sqliteBytes, allowMalformed: true),
          isNot(contains(nativeBefore['seed'] as String)),
        );
        await addSecurityFloor(store, local, recipient);
        final recipientDevice = await recipient.settingsDao.ensureDeviceId();
        final profile = await recipient
            .select(recipient.deviceProfiles)
            .getSingle();
        final intent = await local.prepareBusinessRestore(recipient);
        await recipient.close();
        await BackupStore(supportDir: recipientDir).replaceWithPayload(
          payload: payload,
          localDeviceProfile: profile,
          localInstallationBinding: intent!.binding,
          reset: LocalDataReset(
            supportDir: recipientDir,
            documentsDir: recipientDir,
          ),
        );
        final next = open(recipientDir);
        addTearDown(next.close);
        final restarted = security(store);
        await restarted.start(next);
        expect(restarted.readiness, InstallationReadiness.ready);
        expect(restarted.identity!.id, localId);
        expect(restarted.identity!.publicKey, localKey);
        expect(await next.settingsDao.ensureDeviceId(), recipientDevice);
        expect(
          await next.settingsDao.getSetting('marker'),
          'snapshot-business-data',
        );
        final newBinding = await next.settingsDao.getSetting(
          kInstallationBindingKey,
        );
        expect(
          jsonDecode(newBinding!)['store'],
          isNot(jsonDecode(oldBinding!)['store']),
        );
        final protected = jsonDecode(
          utf8.decode(store.states[local.namespace]!.bytes),
        );
        expect(protected['floors'], {
          'authority.test-company': 7,
          'revocation.test-device': 11,
        });
        expect(restarted.canUseCompanyOperations, isFalse);
      },
    );
  }

  test('protected restore precommit failure retains original binding and permits retry', () async {
    final store = FakeSecureStore();
    final db = open(temporary());
    addTearDown(db.close);
    final service = security(store);
    await service.start(db);
    final originalId = service.identity!.id;
    final originalKey = Uint8List.fromList(service.identity!.publicKey);
    final originalBinding = await db.settingsDao.getSetting(
      kInstallationBindingKey,
    );
    final originalProtected = store.states[service.namespace]!;
    store.failNextWrite = true;
    await expectLater(
      service.prepareBusinessRestore(db),
      throwsA(isA<PlatformException>()),
    );
    expect(
      await db.settingsDao.getSetting(kInstallationBindingKey),
      originalBinding,
    );
    expect(
      store.states[service.namespace]!.revision,
      originalProtected.revision,
    );
    expect(store.states[service.namespace]!.bytes, originalProtected.bytes);
    expect(service.identity!.id, originalId);
    expect(service.identity!.publicKey, originalKey);
    expect(service.readiness, InstallationReadiness.ready);
    final retry = await service.prepareBusinessRestore(db);
    expect(retry, isNotNull);
    expect(
      jsonDecode(retry!.binding)['store'],
      isNot(jsonDecode(originalBinding!)['store']),
    );
    expect(service.readiness, InstallationReadiness.needsRecovery);
    expect(service.identity!.id, originalId);
  });

  test('failed final activation stays closed until restart proves exact persisted target', () async {
    final store = FakeSecureStore();
    final directory = temporary();
    final db = open(directory);
    final service = security(store);
    await service.start(db);
    final originalId = service.identity!.id;
    final originalKey = Uint8List.fromList(service.identity!.publicKey);
    final intent = await service.prepareBusinessRestore(db);
    await db.settingsDao.setSetting(kInstallationBindingKey, intent!.binding);
    final pending = store.states[service.namespace]!;
    store.failNextWrite = true;
    await expectLater(service.reconcile(db), throwsA(isA<PlatformException>()));
    expect(service.readiness, InstallationReadiness.needsRecovery);
    expect(service.canUseCompanyOperations, isFalse);
    expect(store.states[service.namespace]!.revision, pending.revision);
    expect(
      jsonDecode(
        utf8.decode(store.states[service.namespace]!.bytes),
      )['activation'],
      'pending',
    );
    await db.close();
    final next = open(directory);
    addTearDown(next.close);
    final restarted = security(store);
    await restarted.start(next);
    expect(restarted.readiness, InstallationReadiness.ready);
    expect(restarted.identity!.id, originalId);
    expect(restarted.identity!.publicKey, originalKey);
    expect(
      await next.settingsDao.getSetting(kInstallationBindingKey),
      intent.binding,
    );
    expect(
      jsonDecode(
        utf8.decode(store.states[service.namespace]!.bytes),
      )['activation'],
      'active',
    );
    expect(restarted.canUseCompanyOperations, isFalse);
  });

  test(
    'pending activation never authorizes an old or missing database binding',
    () async {
      final store = FakeSecureStore();
      final directory = temporary();
      final db = open(directory);
      final initial = security(store);
      await initial.start(db);
      await initial.prepareBusinessRestore(db);
      await db.close();
      final next = open(directory);
      addTearDown(next.close);
      final restarted = security(store);
      await restarted.start(next);
      expect(restarted.readiness, InstallationReadiness.needsRecovery);
      expect(restarted.canUseCompanyOperations, isFalse);
      await next.customStatement('DELETE FROM app_settings WHERE key = ?', [
        kInstallationBindingKey,
      ]);
      await restarted.start(next);
      expect(restarted.readiness, InstallationReadiness.needsRecovery);
    },
  );

  test(
    'missing native identity with a database binding never regenerates a key',
    () async {
      final store = FakeSecureStore();
      final db = open(temporary());
      addTearDown(db.close);
      await security(store).start(db);
      store.states.clear();
      final restarted = security(store);
      await restarted.start(db);
      expect(restarted.readiness, InstallationReadiness.needsRecovery);
      expect(store.states, isEmpty);
    },
  );

  test('malformed and unsupported protected state refuses replacement while local jobs remain usable', () async {
    final store = FakeSecureStore();
    final db = open(temporary());
    addTearDown(db.close);
    final initial = security(store);
    await initial.start(db);
    final binding = await db.settingsDao.getSetting(kInstallationBindingKey);
    final original = store.states[initial.namespace]!;
    final record =
        jsonDecode(utf8.decode(original.bytes)) as Map<String, dynamic>;
    final jobs = JobsRepository(db, await db.settingsDao.ensureDeviceId());
    final originalJob = await jobs.createJob('Existing offline job');

    for (final invalid in {
      'malformed JSON': '{',
      'unsupported version': jsonEncode({...record, 'v': 2}),
    }.entries) {
      final corrupted = ProtectedInstallationState(
        original.revision,
        Uint8List.fromList(utf8.encode(invalid.value)),
      );
      store.states[initial.namespace] = corrupted;
      final writesBefore = store.writeCalls;
      final restarted = security(store);
      await restarted.start(db);

      expect(
        restarted.readiness,
        InstallationReadiness.needsRecovery,
        reason: invalid.key,
      );
      expect(restarted.identity, isNull, reason: invalid.key);
      expect(restarted.canUseCompanyOperations, isFalse);
      expect(store.writeCalls, writesBefore);
      expect(store.states[initial.namespace], same(corrupted));
      expect(await db.settingsDao.getSetting(kInstallationBindingKey), binding);
      expect((await jobs.getJob(originalJob))!.name, 'Existing offline job');
      final added = await jobs.createJob('Local job after ${invalid.key}');
      expect(
        (await jobs.getJob(added))!.name,
        'Local job after ${invalid.key}',
      );
      expect(store.writeCalls, writesBefore);
    }
  });

  test('reset rotates identity, retains floors and requires the new database binding', () async {
    final store = FakeSecureStore();
    final directory = temporary();
    final db = open(directory);
    final service = security(store);
    await service.start(db);
    final oldIdentity = service.identity!.id;
    await addSecurityFloor(store, service, db);
    final intent = (await service.prepareReset(db))!;
    await db.close();
    await LocalDataReset(
      supportDir: directory,
      documentsDir: directory,
    ).wipeFiles();
    final next = open(directory);
    addTearDown(next.close);
    final interrupted = security(store);
    await interrupted.start(next);
    expect(interrupted.readiness, InstallationReadiness.needsRecovery);
    await service.completeReset(next, intent);
    expect(service.readiness, InstallationReadiness.ready);
    expect(service.identity!.id, isNot(oldIdentity));
    expect(
      jsonDecode(
        utf8.decode(store.states[service.namespace]!.bytes),
      )['floors']['authority.test-company'],
      7,
    );
  });

  test('reset abort and completion retain current floors without restoring a snapshot', () async {
    final store = FakeSecureStore();
    final directory = temporary();
    final db = open(directory);
    final service = security(store);
    await service.start(db);
    final old = _protectedRecord(store, service);
    _changeProtectedRecord(
      store,
      service,
      (record) => record['floors'] = {'test-floor': 13},
    );
    final first = (await service.prepareReset(db))!;
    expect(_protectedRecord(store, service)['floors'], {'test-floor': 13});
    _changeProtectedRecord(
      store,
      service,
      (record) => record['floors'] = {'test-floor': 21},
    );
    await service.abortReset(db, first);
    expect(service.knownSecurityFloors, {'test-floor': 21});
    expect(service.readiness, InstallationReadiness.ready);
    final retained = _protectedRecord(store, service);
    for (final key in ['id', 'generation', 'key', 'public', 'seed', 'store']) {
      expect(retained[key], old[key], reason: key);
    }
    final second = (await service.prepareReset(db))!;
    final fence = store.states[service.namespace]!;
    final oldBinding = await db.settingsDao.getSetting(kInstallationBindingKey);
    await expectLater(service.validateReset(first), throwsStateError);
    await expectLater(service.abortReset(db, first), throwsStateError);
    await expectLater(service.completeReset(db, first), throwsStateError);
    await expectLater(service.prepareReset(db), throwsStateError);
    expect(store.states[service.namespace]!.bytes, fence.bytes);
    expect(
      await db.settingsDao.getSetting(kInstallationBindingKey),
      oldBinding,
    );
    _changeProtectedRecord(
      store,
      service,
      (record) => record['floors'] = {'test-floor': 34},
    );
    await service.validateReset(second);
    await db.close();
    await LocalDataReset(
      supportDir: directory,
      documentsDir: directory,
    ).wipeFiles();
    final next = open(directory);
    addTearDown(next.close);
    await service.completeReset(next, second);
    expect(service.knownSecurityFloors, {'test-floor': 34});
    expect(service.readiness, InstallationReadiness.ready);
    expect(service.identity!.id.value, isNot(old['id']));
    expect(base64Encode(service.identity!.publicKey), isNot(old['public']));
    final completed = store.states[service.namespace]!;
    final newBinding = await next.settingsDao.getSetting(
      kInstallationBindingKey,
    );
    await expectLater(service.completeReset(next, second), throwsStateError);
    await expectLater(service.abortReset(next, second), throwsStateError);
    expect(store.states[service.namespace]!.bytes, completed.bytes);
    expect(
      await next.settingsDao.getSetting(kInstallationBindingKey),
      newBinding,
    );
  });

  for (final phase in ['prepare', 'abort', 'complete']) {
    test(
      'reset $phase stale CAS preserves competing floors and never writes a binding',
      () async {
        final store = FakeSecureStore();
        final directory = temporary();
        final db = open(directory);
        final service = security(store);
        await service.start(db);
        final before = _protectedRecord(store, service);
        InstallationResetIntent? intent;
        AppDatabase target = db;
        if (phase != 'prepare') intent = (await service.prepareReset(db))!;
        if (phase == 'complete') {
          await db.close();
          await LocalDataReset(
            supportDir: directory,
            documentsDir: directory,
          ).wipeFiles();
          target = open(directory);
        }
        addTearDown(target.close);
        final bindingBefore = await target.settingsDao.getSetting(
          kInstallationBindingKey,
        );
        final recordBefore = _protectedRecord(store, service);
        store.beforeCas = (namespace, bytes) async {
          if (namespace != service.namespace) return;
          store.beforeCas = null;
          _changeProtectedRecord(
            store,
            service,
            (record) => record['floors'] = {'concurrent-floor': 55},
          );
        };
        await expectLater(
          switch (phase) {
            'prepare' => service.prepareReset(target),
            'abort' => service.abortReset(target, intent!),
            _ => service.completeReset(target, intent!),
          },
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'installation_conflict',
            ),
          ),
        );
        final after = _protectedRecord(store, service);
        expect(after['floors'], {'concurrent-floor': 55});
        for (final key in [
          'id',
          'generation',
          'key',
          'public',
          'seed',
          'store',
          'activation',
          'previousStore',
        ]) {
          expect(after[key], recordBefore[key], reason: key);
        }
        expect(after['id'], before['id']);
        expect(
          await target.settingsDao.getSetting(kInstallationBindingKey),
          bindingBefore,
        );
        expect(service.readiness, InstallationReadiness.needsRecovery);
      },
    );
  }

  for (final changed in ['custody', 'trust', 'pending', 'previous-store']) {
    test(
      'reset $changed change refuses validation abort and completion before effects',
      () async {
        final store = FakeSecureStore();
        final directory = temporary();
        final db = open(directory);
        addTearDown(db.close);
        final service = security(store);
        await service.start(db);
        final intent = (await service.prepareReset(db))!;
        final binding = await db.settingsDao.getSetting(
          kInstallationBindingKey,
        );
        if (changed == 'custody') {
          store.states[companyCustodyNamespace(
            service.namespace,
          )] = ProtectedInstallationState(
            const Uuid().v4(),
            Uint8List.fromList([1]),
          );
        } else {
          _changeProtectedRecord(store, service, (record) {
            if (changed == 'previous-store') {
              record['previousStore'] = const Uuid().v4();
              return;
            }
            record['v'] = 2;
            record['storePath'] = 'a' * 64;
            record['companyTrust'] = CompanyTrustAnchor(
              companyId: CompanyId(const Uuid().v4()),
              rootKey: Uint8List(32),
              authorityVersion: 1,
              factsCommitment: 'b' * 64,
              policy: 'localContinuity',
            ).encode();
            record['pendingCommand'] = changed == 'pending'
                ? CompanyCommandIntent(
                    receiptKey: 'c' * 64,
                    operationCommitment: 'd' * 64,
                    commandCommitment: 'e' * 64,
                    storeGeneration: record['store'] as String,
                    companyId: const Uuid().v4(),
                    lineId: const Uuid().v4(),
                    originGeneration: const Uuid().v4(),
                    requestId: const Uuid().v4(),
                  ).encode()
                : null;
          });
        }
        final guarded = store.states[service.namespace]!;
        await expectLater(service.validateReset(intent), throwsStateError);
        await expectLater(service.abortReset(db, intent), throwsStateError);
        await expectLater(service.completeReset(db, intent), throwsStateError);
        expect(store.states[service.namespace]!.bytes, guarded.bytes);
        expect(
          await db.settingsDao.getSetting(kInstallationBindingKey),
          binding,
        );
      },
    );
  }

  test(
    'reset refuses mismatched old binding and nonempty completion target',
    () async {
      final store = FakeSecureStore();
      final directory = temporary();
      final db = open(directory);
      addTearDown(db.close);
      final service = security(store);
      await service.start(db);
      final binding = (await db.settingsDao.getSetting(
        kInstallationBindingKey,
      ))!;
      await db.settingsDao.setSetting(
        kInstallationBindingKey,
        'different binding',
      );
      final active = store.states[service.namespace]!;
      await expectLater(service.prepareReset(db), throwsStateError);
      expect(store.states[service.namespace]!.bytes, active.bytes);
      await db.settingsDao.setSetting(kInstallationBindingKey, binding);
      final intent = (await service.prepareReset(db))!;
      await db.settingsDao.setSetting(
        kInstallationBindingKey,
        'different binding',
      );
      final fenced = store.states[service.namespace]!;
      await expectLater(service.abortReset(db, intent), throwsStateError);
      expect(store.states[service.namespace]!.bytes, fenced.bytes);
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      await other.settingsDao.setSetting('marker', 'unrelated business data');
      await expectLater(service.completeReset(other, intent), throwsStateError);
      expect(store.states[service.namespace]!.bytes, fenced.bytes);
      expect(
        await other.settingsDao.getSetting(kInstallationBindingKey),
        isNull,
      );
      expect(
        await other.settingsDao.getSetting('marker'),
        'unrelated business data',
      );
    },
  );

  test('invalid namespaces cannot fall back to production', () {
    for (final namespace in [
      '',
      'synthetic.',
      'synthetic../escape',
      'Synthetic.test',
      'synthetic.${'a' * 64}',
    ]) {
      expect(() => security(FakeSecureStore(), namespace), throwsArgumentError);
    }
  });
}

Map<String, dynamic> _protectedRecord(
  FakeSecureStore store,
  InstallationSecurity service,
) =>
    jsonDecode(utf8.decode(store.states[service.namespace]!.bytes))
        as Map<String, dynamic>;

void _changeProtectedRecord(
  FakeSecureStore store,
  InstallationSecurity service,
  void Function(Map<String, dynamic>) change,
) {
  final record = _protectedRecord(store, service);
  change(record);
  store.states[service.namespace] = ProtectedInstallationState(
    const Uuid().v4(),
    Uint8List.fromList(utf8.encode(jsonEncode(record))),
  );
}
