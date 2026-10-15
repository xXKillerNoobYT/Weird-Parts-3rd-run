import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

String _canonical(Object? value) {
  Object? sorted(Object? item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(item[key])};
    }
    if (item is List) return item.map(sorted).toList();
    return item;
  }

  return jsonEncode(sorted(value));
}

Future<Uint8List> _resignEncryptedFirstOwnerPackage({
  required Uint8List original,
  required String passphrase,
  required _MemoryStore store,
  required String namespace,
  required void Function(Map<String, dynamic>, Map<String, dynamic>) mutate,
}) async {
  final wrapper = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
  final header = Map<String, dynamic>.from(wrapper['header'] as Map);
  final salt = base64Decode(header['salt'] as String);
  final derived = await Argon2id(
    parallelism: 1,
    memory: 19456,
    iterations: 2,
    hashLength: 32,
  ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
  final key = SecretKey(await derived.extractBytes());
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox(
      base64Decode(wrapper['cipher'] as String),
      nonce: base64Decode(header['nonce'] as String),
      mac: Mac(base64Decode(wrapper['mac'] as String)),
    ),
    secretKey: key,
    aad: utf8.encode(_canonical(header)),
  );
  final payload = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  final signed = jsonDecode(payload['facts'] as String) as Map<String, dynamic>;
  final body = signed['body'] as Map<String, dynamic>;
  mutate(body, payload);
  final custody = jsonDecode(
    utf8.decode(store.states[companyCustodyNamespace(namespace)]!.bytes),
  ) as Map<String, dynamic>;
  final root = await Ed25519().newKeyPairFromSeed(
    base64Decode(custody['rootSeed'] as String),
  );
  final signature = await Ed25519().sign(
    utf8.encode('wiredpart.company.facts@2:${_canonical(body)}'),
    keyPair: root,
  );
  payload['facts'] = _canonical({
    'body': body,
    'signature': base64Encode(signature.bytes),
  });
  final random = Random.secure();
  final nonce = Uint8List.fromList(
    List<int>.generate(12, (_) => random.nextInt(256)),
  );
  header['nonce'] = base64Encode(nonce);
  final encrypted = await AesGcm.with256bits().encrypt(
    utf8.encode(_canonical(payload)),
    secretKey: key,
    nonce: nonce,
    aad: utf8.encode(_canonical(header)),
  );
  return Uint8List.fromList(
    utf8.encode(
      _canonical({
        'header': header,
        'cipher': base64Encode(encrypted.cipherText),
        'mac': base64Encode(encrypted.mac.bytes),
      }),
    ),
  );
}

final class _MemoryStore
    implements InstallationSecureStore, RecoveryFilePublisher {
  final states = <String, ProtectedInstallationState>{};
  Future<void> Function(String namespace, Uint8List bytes)? beforeCas;
  Future<void> Function(String namespace)? beforeRead;
  Future<void> Function()? afterPublish;

  @override
  Future<ProtectedInstallationState?> readState(String namespace) async {
    await beforeRead?.call(namespace);
    return states[namespace];
  }

  @override
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  }) async {
    await beforeCas?.call(namespace, bytes);
    if (states[namespace]?.revision != expectedRevision) {
      throw StateError('CAS conflict');
    }
    states[namespace] = ProtectedInstallationState(nextRevision, bytes);
    return nextRevision;
  }

  @override
  Future<void> writeRecoveryFileExclusive(
    String absolutePath,
    Uint8List bytes,
  ) async {
    // Unit-only adapter: native same-descriptor publication is proved separately.
    final file = File(absolutePath);
    await file.create(exclusive: true);
    await file.writeAsBytes(bytes, flush: true);
    await afterPublish?.call();
  }
}

final class _PausedReset extends LocalDataReset {
  _PausedReset(Directory root) : super(supportDir: root, documentsDir: root);

  final reached = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> preflight() async {
    await super.preflight();
    if (!reached.isCompleted) {
      reached.complete();
      await resume.future;
    }
  }
}

void main() {
  testWidgets(
    'wipe paused after legacy preflight cannot rotate a newly active company',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'company-wipe-race-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      const namespace = 'synthetic.wipe-race';
      final installation = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      late String deviceId;
      late _PausedReset reset;
      await tester.runAsync(() async {
        await installation.start(db);
        deviceId = await db.settingsDao.ensureDeviceId();
        reset = _PausedReset(directory);
      });
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: deviceId,
          installation: installation,
          reset: reset,
          reopenDatabase: () => AppDatabase.forTesting(
            NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final wipe = expectLater(
          tester.widget<AppScope>(find.byType(AppScope)).wipeLocalData(),
          throwsA(isA<StateError>()),
        );
        await reset.reached.future.timeout(const Duration(seconds: 10));
        await CompanyEnrollment(installation: installation, db: db).create(
          companyName: 'Wipe Race Crew',
          policy: CompanyContinuityPolicy.localContinuity,
          pin: '1234',
          recoveryPassphrase: 'wipe race recovery phrase',
          recoveryFile: File(p.join(directory.path, 'authority.wpca')),
        );
        final protected = store.states[namespace]!;
        final installationId = installation.identity!.id.value;
        final facts = await db.select(db.companyAuthorityFacts).get();
        final witness = await db.select(db.companyBootstrapWitnesses).get();
        reset.resume.complete();
        await wipe;
        expect(store.states[namespace]!.revision, protected.revision);
        expect(store.states[namespace]!.bytes, protected.bytes);
        expect(installation.identity!.id.value, installationId);
        expect(await db.select(db.companyAuthorityFacts).get(), facts);
        expect(await db.select(db.companyBootstrapWitnesses).get(), witness);
        expect(await db.settingsDao.ensureDeviceId(), deviceId);
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'reset admission first prevents stale Create from writing custody',
    () async {
      final directory = Directory.systemTemp.createTempSync('reset-first-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      const namespace = 'synthetic.reset-first';
      final installation = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      await installation.start(db);
      await installation.prepareReset(db);
      final afterReset = store.states[namespace]!;
      await expectLater(
        CompanyEnrollment(installation: installation, db: db).create(
          companyName: 'Reset First Crew',
          policy: CompanyContinuityPolicy.localContinuity,
          pin: '1234',
          recoveryPassphrase: 'reset first recovery phrase',
          recoveryFile: File(p.join(directory.path, 'authority.wpca')),
        ),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      expect(store.states[namespace]!.revision, afterReset.revision);
      expect(store.states[namespace]!.bytes, afterReset.bytes);
      expect(
        store.states.containsKey(companyCustodyNamespace(namespace)),
        isFalse,
      );
      expect(await db.select(db.companyAuthorityFacts).get(), isEmpty);
      expect(await db.select(db.companyBootstrapWitnesses).get(), isEmpty);
    },
  );

  test('pending company custody blocks legacy reset and restore without SQL markers', () async {
    final directory = Directory.systemTemp.createTempSync('pending-reset-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final db = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
    );
    addTearDown(db.close);
    final store = _MemoryStore();
    const namespace = 'synthetic.pending-reset';
    final installation = InstallationSecurity(
      store: store,
      namespace: namespace,
    );
    await installation.start(db);
    store.beforeCas = (name, bytes) async {
      if (name != companyCustodyNamespace(namespace)) return;
      final next = jsonDecode(utf8.decode(bytes)) as Map;
      if (next['facts'] != null) throw StateError('facts commit interrupted');
    };
    await expectLater(
      CompanyEnrollment(installation: installation, db: db).create(
        companyName: 'Pending Reset Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'pending reset recovery phrase',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await db.select(db.companyAuthorityFacts).get(), isEmpty);
    expect(await db.select(db.companyBootstrapWitnesses).get(), isEmpty);
    final original = store.states[namespace]!;
    final pending = store.states[companyCustodyNamespace(namespace)]!;
    store.beforeCas = null;
    await expectLater(
      installation.prepareReset(db),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      installation.prepareBusinessRestore(db),
      throwsA(isA<StateError>()),
    );
    expect(store.states[namespace]!.revision, original.revision);
    expect(store.states[namespace]!.bytes, original.bytes);
    expect(
      store.states[companyCustodyNamespace(namespace)]!.revision,
      pending.revision,
    );
    expect(
      store.states[companyCustodyNamespace(namespace)]!.bytes,
      pending.bytes,
    );
  });

  test(
    'company commit fences cached legacy Jobs, Parts, and Taxonomy writers',
    () async {
      final directory = Directory.systemTemp.createTempSync('company-fence-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File(p.join(directory.path, kSqliteFileName));
      final companyDb = AppDatabase.forTesting(NativeDatabase(file));
      final legacyDb = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(companyDb.close);
      addTearDown(legacyDb.close);
      final store = _MemoryStore();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.legacy-fence',
      );
      await installation.start(companyDb);
      await CompanyEnrollment(installation: installation, db: companyDb).create(
        companyName: 'Fenced Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'fenced recovery phrase 123',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      );
      final device = const Uuid().v4();
      await expectLater(
        legacyDb.jobsDao.insertJob(
          id: const Uuid().v4(),
          name: 'Stale job',
          deviceId: device,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        legacyDb.partsDao.insertGeneralPart(
          id: const Uuid().v4(),
          name: 'Stale part',
          deviceId: device,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        legacyDb.taxonomyDao.insertCategory(
          id: const Uuid().v4(),
          name: 'Stale category',
          deviceId: device,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await companyDb.select(companyDb.jobs).get(), isEmpty);
      expect(await companyDb.select(companyDb.parts).get(), isEmpty);
      expect(await companyDb.select(companyDb.categories).get(), isEmpty);
      expect(
        await companyDb.select(companyDb.companyAuthorityFacts).get(),
        hasLength(1),
      );
      expect(
        await companyDb.select(companyDb.companyBootstrapWitnesses).get(),
        hasLength(1),
      );
    },
  );

  test('held legacy write commits before Create admission; Create leaves no custody', () async {
    final directory = Directory.systemTemp.createTempSync('legacy-first-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File(p.join(directory.path, kSqliteFileName));
    final legacyDb = AppDatabase.forTesting(NativeDatabase(file));
    final companyDb = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(legacyDb.close);
    addTearDown(companyDb.close);
    final store = _MemoryStore();
    const namespace = 'synthetic.legacy-first';
    final installation = InstallationSecurity(
      store: store,
      namespace: namespace,
    );
    await installation.start(companyDb);
    final entered = Completer<void>();
    final release = Completer<void>();
    final legacyWrite = legacyDb.transaction(() async {
      await legacyDb.customStatement(
        'UPDATE app_settings SET value = value WHERE key = ?',
        [kInstallationBindingKey],
      );
      await legacyDb.jobsDao.insertJob(
        id: const Uuid().v4(),
        name: 'Earlier job',
        deviceId: const Uuid().v4(),
      );
      entered.complete();
      await release.future;
    });
    await entered.future;
    final creationCheck = expectLater(
      CompanyEnrollment(installation: installation, db: companyDb).create(
        companyName: 'Later Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'later recovery phrase 123',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      ),
      throwsA(isA<Exception>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    release.complete();
    await legacyWrite;
    await creationCheck;
    await expectLater(
      CompanyEnrollment(installation: installation, db: companyDb).create(
        companyName: 'Later Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'later recovery phrase 123',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      ),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
    expect(await companyDb.select(companyDb.jobs).get(), hasLength(1));
    expect(
      await companyDb.select(companyDb.companyAuthorityFacts).get(),
      isEmpty,
    );
    expect(
      await companyDb.select(companyDb.companyBootstrapWitnesses).get(),
      isEmpty,
    );
    expect(
      store.states.containsKey(companyCustodyNamespace(namespace)),
      isFalse,
    );
  });

  test(
    'rolled-back facts plus legacy job prevent pending Create adoption',
    () async {
      final directory = Directory.systemTemp.createTempSync('pending-legacy-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      const namespace = 'synthetic.pending-legacy';
      final installation = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      await installation.start(db);
      store.beforeCas = (name, bytes) async {
        if (name != companyCustodyNamespace(namespace)) return;
        final state = jsonDecode(utf8.decode(bytes)) as Map;
        if (state['facts'] != null && state['digest'] == null) {
          throw StateError('injected after_writeFacts rollback');
        }
      };
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      final destination = File(p.join(directory.path, 'authority.wpca'));
      Future<CompanyIdentity> create() => enrollment.create(
        companyName: 'Pending Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'pending recovery phrase 123',
        recoveryFile: destination,
      );
      await expectLater(create(), throwsA(isA<StateError>()));
      expect(await db.select(db.companyAuthorityFacts).get(), isEmpty);
      expect(await db.select(db.companyBootstrapWitnesses).get(), isEmpty);
      final pending = jsonDecode(
        utf8.decode(store.states[companyCustodyNamespace(namespace)]!.bytes),
      ) as Map;
      store.beforeCas = null;
      await db.jobsDao.insertJob(
        id: const Uuid().v4(),
        name: 'Real legacy job',
        deviceId: const Uuid().v4(),
      );
      await expectLater(create(), throwsA(isA<CompanyBootstrapRefusal>()));
      final after = jsonDecode(
        utf8.decode(store.states[companyCustodyNamespace(namespace)]!.bytes),
      ) as Map;
      expect(after['company'], pending['company']);
      expect(after['shop'], pending['shop']);
      expect(after['intent'], pending['intent']);
      expect(
        identical(after['rootSeed'], pending['rootSeed']) ||
            after['rootSeed'] == pending['rootSeed'],
        isTrue,
      );
      expect(await db.select(db.jobs).get(), hasLength(1));
      expect(await db.select(db.companyAuthorityFacts).get(), isEmpty);
      expect(await db.select(db.companyBootstrapWitnesses).get(), isEmpty);
      expect(destination.existsSync(), isFalse);
    },
  );

  test('rolled-back recovery facts cannot adopt a later legacy job', () async {
    final directory = Directory.systemTemp.createTempSync('recovery-adoption-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final sourceDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'source.sqlite'))),
    );
    addTearDown(sourceDb.close);
    final sourceStore = _MemoryStore();
    final sourceInstallation = InstallationSecurity(
      store: sourceStore,
      namespace: 'synthetic.recovery-adoption-source',
    );
    await sourceInstallation.start(sourceDb);
    final sourceFile = File(p.join(directory.path, 'source.wpca'));
    await CompanyEnrollment(
      installation: sourceInstallation,
      db: sourceDb,
    ).create(
      companyName: 'Recovery Adoption Crew',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'recovery adoption source phrase',
      recoveryFile: sourceFile,
    );
    final targetDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'target.sqlite'))),
    );
    addTearDown(targetDb.close);
    final targetStore = _MemoryStore();
    const targetNamespace = 'synthetic.recovery-adoption-target';
    final targetInstallation = InstallationSecurity(
      store: targetStore,
      namespace: targetNamespace,
    );
    await targetInstallation.start(targetDb);
    final target = CompanyEnrollment(
      installation: targetInstallation,
      db: targetDb,
    );
    final destination = File(p.join(directory.path, 'target.wpca'));
    Future<CompanyIdentity> recover() => target.recover(
      policy: CompanyContinuityPolicy.localContinuity,
      sourceFile: sourceFile,
      sourcePassphrase: 'recovery adoption source phrase',
      newPin: '0123',
      newRecoveryPassphrase: 'recovery adoption target phrase',
      newRecoveryFile: destination,
    );
    var interrupted = false;
    targetStore.beforeCas = (name, bytes) async {
      if (interrupted || name != companyCustodyNamespace(targetNamespace)) {
        return;
      }
      final next = jsonDecode(utf8.decode(bytes)) as Map;
      if (next['facts'] != null) {
        interrupted = true;
        throw StateError('simulated recovery facts CAS interruption');
      }
    };
    await expectLater(recover(), throwsA(isA<StateError>()));
    expect(interrupted, isTrue);
    expect(
      await targetDb.select(targetDb.companyAuthorityFacts).get(),
      isEmpty,
    );
    final pending =
        targetStore.states[companyCustodyNamespace(targetNamespace)]!;
    targetStore.beforeCas = null;
    await targetDb.jobsDao.insertJob(
      id: const Uuid().v4(),
      name: 'Later legacy job',
      deviceId: const Uuid().v4(),
    );
    await expectLater(recover(), throwsA(isA<CompanyBootstrapRefusal>()));
    expect(
      targetStore.states[companyCustodyNamespace(targetNamespace)]!.bytes,
      pending.bytes,
    );
    expect(
      await targetDb.select(targetDb.companyAuthorityFacts).get(),
      isEmpty,
    );
    expect(
      await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
      isEmpty,
    );
    expect(await targetDb.select(targetDb.jobs).get(), hasLength(1));
    expect(destination.existsSync(), isFalse);
  });

  test(
    'pending recovery cannot be continued as Create after facts rollback',
    () async {
      final directory = Directory.systemTemp.createTempSync('recovery-mode-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final sourceDb = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, 'source.sqlite'))),
      );
      addTearDown(sourceDb.close);
      final sourceStore = _MemoryStore();
      final sourceInstallation = InstallationSecurity(
        store: sourceStore,
        namespace: 'synthetic.recovery-mode-source',
      );
      await sourceInstallation.start(sourceDb);
      final sourceFile = File(p.join(directory.path, 'source.wpca'));
      final sourceIdentity =
          await CompanyEnrollment(
            installation: sourceInstallation,
            db: sourceDb,
          ).create(
            companyName: 'Recovery Mode Crew',
            policy: CompanyContinuityPolicy.localContinuity,
            pin: '1234',
            recoveryPassphrase: 'recovery mode source phrase',
            recoveryFile: sourceFile,
          );

      final targetFile = File(p.join(directory.path, 'target.sqlite'));
      var targetDb = AppDatabase.forTesting(NativeDatabase(targetFile));
      addTearDown(() => targetDb.close());
      final targetStore = _MemoryStore();
      const targetNamespace = 'synthetic.recovery-mode-target';
      var targetInstallation = InstallationSecurity(
        store: targetStore,
        namespace: targetNamespace,
      );
      await targetInstallation.start(targetDb);
      var target = CompanyEnrollment(
        installation: targetInstallation,
        db: targetDb,
      );
      final recoveryFile = File(p.join(directory.path, 'replacement.wpca'));
      Future<CompanyIdentity> recover() => target.recover(
        policy: CompanyContinuityPolicy.localContinuity,
        sourceFile: sourceFile,
        sourcePassphrase: 'recovery mode source phrase',
        newPin: '0123',
        newRecoveryPassphrase: 'recovery mode replacement phrase',
        newRecoveryFile: recoveryFile,
      );
      var interrupted = false;
      targetStore.beforeCas = (namespace, bytes) async {
        if (interrupted ||
            namespace != companyCustodyNamespace(targetNamespace)) {
          return;
        }
        final next = jsonDecode(utf8.decode(bytes)) as Map;
        if (next['facts'] != null) {
          interrupted = true;
          throw StateError('simulated recovery facts rollback');
        }
      };
      await expectLater(recover(), throwsA(isA<StateError>()));
      expect(interrupted, isTrue);
      targetStore.beforeCas = null;
      expect(
        await targetDb.select(targetDb.companyAuthorityFacts).get(),
        isEmpty,
      );
      expect(
        await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
        isEmpty,
      );
      await targetDb.close();

      targetDb = AppDatabase.forTesting(NativeDatabase(targetFile));
      targetInstallation = InstallationSecurity(
        store: targetStore,
        namespace: targetNamespace,
      );
      await targetInstallation.start(targetDb);
      target = CompanyEnrollment(
        installation: targetInstallation,
        db: targetDb,
      );
      expect(await target.readStatus(), CompanyBootstrapStatus.pendingRecovery);
      final before = {
        for (final entry in targetStore.states.entries)
          entry.key: (
            entry.value.revision,
            Uint8List.fromList(entry.value.bytes),
          ),
      };
      final wrongFile = File(p.join(directory.path, 'wrong-flow.wpca'));
      await expectLater(
        target.create(
          companyName: 'Recovery Mode Crew',
          policy: CompanyContinuityPolicy.localContinuity,
          pin: '0123',
          recoveryPassphrase: 'wrong flow authority phrase',
          recoveryFile: wrongFile,
        ),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      for (final entry in before.entries) {
        expect(targetStore.states[entry.key]!.revision, entry.value.$1);
        expect(targetStore.states[entry.key]!.bytes, entry.value.$2);
      }
      expect(
        await targetDb.select(targetDb.companyAuthorityFacts).get(),
        isEmpty,
      );
      expect(
        await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
        isEmpty,
      );
      expect(wrongFile.existsSync(), isFalse);

      final recovered = await recover();
      expect(recovered.companyId, sourceIdentity.companyId);
      expect(recovered.shopId, sourceIdentity.shopId);
      expect(recovered.userId, sourceIdentity.userId);
      final protected = jsonDecode(
        utf8.decode(
          targetStore.states[companyCustodyNamespace(targetNamespace)]!.bytes,
        ),
      ) as Map;
      expect(protected['authority'], 2);
      expect(protected['recoverySeed'], isNull);
      expect(recoveryFile.existsSync(), isTrue);
      expect(await target.readStatus(), CompanyBootstrapStatus.active);
      expect((await target.signIn('0123')).isValid, isTrue);
      expect(
        (await targetInstallation.readCompanyTrust(targetDb))!.authorityVersion,
        2,
      );
      expect(
        targetInstallation
            .knownSecurityFloors['authority.${sourceIdentity.companyId}'],
        2,
      );
      final facts = await targetDb.select(targetDb.companyAuthorityFacts).get();
      expect(facts, hasLength(2));
      expect(
        facts.map(
          (fact) => (jsonDecode(fact.signedBytes) as Map)['body']['authority'],
        ),
        contains(2),
      );
    },
  );

  test('pending Create cannot be continued as authority recovery', () async {
    final directory = Directory.systemTemp.createTempSync('create-mode-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final sourceDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'source.sqlite'))),
    );
    addTearDown(sourceDb.close);
    final sourceStore = _MemoryStore();
    final sourceInstallation = InstallationSecurity(
      store: sourceStore,
      namespace: 'synthetic.create-mode-source',
    );
    await sourceInstallation.start(sourceDb);
    final sourceFile = File(p.join(directory.path, 'source.wpca'));
    await CompanyEnrollment(
      installation: sourceInstallation,
      db: sourceDb,
    ).create(
      companyName: 'Source Crew',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'source create mode phrase',
      recoveryFile: sourceFile,
    );

    final targetDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'target.sqlite'))),
    );
    addTearDown(targetDb.close);
    final store = _MemoryStore();
    const namespace = 'synthetic.create-mode-target';
    final installation = InstallationSecurity(
      store: store,
      namespace: namespace,
    );
    await installation.start(targetDb);
    final enrollment = CompanyEnrollment(
      installation: installation,
      db: targetDb,
    );
    var interrupted = false;
    store.beforeCas = (name, bytes) async {
      if (interrupted || name != companyCustodyNamespace(namespace)) return;
      final next = jsonDecode(utf8.decode(bytes)) as Map;
      if (next['facts'] != null) {
        interrupted = true;
        throw StateError('simulated Create facts rollback');
      }
    };
    await expectLater(
      enrollment.create(
        companyName: 'New Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '0123',
        recoveryPassphrase: 'new create mode phrase',
        recoveryFile: File(p.join(directory.path, 'create.wpca')),
      ),
      throwsA(isA<StateError>()),
    );
    expect(interrupted, isTrue);
    store.beforeCas = null;
    expect(await enrollment.readStatus(), CompanyBootstrapStatus.pending);
    final before = {
      for (final entry in store.states.entries)
        entry.key: (
          entry.value.revision,
          Uint8List.fromList(entry.value.bytes),
        ),
    };
    final wrongFile = File(p.join(directory.path, 'wrong-recovery.wpca'));
    await expectLater(
      enrollment.recover(
        policy: CompanyContinuityPolicy.localContinuity,
        sourceFile: sourceFile,
        sourcePassphrase: 'source create mode phrase',
        newPin: '0123',
        newRecoveryPassphrase: 'wrong recovery mode phrase',
        newRecoveryFile: wrongFile,
      ),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
    for (final entry in before.entries) {
      expect(store.states[entry.key]!.revision, entry.value.$1);
      expect(store.states[entry.key]!.bytes, entry.value.$2);
    }
    expect(
      await targetDb.select(targetDb.companyAuthorityFacts).get(),
      isEmpty,
    );
    expect(
      await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
      isEmpty,
    );
    expect(wrongFile.existsSync(), isFalse);
  });

  test('authenticated revoked admin is refused before recovery mutation', () async {
    final directory = Directory.systemTemp.createTempSync('revoked-source-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final sourceDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'source.sqlite'))),
    );
    addTearDown(sourceDb.close);
    final sourceStore = _MemoryStore();
    const sourceNamespace = 'synthetic.revoked-source';
    final sourceInstallation = InstallationSecurity(
      store: sourceStore,
      namespace: sourceNamespace,
    );
    await sourceInstallation.start(sourceDb);
    final originalFile = File(p.join(directory.path, 'original.wpca'));
    final originalCompany =
        await CompanyEnrollment(
          installation: sourceInstallation,
          db: sourceDb,
        ).create(
          companyName: 'Revoked Source',
          policy: CompanyContinuityPolicy.localContinuity,
          pin: '1234',
          recoveryPassphrase: 'revoked source phrase 123',
          recoveryFile: originalFile,
        );
    final original = await originalFile.readAsBytes();
    await sourceDb.close();
    final targetDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'target.sqlite'))),
    );
    addTearDown(targetDb.close);
    final targetStore = _MemoryStore();
    final targetInstallation = InstallationSecurity(
      store: targetStore,
      namespace: 'synthetic.revoked-target',
    );
    await targetInstallation.start(targetDb);
    final baseRevision =
        targetStore.states['synthetic.revoked-target']!.revision;
    final target = CompanyEnrollment(
      installation: targetInstallation,
      db: targetDb,
    );
    for (final profile in ['revoked user', 'reduced user capability']) {
      final forged = await _resignEncryptedFirstOwnerPackage(
        original: original,
        passphrase: 'revoked source phrase 123',
        store: sourceStore,
        namespace: sourceNamespace,
        mutate: (body, _) {
          final user = (body['users'] as List).single as Map<String, dynamic>;
          if (profile == 'revoked user') {
            user['revoked'] = true;
          } else {
            user['capabilities'] = ['patchJobLine', 'deleteJobLine'];
          }
        },
      );
      final forgedFile = File(p.join(directory.path, '$profile.wpca'));
      await forgedFile.writeAsBytes(forged);
      final nextFile = File(p.join(directory.path, '$profile.next.wpca'));
      await expectLater(
        target.recover(
          policy: CompanyContinuityPolicy.localContinuity,
          sourceFile: forgedFile,
          sourcePassphrase: 'revoked source phrase 123',
          newPin: '0123',
          newRecoveryPassphrase: 'fresh recovery phrase 123',
          newRecoveryFile: nextFile,
        ),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      expect(targetStore.states.keys, contains('synthetic.revoked-target'));
      expect(targetStore.states.length, 1);
      expect(
        targetStore.states['synthetic.revoked-target']!.revision,
        baseRevision,
      );
      expect(
        await targetDb.select(targetDb.companyAuthorityFacts).get(),
        isEmpty,
      );
      expect(
        await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
        isEmpty,
      );
      expect(nextFile.existsSync(), isFalse);
    }
    final revokedDevice = await _resignEncryptedFirstOwnerPackage(
      original: original,
      passphrase: 'revoked source phrase 123',
      store: sourceStore,
      namespace: sourceNamespace,
      mutate: (body, payload) {
        final device = (body['devices'] as List).single as Map<String, dynamic>;
        device['revoked'] = true;
        (payload['floors']
                as Map<String, dynamic>)['revocation.device.${device['id']}'] =
            1;
      },
    );
    final revokedDeviceFile = File(
      p.join(directory.path, 'revoked-device.wpca'),
    );
    await revokedDeviceFile.writeAsBytes(revokedDevice);
    final recovered = await target.recover(
      policy: CompanyContinuityPolicy.localContinuity,
      sourceFile: revokedDeviceFile,
      sourcePassphrase: 'revoked source phrase 123',
      newPin: '0123',
      newRecoveryPassphrase: 'fresh recovery phrase 123',
      newRecoveryFile: File(p.join(directory.path, 'valid-next.wpca')),
    );
    expect(recovered.companyId, isNotEmpty);
    expect(
      targetInstallation
          .knownSecurityFloors['revocation.device.${originalCompany.deviceId}'],
      1,
    );
  });

  test(
    'cold restart after facts commit and lost custody needs recovery',
    () async {
      final directory = Directory.systemTemp.createTempSync('lost-custody-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File(p.join(directory.path, kSqliteFileName));
      AppDatabase open() => AppDatabase.forTesting(NativeDatabase(file));
      final db = open();
      addTearDown(db.close);
      final store = _MemoryStore();
      const namespace = 'synthetic.lost-custody';
      final installation = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      await installation.start(db);
      store.beforeCas = (name, bytes) async {
        if (name != companyCustodyNamespace(namespace)) return;
        final state = jsonDecode(utf8.decode(bytes)) as Map;
        if (state['facts'] != null && state['digest'] != null) {
          throw StateError('injected after_writeFacts interruption');
        }
      };
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      await expectLater(
        enrollment.create(
          companyName: 'Interrupted Crew',
          policy: CompanyContinuityPolicy.localContinuity,
          pin: '1234',
          recoveryPassphrase: 'separate recovery phrase 123',
          recoveryFile: File(p.join(directory.path, 'authority.wpca')),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await db.select(db.companyAuthorityFacts).get(), hasLength(1));
      expect(await db.select(db.companyBootstrapWitnesses).get(), hasLength(1));
      expect(
        store.states.remove(companyCustodyNamespace(namespace)),
        isNotNull,
      );
      await db.close();

      final reopened = open();
      addTearDown(reopened.close);
      final restarted = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      await restarted.start(reopened);
      expect(restarted.readiness, InstallationReadiness.ready);
      expect(
        await CompanyEnrollment(
          installation: restarted,
          db: reopened,
        ).readStatus(),
        CompanyBootstrapStatus.needsRecovery,
      );
    },
  );

  for (final marker in ['facts', 'witness', 'history', 'query failure']) {
    test(
      'missing custody with $marker needs recovery, never unjoined',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final store = _MemoryStore();
        final installation = InstallationSecurity(
          store: store,
          namespace: 'synthetic.missing-custody-${marker.replaceAll(' ', '-')}',
        );
        await installation.start(db);
        if (marker == 'facts') {
          await db.customStatement(
            "INSERT INTO company_authority_facts (company_id, commitment, signed_bytes) "
            "VALUES ('company', 'digest', 'bytes')",
          );
        } else if (marker == 'witness') {
          await db.customStatement(
            "INSERT INTO company_bootstrap_witnesses "
            "(company_id, bootstrap_id, facts_commitment, package_id, package_digest, status) "
            "VALUES ('company', 'intent', 'facts', 'package', NULL, 'pending')",
          );
        } else if (marker == 'history') {
          await db.customStatement(
            "INSERT INTO job_line_audits (receipt_key, audit_bytes) "
            "VALUES ('receipt', 'bytes')",
          );
        } else {
          await db.customStatement('DROP TABLE company_bootstrap_witnesses');
        }
        final enrollment = CompanyEnrollment(
          installation: installation,
          db: db,
        );
        expect(
          await enrollment.readStatus(),
          CompanyBootstrapStatus.needsRecovery,
        );
      },
    );
  }

  test(
    'production namespace creates and reopens a signed-in local company',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'company-production-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final dbFile = File(p.join(directory.path, kSqliteFileName));
      AppDatabase open() => AppDatabase.forTesting(NativeDatabase(dbFile));
      final store = _MemoryStore();
      final db = open();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'production',
      );
      await installation.start(db);
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      final package = File(p.join(directory.path, 'authority.wpca'));
      final created = await enrollment.create(
        companyName: 'Production Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '12345678',
        recoveryPassphrase: 'separate authority phrase 123',
        recoveryFile: package,
      );
      expect(await enrollment.readStatus(), CompanyBootstrapStatus.active);
      expect(installation.canUseCompanyOperations, isTrue);
      final first = await enrollment.signIn('12345678');
      expect(first.identity.companyId, created.companyId);
      await enrollment.signOut();
      expect(first.isValid, isFalse);
      await db.close();

      final reopened = open();
      addTearDown(reopened.close);
      final resumedInstallation = InstallationSecurity(
        store: store,
        namespace: 'production',
      );
      await resumedInstallation.start(reopened);
      final resumed = CompanyEnrollment(
        installation: resumedInstallation,
        db: reopened,
      );
      expect(await resumed.readStatus(), CompanyBootstrapStatus.active);
      expect(resumed.currentSession, isNull);
      final second = await resumed.signIn('12345678');
      expect(second.identity.companyId, created.companyId);
      expect(second.sessionId, isNot(first.sessionId));
      expect(package.existsSync(), isTrue);
    },
  );

  test('protected PIN reservations survive restart and exhaust after eight failures', () async {
    final directory = Directory.systemTemp.createTempSync(
      'company-pin-budget-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File(p.join(directory.path, kSqliteFileName));
    AppDatabase open() => AppDatabase.forTesting(NativeDatabase(file));
    final store = _MemoryStore();
    var db = open();
    var installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.pin-budget',
    );
    await installation.start(db);
    var enrollment = CompanyEnrollment(installation: installation, db: db);
    await enrollment.create(
      companyName: 'PIN Budget Crew',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'PIN budget recovery phrase',
      recoveryFile: File(p.join(directory.path, 'authority.wpca')),
    );
    for (var i = 0; i < 3; i++) {
      await expectLater(enrollment.signIn('9999'), throwsA(isA<Exception>()));
    }
    await db.close();
    db = open();
    addTearDown(db.close);
    installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.pin-budget',
    );
    await installation.start(db);
    enrollment = CompanyEnrollment(installation: installation, db: db);
    for (var i = 0; i < 5; i++) {
      await expectLater(enrollment.signIn('9999'), throwsA(isA<Exception>()));
    }
    final custody = jsonDecode(
      utf8.decode(
        store.states[companyCustodyNamespace('synthetic.pin-budget')]!.bytes,
      ),
    ) as Map<String, dynamic>;
    expect(custody['attempts'], 0);
    await expectLater(enrollment.signIn('1234'), throwsA(isA<Exception>()));
    expect(enrollment.currentSession, isNull);
  });

  test(
    'overlapping PIN reservations cannot reuse one protected revision',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'company-pin-race-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.pin-race',
      );
      await installation.start(db);
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      await enrollment.create(
        companyName: 'PIN Race Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'PIN race recovery phrase',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      );
      final bothEntered = Completer<void>();
      final release = Completer<void>();
      var reservations = 0;
      store.beforeCas = (namespace, bytes) async {
        if (namespace != companyCustodyNamespace('synthetic.pin-race') ||
            (jsonDecode(utf8.decode(bytes)) as Map)['attempts'] != 7) {
          return;
        }
        reservations++;
        if (reservations == 2) bothEntered.complete();
        await release.future;
      };
      final calls = [enrollment.signIn('9999'), enrollment.signIn('9999')];
      await bothEntered.future.timeout(const Duration(seconds: 10));
      release.complete();
      final results = await Future.wait(
        calls.map(
          (call) => call.then<Object>(
            (_) => 'unexpected success',
            onError: (Object error) => error,
          ),
        ),
      );
      expect(results, everyElement(isNot('unexpected success')));
      final attempts = (jsonDecode(
        utf8.decode(
          store.states[companyCustodyNamespace('synthetic.pin-race')]!.bytes,
        ),
      ) as Map)['attempts'];
      expect(attempts, 7);
      expect(enrollment.currentSession, isNull);
    },
  );

  test('package-digest CAS interruption resumes the same pending company after cold restart', () async {
    final directory = Directory.systemTemp.createTempSync('company-pending-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final dbFile = File(p.join(directory.path, kSqliteFileName));
    AppDatabase open() => AppDatabase.forTesting(NativeDatabase(dbFile));
    final store = _MemoryStore();
    var db = open();
    var installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.pending',
    );
    await installation.start(db);
    var enrollment = CompanyEnrollment(installation: installation, db: db);
    final destination = File(p.join(directory.path, 'authority.wpca'));
    var failed = false;
    store.beforeCas = (namespace, bytes) async {
      if (failed || namespace != companyCustodyNamespace('synthetic.pending')) {
        return;
      }
      final next = jsonDecode(utf8.decode(bytes)) as Map;
      if (next['status'] == 'pending' && next['digest'] != null) {
        failed = true;
        throw StateError('simulated protected CAS interruption');
      }
    };
    await expectLater(
      enrollment.create(
        companyName: 'Pending Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'pending recovery phrase 123',
        recoveryFile: destination,
      ),
      throwsA(isA<StateError>()),
    );
    expect(failed, isTrue);
    expect(destination.existsSync(), isFalse);
    expect(File('${destination.path}.pending').existsSync(), isFalse);
    final before = jsonDecode(
      utf8.decode(
        store.states[companyCustodyNamespace('synthetic.pending')]!.bytes,
      ),
    ) as Map;
    final originalCompany = before['company'];
    expect(before['status'], 'pending');
    await db.close();
    store.beforeCas = null;
    db = open();
    addTearDown(db.close);
    installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.pending',
    );
    await installation.start(db);
    enrollment = CompanyEnrollment(installation: installation, db: db);
    final completed = await enrollment.create(
      companyName: 'Pending Crew',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'pending recovery phrase 123',
      recoveryFile: destination,
    );
    expect(completed.companyId, originalCompany);
    expect(destination.existsSync(), isTrue);
    expect(await db.select(db.companyBootstrapWitnesses).get(), hasLength(1));
    expect(await db.select(db.companyAuthorityFacts).get(), hasLength(1));
    expect(await enrollment.readStatus(), CompanyBootstrapStatus.active);
  });

  test(
    'unconfirmed complete export requires a fresh destination on retry',
    () async {
      final directory = Directory.systemTemp.createTempSync('company-publish-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      const namespace = 'synthetic.publish-interruption';
      final installation = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      await installation.start(db);
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      final first = File(p.join(directory.path, 'first.wpca'));
      final second = File(p.join(directory.path, 'second.wpca'));
      Future<CompanyIdentity> create(File destination) => enrollment.create(
        companyName: 'Publisher Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'publisher recovery phrase 123',
        recoveryFile: destination,
      );
      store.afterPublish = () async {
        throw StateError('simulated reply loss after complete write');
      };
      await expectLater(create(first), throwsA(isA<StateError>()));
      final firstBytes = await first.readAsBytes();
      final pending = jsonDecode(
        utf8.decode(store.states[companyCustodyNamespace(namespace)]!.bytes),
      ) as Map<String, dynamic>;
      expect(pending['status'], 'pending');
      store.afterPublish = null;
      await expectLater(
        create(first),
        throwsA(
          isA<CompanyBootstrapRefusal>().having(
            (e) => e.message,
            'message',
            contains('fresh destination'),
          ),
        ),
      );
      expect(await enrollment.readStatus(), CompanyBootstrapStatus.pending);
      expect(await first.readAsBytes(), firstBytes);
      final identity = await create(second);
      expect(identity.companyId, pending['company']);
      expect(identity.userId, pending['user']);
      expect(await second.readAsBytes(), firstBytes);
      expect(await enrollment.readStatus(), CompanyBootstrapStatus.active);
      store.afterPublish = () async {
        throw StateError('active retry must not republish');
      };
      final repeated = await create(second);
      expect(repeated.companyId, identity.companyId);
      expect(repeated.packageId, identity.packageId);
      expect(await second.readAsBytes(), firstBytes);
    },
  );

  test(
    'activation CAS interruption retries only at a fresh destination',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'company-activate-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      const namespace = 'synthetic.activation-retry';
      final installation = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      await installation.start(db);
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      final first = File(p.join(directory.path, 'first.wpca'));
      final second = File(p.join(directory.path, 'second.wpca'));
      Future<CompanyIdentity> create(File destination) => enrollment.create(
        companyName: 'Activation Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'activation retry recovery phrase',
        recoveryFile: destination,
      );
      var interrupted = false;
      store.beforeCas = (name, bytes) async {
        if (interrupted || name != namespace) return;
        final next = jsonDecode(utf8.decode(bytes)) as Map;
        if (next['companyTrust'] != null) {
          interrupted = true;
          throw StateError('simulated activation CAS interruption');
        }
      };
      await expectLater(create(first), throwsA(isA<StateError>()));
      expect(interrupted, isTrue);
      final original = await first.readAsBytes();
      final pending = jsonDecode(
        utf8.decode(store.states[companyCustodyNamespace(namespace)]!.bytes),
      ) as Map<String, dynamic>;
      expect(pending['status'], 'pending');
      store.beforeCas = null;
      await expectLater(
        create(first),
        throwsA(
          isA<CompanyBootstrapRefusal>().having(
            (e) => e.message,
            'message',
            contains('fresh destination'),
          ),
        ),
      );
      final identity = await create(second);
      expect(identity.companyId, pending['company']);
      expect(identity.packageId, pending['package']);
      expect(await second.readAsBytes(), original);
      expect(await enrollment.readStatus(), CompanyBootstrapStatus.active);
    },
  );

  test(
    'sign-out during an in-flight correct PIN never publishes a session',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'company-signout-race-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.signout-race',
      );
      await installation.start(db);
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      await enrollment.create(
        companyName: 'Sign-out Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'signout recovery phrase 123',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      store.beforeCas = (namespace, bytes) async {
        if (namespace != companyCustodyNamespace('synthetic.signout-race') ||
            (jsonDecode(utf8.decode(bytes)) as Map)['attempts'] != 7) {
          return;
        }
        entered.complete();
        await release.future;
      };
      final signingIn = enrollment.signIn('1234');
      await entered.future.timeout(const Duration(seconds: 10));
      await enrollment.signOut();
      release.complete();
      await expectLater(signingIn, throwsA(isA<Exception>()));
      expect(enrollment.currentSession, isNull);
    },
  );

  test(
    'sign-out during final custody read never publishes a session',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'company-final-read-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final db = AppDatabase.forTesting(
        NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
      );
      addTearDown(db.close);
      final store = _MemoryStore();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.final-read',
      );
      await installation.start(db);
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      await enrollment.create(
        companyName: 'Final Read Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'final read recovery phrase',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      var reset = false;
      var readsAfterReset = 0;
      store.beforeCas = (namespace, bytes) async {
        if (namespace == companyCustodyNamespace('synthetic.final-read') &&
            (jsonDecode(utf8.decode(bytes)) as Map)['attempts'] == 8) {
          reset = true;
        }
      };
      store.beforeRead = (namespace) async {
        if (!reset ||
            namespace != companyCustodyNamespace('synthetic.final-read')) {
          return;
        }
        readsAfterReset++;
        if (readsAfterReset == 2) {
          entered.complete();
          await release.future;
        }
      };
      final signingIn = enrollment.signIn('1234');
      await entered.future.timeout(const Duration(seconds: 10));
      await enrollment.signOut();
      release.complete();
      await expectLater(signingIn, throwsA(isA<Exception>()));
      expect(enrollment.currentSession, isNull);
    },
  );

  test('immediate sign-out cancels a just-started sign-in', () async {
    final directory = Directory.systemTemp.createTempSync(
      'company-entry-race-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final db = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
    );
    addTearDown(db.close);
    final store = _MemoryStore();
    final installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.entry-race',
    );
    await installation.start(db);
    final enrollment = CompanyEnrollment(installation: installation, db: db);
    await enrollment.create(
      companyName: 'Entry Race Crew',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'entry race recovery phrase',
      recoveryFile: File(p.join(directory.path, 'authority.wpca')),
    );
    final signingIn = enrollment.signIn('1234');
    await enrollment.signOut();
    await expectLater(signingIn, throwsA(isA<Exception>()));
    expect(enrollment.currentSession, isNull);
  });

  test(
    'fresh shop creates one real company and survives cold restart',
    () async {
      final directory = Directory.systemTemp.createTempSync('company-enroll-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dbFile = File(p.join(directory.path, kSqliteFileName));
      AppDatabase open() => AppDatabase.forTesting(NativeDatabase(dbFile));
      final store = _MemoryStore();
      final db = open();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.company',
      );
      await installation.start(db);
      final package = File(p.join(directory.path, 'authority.wpca'));
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      final result = await enrollment.create(
        companyName: 'Jobsite Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '12345678',
        recoveryPassphrase: 'long unique recovery phrase',
        recoveryFile: package,
      );
      expect(Uuid.isValidUUID(fromString: result.companyId), isTrue);
      expect(
        {
          result.companyId,
          result.shopId,
          result.userId,
          result.deviceId,
        }.length,
        4,
      );
      expect(package.existsSync(), isTrue);
      final witness = await db.select(db.companyBootstrapWitnesses).getSingle();
      expect(witness.status, 'active');
      expect(witness.packageDigest, isNotNull);
      expect(
        (await installation.readCompanyTrust(db))?.companyId.value,
        result.companyId,
      );
      await expectLater(
        enrollment.signIn('87654321'),
        throwsA(isA<Exception>()),
      );
      final firstSession = await enrollment.signIn('12345678');
      expect(firstSession.isValid, isTrue);
      await enrollment.signOut();
      expect(firstSession.isValid, isFalse);
      await db.close();

      final restarted = open();
      addTearDown(restarted.close);
      final resumedInstallation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.company',
      );
      await resumedInstallation.start(restarted);
      final resumed = CompanyEnrollment(
        installation: resumedInstallation,
        db: restarted,
      );
      final seen = await resumed.readIdentity();
      expect(seen?.companyId, result.companyId);
      expect(seen?.shopId, result.shopId);
      expect(seen?.userId, result.userId);
      expect(resumed.currentSession, isNull);
      final restartedSession = await resumed.signIn('12345678');
      expect(restartedSession.isValid, isTrue);
    },
  );

  test(
    'encrypted checkpoint recovers authority with fresh installation and grant',
    () async {
      final sourceDir = Directory.systemTemp.createTempSync('company-source-');
      final targetDir = Directory.systemTemp.createTempSync('company-target-');
      addTearDown(() {
        sourceDir.deleteSync(recursive: true);
        targetDir.deleteSync(recursive: true);
      });
      final sourceDb = AppDatabase.forTesting(
        NativeDatabase(File(p.join(sourceDir.path, kSqliteFileName))),
      );
      final sourceStore = _MemoryStore();
      final sourceInstallation = InstallationSecurity(
        store: sourceStore,
        namespace: 'synthetic.recovery-source',
      );
      await sourceInstallation.start(sourceDb);
      final sourcePackage = File(p.join(sourceDir.path, 'source.wpca'));
      final original =
          await CompanyEnrollment(
            installation: sourceInstallation,
            db: sourceDb,
          ).create(
            companyName: 'Crew Recovery',
            policy: CompanyContinuityPolicy.localContinuity,
            pin: '1234',
            recoveryPassphrase: 'source recovery phrase 123',
            recoveryFile: sourcePackage,
          );
      final oldKey = sourceInstallation.identity!.publicKey;
      final oldInstall = sourceInstallation.identity!.id.value;
      final sourceBytes = await sourcePackage.readAsBytes();
      await sourceDb.close();

      final targetDb = AppDatabase.forTesting(
        NativeDatabase(File(p.join(targetDir.path, kSqliteFileName))),
      );
      addTearDown(targetDb.close);
      final targetStore = _MemoryStore();
      final targetInstallation = InstallationSecurity(
        store: targetStore,
        namespace: 'synthetic.recovery-target',
      );
      await targetInstallation.start(targetDb);
      final nextPackage = File(p.join(targetDir.path, 'next.wpca'));
      final target = CompanyEnrollment(
        installation: targetInstallation,
        db: targetDb,
      );
      await expectLater(
        target.recover(
          policy: CompanyContinuityPolicy.localContinuity,
          sourceFile: sourcePackage,
          sourcePassphrase: 'wrong recovery phrase',
          newPin: '0123',
          newRecoveryPassphrase: 'next recovery phrase 123',
          newRecoveryFile: nextPackage,
        ),
        throwsA(isA<Exception>()),
      );
      expect(targetStore.states.length, 1);
      final tamperedEnvelope =
          jsonDecode(utf8.decode(sourceBytes)) as Map<String, dynamic>;
      final tamperedCipher = base64Decode(tamperedEnvelope['cipher'] as String);
      tamperedCipher[0] ^= 1;
      tamperedEnvelope['cipher'] = base64Encode(tamperedCipher);
      final tampered = Uint8List.fromList(
        utf8.encode(jsonEncode(tamperedEnvelope)),
      );
      final tamperedFile = File(p.join(targetDir.path, 'tampered.wpca'));
      await tamperedFile.writeAsBytes(tampered);
      final truncatedFile = File(p.join(targetDir.path, 'truncated.wpca'));
      await truncatedFile.writeAsBytes(sourceBytes.sublist(0, 12));
      for (final invalidSource in [tamperedFile, truncatedFile]) {
        await expectLater(
          target.recover(
            policy: CompanyContinuityPolicy.localContinuity,
            sourceFile: invalidSource,
            sourcePassphrase: 'source recovery phrase 123',
            newPin: '0123',
            newRecoveryPassphrase: 'next recovery phrase 123',
            newRecoveryFile: nextPackage,
          ),
          throwsA(isA<Exception>()),
        );
        expect(targetStore.states.length, 1);
        expect(
          await targetDb.select(targetDb.companyAuthorityFacts).get(),
          isEmpty,
        );
        expect(
          await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
          isEmpty,
        );
      }
      final recovered = await target.recover(
        policy: CompanyContinuityPolicy.localContinuity,
        sourceFile: sourcePackage,
        sourcePassphrase: 'source recovery phrase 123',
        newPin: '0123',
        newRecoveryPassphrase: 'next recovery phrase 123',
        newRecoveryFile: nextPackage,
      );
      expect(recovered.companyId, original.companyId);
      expect(recovered.shopId, original.shopId);
      expect(recovered.userId, original.userId);
      expect(recovered.deviceId, isNot(original.deviceId));
      expect(targetInstallation.identity!.id.value, isNot(oldInstall));
      expect(targetInstallation.identity!.publicKey, isNot(oldKey));
      expect(
        (await targetInstallation.readCompanyTrust(targetDb))!.authorityVersion,
        2,
      );
      expect(
        targetInstallation
            .knownSecurityFloors['authority.${original.companyId}'],
        2,
      );
      expect(nextPackage.existsSync(), isTrue);
      expect(await sourcePackage.readAsBytes(), sourceBytes);
      expect((await target.signIn('0123')).isValid, isTrue);
      expect(
        await targetDb.select(targetDb.companyAuthorityFacts).get(),
        hasLength(2),
      );
    },
  );

  test('known credential floor refuses an older recovery checkpoint before mutation', () async {
    final directory = Directory.systemTemp.createTempSync('company-floor-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final sourceDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'source.sqlite'))),
    );
    addTearDown(sourceDb.close);
    final sourceInstallation = InstallationSecurity(
      store: _MemoryStore(),
      namespace: 'synthetic.floor-source',
    );
    await sourceInstallation.start(sourceDb);
    final sourceFile = File(p.join(directory.path, 'source.wpca'));
    final source =
        await CompanyEnrollment(
          installation: sourceInstallation,
          db: sourceDb,
        ).create(
          companyName: 'Floor Crew',
          policy: CompanyContinuityPolicy.localContinuity,
          pin: '1234',
          recoveryPassphrase: 'floor recovery phrase 123',
          recoveryFile: sourceFile,
        );
    await sourceDb.close();
    final targetDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'target.sqlite'))),
    );
    addTearDown(targetDb.close);
    final targetStore = _MemoryStore();
    final targetInstallation = InstallationSecurity(
      store: targetStore,
      namespace: 'synthetic.floor-target',
    );
    await targetInstallation.start(targetDb);
    final initial = targetStore.states['synthetic.floor-target']!;
    final record =
        jsonDecode(utf8.decode(initial.bytes)) as Map<String, dynamic>;
    (record['floors'] as Map<String, dynamic>)['credential.${source.userId}'] =
        5;
    targetStore.states['synthetic.floor-target'] = ProtectedInstallationState(
      const Uuid().v4(),
      Uint8List.fromList(utf8.encode(jsonEncode(record))),
    );
    await targetInstallation.start(targetDb);
    final before = await targetDb.select(targetDb.companyAuthorityFacts).get();
    await expectLater(
      CompanyEnrollment(installation: targetInstallation, db: targetDb).recover(
        policy: CompanyContinuityPolicy.localContinuity,
        sourceFile: sourceFile,
        sourcePassphrase: 'floor recovery phrase 123',
        newPin: '0123',
        newRecoveryPassphrase: 'next floor recovery phrase',
        newRecoveryFile: File(p.join(directory.path, 'next.wpca')),
      ),
      throwsA(isA<Exception>()),
    );
    expect(await targetDb.select(targetDb.companyAuthorityFacts).get(), before);
    expect(
      await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
      isEmpty,
    );
    expect(
      targetStore.states.containsKey(
        companyCustodyNamespace('synthetic.floor-target'),
      ),
      isFalse,
    );
  });

  test('destination created during digest CAS is never overwritten', () async {
    final directory = Directory.systemTemp.createTempSync(
      'company-no-overwrite-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final db = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
    );
    addTearDown(db.close);
    final store = _MemoryStore();
    final installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.no-overwrite',
    );
    await installation.start(db);
    final enrollment = CompanyEnrollment(installation: installation, db: db);
    final destination = File(p.join(directory.path, 'authority.wpca'));
    final unrelated = Uint8List.fromList(utf8.encode('unrelated destination'));
    var injected = false;
    store.beforeCas = (namespace, bytes) async {
      if (injected ||
          namespace != companyCustodyNamespace('synthetic.no-overwrite')) {
        return;
      }
      final state = jsonDecode(utf8.decode(bytes)) as Map;
      if (state['digest'] != null) {
        injected = true;
        await destination.writeAsBytes(unrelated, flush: true);
      }
    };
    await expectLater(
      enrollment.create(
        companyName: 'No Overwrite Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'no overwrite recovery phrase',
        recoveryFile: destination,
      ),
      throwsA(isA<Exception>()),
    );
    expect(injected, isTrue);
    expect(await destination.readAsBytes(), unrelated);
    expect(await enrollment.readStatus(), CompanyBootstrapStatus.pending);
  });

  test(
    'copied company SQLite without protected custody cannot sign in',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'company-foreign-db-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final sourceFile = File(p.join(directory.path, 'source.sqlite'));
      final sourceDb = AppDatabase.forTesting(NativeDatabase(sourceFile));
      final sourceInstallation = InstallationSecurity(
        store: _MemoryStore(),
        namespace: 'synthetic.foreign-source',
      );
      await sourceInstallation.start(sourceDb);
      await CompanyEnrollment(
        installation: sourceInstallation,
        db: sourceDb,
      ).create(
        companyName: 'Foreign DB Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'foreign database recovery phrase',
        recoveryFile: File(p.join(directory.path, 'authority.wpca')),
      );
      await sourceDb.close();
      final copied = File(p.join(directory.path, 'copied.sqlite'));
      await sourceFile.copy(copied.path);
      final targetDb = AppDatabase.forTesting(NativeDatabase(copied));
      addTearDown(targetDb.close);
      final targetInstallation = InstallationSecurity(
        store: _MemoryStore(),
        namespace: 'synthetic.foreign-target',
      );
      await targetInstallation.start(targetDb);
      final target = CompanyEnrollment(
        installation: targetInstallation,
        db: targetDb,
      );
      expect(await target.readStatus(), CompanyBootstrapStatus.needsRecovery);
      expect(targetInstallation.canUseCompanyOperations, isFalse);
      await expectLater(target.signIn('1234'), throwsA(isA<Exception>()));
      expect(target.currentSession, isNull);
    },
  );

  test('signed v2 entity fixture requires a live owner and current floors', () async {
    final directory = Directory.systemTemp.createTempSync('company-v2-signer-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final db = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
    );
    addTearDown(db.close);
    final store = _MemoryStore();
    const namespace = 'synthetic.v2-signer';
    final installation = InstallationSecurity(
      store: store,
      namespace: namespace,
    );
    await installation.start(db);
    final enrollment = CompanyEnrollment(installation: installation, db: db);
    final company = await enrollment.create(
      companyName: 'Signer Crew',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'signer recovery phrase 123',
      recoveryFile: File(p.join(directory.path, 'authority.wpca')),
    );

    // Entity authoring belongs to later Jobs adoption. This root-signed fixture
    // only exercises the current v2 assertion, signer and command boundaries.
    final line = const Uuid().v4();
    final request = const Uuid().v4();
    final job = const Uuid().v4();
    final now = DateTime.utc(2026, 1, 1);
    await db
        .into(db.jobs)
        .insert(
          JobsCompanion.insert(
            id: job,
            name: 'Test-only job',
            originDeviceId: company.deviceId,
            createdAt: now,
            modifiedAt: now,
          ),
        );
    await db
        .into(db.jobLines)
        .insert(
          JobLinesCompanion.insert(
            id: line,
            jobId: job,
            customName: const Value('Test-only line'),
            neededQty: 1,
            originDeviceId: company.deviceId,
            createdAt: now,
            modifiedAt: now,
          ),
        );
    final baseline = jobLineLegacyBaselineCommitment(
      companyId: company.companyId,
      shopId: company.shopId,
      row: await db.select(db.jobLines).getSingle(),
    );
    final originalFact = await db.select(db.companyAuthorityFacts).getSingle();
    final signed = jsonDecode(originalFact.signedBytes) as Map<String, dynamic>;
    final body = signed['body'] as Map<String, dynamic>;
    body['entities'] = [
      {
        'kind': 'jobLine',
        'id': line,
        'shop': company.shopId,
        'baseline': baseline,
      },
      {'kind': 'job', 'id': job, 'shop': company.shopId},
    ];
    final newCommitment = hashes.sha256
        .convert(utf8.encode(_canonical(body)))
        .toString();
    final companionNamespace = companyCustodyNamespace(namespace);
    final companionState = store.states[companionNamespace]!;
    final custody =
        jsonDecode(utf8.decode(companionState.bytes)) as Map<String, dynamic>;
    final rootPair = await Ed25519().newKeyPairFromSeed(
      base64Decode(custody['rootSeed'] as String),
    );
    final signature = await Ed25519().sign(
      utf8.encode('wiredpart.company.facts@2:${_canonical(body)}'),
      keyPair: rootPair,
    );
    await db.customStatement(
      'UPDATE company_authority_facts SET commitment = ?, signed_bytes = ? WHERE company_id = ?',
      [
        newCommitment,
        _canonical({'body': body, 'signature': base64Encode(signature.bytes)}),
        company.companyId,
      ],
    );
    await db.customStatement(
      'UPDATE company_bootstrap_witnesses SET facts_commitment = ? WHERE company_id = ?',
      [newCommitment, company.companyId],
    );
    custody['facts'] = newCommitment;
    store.states[companionNamespace] = ProtectedInstallationState(
      const Uuid().v4(),
      Uint8List.fromList(utf8.encode(jsonEncode(custody))),
    );
    final baseState = store.states[namespace]!;
    final base =
        jsonDecode(utf8.decode(baseState.bytes)) as Map<String, dynamic>;
    (base['companyTrust'] as Map<String, dynamic>)['facts'] = newCommitment;
    store.states[namespace] = ProtectedInstallationState(
      const Uuid().v4(),
      Uint8List.fromList(utf8.encode(jsonEncode(base))),
    );
    await installation.start(db);
    expect(installation.canUseCompanyOperations, isTrue);

    final owner = await enrollment.signIn('1234');
    final command = JobLineCommand(
      companyId: company.companyId,
      shopId: company.shopId,
      lineId: line,
      requestId: request,
      observedHeads: const [],
      mutation: const JobLinePatch(notes: SetField('fixture edit')),
    );
    final verified = await enrollment.issueJobLineAssertion(command);
    final identity = installation.identity!;
    final operation = Uint8List.fromList(
      utf8.encode(
        _canonical({
          'v': 1,
          'contract': 'job.line.patch@1',
          'company': company.companyId,
          'shop': company.shopId,
          'line': line,
          'request': request,
          'generation': identity.generation.value,
          'installation': identity.id.value,
          'device': company.deviceId,
          'user': company.userId,
          'parents': <String>[],
          'baseline': baseline,
          'units': {'notes': 'fixture edit'},
          'command': command.commitment,
          'facts': newCommitment,
        }),
      ),
    );
    expect(
      (await installation.signCompanyOperation(
        db,
        verified,
        operation,
        ownerSession: owner,
      )).bytes,
      hasLength(64),
    );
    final authorization = JobLineAuthorization(
      db: db,
      installation: installation,
    );
    await expectLater(
      JobLineCommands(authorization: authorization)
          .patchJobLine(verified, command),
      throwsA(isA<JobLineRefusal>()),
    );
    Future<String> businessAndHistory() async => _canonical({
      'line': (await db.select(db.jobLines).getSingle()).toJson(),
      'baselines': (await db.select(db.jobLineBaselines).get())
          .map((row) => row.toJson())
          .toList(),
      'operations': (await db.select(db.jobLineOperations).get())
          .map((row) => row.toJson())
          .toList(),
      'receipts': (await db.select(db.jobLineReceipts).get())
          .map((row) => row.toJson())
          .toList(),
      'audits': (await db.select(db.jobLineAudits).get())
          .map((row) => row.toJson())
          .toList(),
      'outgoing': (await db.select(db.jobLineOutgoing).get())
          .map((row) => row.toJson())
          .toList(),
      'conflicts': (await db.select(db.jobLineConflicts).get())
          .map((row) => row.toJson())
          .toList(),
    });
    final beforeRace = await businessAndHistory();
    Future<void>? signOutDuringCommit;
    var reachedBeforeCommit = false;
    final racingCommands = JobLineCommands(
      authorization: authorization,
      beforeCommit: () async {
        reachedBeforeCommit = true;
        signOutDuringCommit = enrollment.signOut();
        await Future<void>.delayed(Duration.zero);
      },
    );
    Object? racingError;
    try {
      await racingCommands.patchJobLine(verified, command, ownerSession: owner);
    } catch (error) {
      racingError = error;
    }
    expect(reachedBeforeCommit, isTrue, reason: '$racingError');
    expect(racingError, anyOf(isA<StateError>(), isA<JobLineRefusal>()));
    await signOutDuringCommit;
    expect(await businessAndHistory(), beforeRace);
    expect(enrollment.currentSession, isNull);
    await enrollment.signOut();
    await expectLater(
      installation.signCompanyOperation(
        db,
        verified,
        operation,
        ownerSession: owner,
      ),
      throwsA(anyOf(isA<StateError>(), isA<JobLineRefusal>())),
    );
    await expectLater(
      JobLineCommands(
        authorization: JobLineAuthorization(db: db, installation: installation),
      ).patchJobLine(verified, command, ownerSession: owner),
      throwsA(anyOf(isA<StateError>(), isA<JobLineRefusal>())),
    );

    final nextOwner = await enrollment.signIn('1234');
    final nextVerified = await enrollment.issueJobLineAssertion(command);
    expect(
      (await JobLineCommands(
        authorization: authorization,
      ).patchJobLine(nextVerified, command, ownerSession: nextOwner)).status,
      'applied',
    );
    final changedBaseState = store.states[namespace]!;
    final changedBase =
        jsonDecode(utf8.decode(changedBaseState.bytes)) as Map<String, dynamic>;
    (changedBase['floors']
            as Map<String, dynamic>)['permission.${company.userId}'] =
        2;
    store.states[namespace] = ProtectedInstallationState(
      const Uuid().v4(),
      Uint8List.fromList(utf8.encode(jsonEncode(changedBase))),
    );
    await expectLater(
      installation.signCompanyOperation(
        db,
        nextVerified,
        operation,
        ownerSession: nextOwner,
      ),
      throwsA(anyOf(isA<StateError>(), isA<JobLineRefusal>())),
    );
  });
}
