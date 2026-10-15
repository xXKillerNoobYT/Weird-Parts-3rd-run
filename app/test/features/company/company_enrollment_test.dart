import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

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

final class _MemoryStore
    implements InstallationSecureStore, RecoveryFilePublisher {
  final states = <String, ProtectedInstallationState>{};
  Future<void> Function(String namespace, Uint8List bytes)? beforeCas;
  Future<void> Function(String namespace)? beforeRead;

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
  }
}

void main() {
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
