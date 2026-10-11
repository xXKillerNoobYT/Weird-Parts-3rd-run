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
import 'package:wired_parts/features/reset/local_data_reset.dart';

class FakeSecureStore implements InstallationSecureStore {
  final states = <String, ProtectedInstallationState>{};
  bool failNextWrite = false;
  bool failReads = false;
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
    if (failNextWrite) {
      failNextWrite = false;
      throw PlatformException(code: 'installation_unavailable');
    }
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

  test('reset rotates identity, retains floors and requires the new database binding', () async {
    final store = FakeSecureStore();
    final directory = temporary();
    final db = open(directory);
    final service = security(store);
    await service.start(db);
    final oldIdentity = service.identity!.id;
    await addSecurityFloor(store, service, db);
    await service.prepareReset();
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
    await service.completeReset(next);
    expect(service.readiness, InstallationReadiness.ready);
    expect(service.identity!.id, isNot(oldIdentity));
    expect(
      jsonDecode(
        utf8.decode(store.states[service.namespace]!.bytes),
      )['floors']['authority.test-company'],
      7,
    );
  });

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
