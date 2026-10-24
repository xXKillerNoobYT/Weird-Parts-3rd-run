import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/company/company_gate.dart';
import 'package:wired_parts/features/company/company_join_page.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';
import 'package:wired_parts/features/shell/home_shell.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';

import 'company_join_test.dart' show JoinTestDiscovery;

final class _Store implements InstallationSecureStore, RecoveryFilePublisher {
  final states = <String, ProtectedInstallationState>{};
  Future<void> Function(String namespace, Uint8List bytes)? beforeCas;
  bool unavailable = false;

  @override
  Future<ProtectedInstallationState?> readState(String namespace) async {
    if (unavailable) throw PlatformException(code: 'installation_unavailable');
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
    // Unit-only adapter; production uses the native single-descriptor writer.
    final file = File(absolutePath);
    await file.create(exclusive: true);
    await file.writeAsBytes(bytes, flush: true);
  }
}

void main() {
  testWidgets(
    'application forwards the passive native controller factory through the unjoined gate',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'company-gate-observer-',
      );
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final store = _Store();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.passive-gate',
      );
      await installation.start(db);
      final discovery = JoinTestDiscovery();
      NearbyController? created;
      String? encounter;
      NearbyController factory(String alias) {
        encounter = alias;
        return created = NearbyController(
          deviceId: alias,
          deviceName: 'Nearby ${alias.substring(0, 6)}',
          discovery: discovery,
          companyJoin: true,
          bindAddress: InternetAddress.loopbackIPv4,
          localIps: () async => ['127.0.0.1'],
        );
      }

      final app = WiredPartsApp(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: await db.settingsDao.ensureDeviceId(),
        installation: installation,
        enableCompanyBootstrap: true,
        reset: LocalDataReset(supportDir: directory),
        createCompanyJoinController: factory,
      );
      try {
        await tester.pumpWidget(app);
        final open = find.byKey(const Key('company-join-open'));
        for (var index = 0; index < 100 && open.evaluate().isEmpty; index++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(open, findsOneWidget);
        expect(
          tester
              .widget<CompanyBootstrapGate>(find.byType(CompanyBootstrapGate))
              .createJoinController,
          same(factory),
        );
        await tester.runAsync(() => tester.tap(open));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final page = tester.widget<CompanyJoinPage>(
          find.byType(CompanyJoinPage),
        );
        expect(page.createController, same(factory));
        expect(encounter, matches(RegExp(r'^[a-f0-9-]{36}$')));
        expect(created!.deviceId, encounter);
        expect(created!.discovery, same(discovery));
        expect(created!.companyJoin, isTrue);
        expect(created!.onJoinMessage, isNotNull);
        expect(created!.companySyncDisclosure, isNull);
        expect(page.approver, isNull);
        expect(page.reconnect, isFalse);
      } finally {
        await tester.runAsync(() async {
          await created?.dispose();
          await discovery.controller.close();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await db.close();
          directory.deleteSync(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets('unjoined gate opens nearby Join without an owner session', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('company-gate-join-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      directory.deleteSync(recursive: true);
    });
    final store = _Store();
    const namespace = 'synthetic.unjoined-gate-join';
    final installation = InstallationSecurity(
      store: store,
      namespace: namespace,
    );
    await installation.start(db);
    expect(
      await CompanyEnrollment(installation: installation, db: db).readStatus(),
      CompanyBootstrapStatus.unjoined,
    );
    final before = Map.of(store.states);
    await tester.pumpWidget(
      MaterialApp(
        home: CompanyBootstrapGate(
          db: db,
          installation: installation,
          supportDirectory: directory,
        ),
      ),
    );
    final open = find.byKey(const Key('company-join-open'));
    for (var i = 0; i < 80 && open.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(open, findsOneWidget);
    await tester.runAsync(() => tester.tap(open));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CompanyJoinPage), findsOneWidget);
    final page = tester.widget<CompanyJoinPage>(find.byType(CompanyJoinPage));
    expect(page.approver, isNull);
    expect(page.reconnect, isFalse);
    expect(page.enrollment.currentCompanySession, isNull);
    expect(find.text('Join company nearby'), findsOneWidget);
    expect(find.byKey(const Key('company-join-approve')), findsNothing);
    expect(
      await tester.runAsync(page.enrollment.readStatus),
      CompanyBootstrapStatus.unjoined,
    );
    expect(store.states.keys, before.keys);
    for (final entry in before.entries) {
      expect(store.states[entry.key]!.revision, entry.value.revision);
      expect(store.states[entry.key]!.bytes, entry.value.bytes);
    }
    expect(
      await tester.runAsync(() => db.select(db.companyAuthorityFacts).get()),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {});
    await tester.pump();
  });

  testWidgets(
    'Create requires a matching new recovery passphrase confirmation',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('confirm-create-');
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await db.close();
        directory.deleteSync(recursive: true);
      });
      final store = _Store();
      const namespace = 'synthetic.confirm-create';
      final installation = InstallationSecurity(
        store: store,
        namespace: namespace,
      );
      await installation.start(db);
      final initialBase = store.states[namespace]!;
      final destination = File(p.join(directory.path, 'authority.wpca'));
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: await db.settingsDao.ensureDeviceId(),
          installation: installation,
          enableCompanyBootstrap: true,
          pickCompanyRecoveryPath: () async => destination.path,
          reset: LocalDataReset(supportDir: directory),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('company-name')),
        'Confirm Crew',
      );
      await tester.enterText(find.byKey(const Key('company-pin')), '1234');
      await tester.enterText(
        find.byKey(const Key('recovery-passphrase')),
        'confirm create authority phrase',
      );
      await tester.ensureVisible(
        find.byKey(const Key('local-continuity-consent')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('local-continuity-consent')));
      await tester.ensureVisible(
        find.byKey(const Key('authority-only-consent')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('authority-only-consent')));
      await tester.scrollUntilVisible(
        find.text('Choose encrypted recovery file'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Choose encrypted recovery file'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('create-company')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('create-company')));
      await tester.pumpAndSettle();
      expect(
        find.text('Confirm the new recovery passphrase exactly.'),
        findsOneWidget,
      );
      expect(
        store.states.containsKey(companyCustodyNamespace(namespace)),
        isFalse,
      );
      expect(store.states[namespace]!.revision, initialBase.revision);
      expect(store.states[namespace]!.bytes, initialBase.bytes);
      expect(await db.select(db.companyAuthorityFacts).get(), isEmpty);
      expect(await db.select(db.companyBootstrapWitnesses).get(), isEmpty);
      expect(destination.existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('replacement Recover refuses mismatched new passphrases', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('confirm-recover-');
    final sourceDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'source.sqlite'))),
    );
    final targetDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'target.sqlite'))),
    );
    addTearDown(() async {
      await sourceDb.close();
      await targetDb.close();
      directory.deleteSync(recursive: true);
    });
    final sourceStore = _Store();
    final sourceInstallation = InstallationSecurity(
      store: sourceStore,
      namespace: 'synthetic.confirm-recover-source',
    );
    await sourceInstallation.start(sourceDb);
    final sourceFile = File(p.join(directory.path, 'source.wpca'));
    await tester.runAsync(
      () => CompanyEnrollment(installation: sourceInstallation, db: sourceDb)
          .create(
            companyName: 'Confirm Recovery Crew',
            policy: CompanyContinuityPolicy.localContinuity,
            pin: '1234',
            recoveryPassphrase: 'confirm source authority phrase',
            recoveryFile: sourceFile,
          ),
    );
    final targetStore = _Store();
    const targetNamespace = 'synthetic.confirm-recover-target';
    final targetInstallation = InstallationSecurity(
      store: targetStore,
      namespace: targetNamespace,
    );
    await targetInstallation.start(targetDb);
    final initialBase = targetStore.states[targetNamespace]!;
    final destination = File(p.join(directory.path, 'replacement.wpca'));
    await tester.pumpWidget(
      WiredPartsApp(
        db: targetDb,
        pin: PinService(targetDb.settingsDao),
        deviceId: await targetDb.settingsDao.ensureDeviceId(),
        installation: targetInstallation,
        enableCompanyBootstrap: true,
        pickCompanySourcePath: () async => sourceFile.path,
        pickCompanyRecoveryPath: () async => destination.path,
        reset: LocalDataReset(supportDir: directory),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('switch-company-recovery')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-source-package')));
    await tester.enterText(
      find.byKey(const Key('source-passphrase')),
      'confirm source authority phrase',
    );
    await tester.enterText(find.byKey(const Key('company-pin')), '0123');
    await tester.enterText(
      find.byKey(const Key('recovery-passphrase')),
      'confirm replacement authority phrase',
    );
    final confirmation = find.byKey(const Key('recovery-passphrase-confirm'));
    if (confirmation.evaluate().isNotEmpty) {
      await tester.enterText(confirmation, 'different replacement phrase');
    }
    await tester.ensureVisible(
      find.byKey(const Key('local-continuity-consent')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('local-continuity-consent')));
    await tester.ensureVisible(find.byKey(const Key('authority-only-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authority-only-consent')));
    await tester.scrollUntilVisible(
      find.text('Choose encrypted recovery file'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose encrypted recovery file'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('create-company')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('create-company')));
    for (
      var attempt = 0;
      attempt < 40 &&
          find
              .text('Confirm the new recovery passphrase exactly.')
              .evaluate()
              .isEmpty &&
          !destination.existsSync();
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(
      find.text('Confirm the new recovery passphrase exactly.'),
      findsOneWidget,
    );
    expect(
      targetStore.states.containsKey(companyCustodyNamespace(targetNamespace)),
      isFalse,
    );
    expect(targetStore.states[targetNamespace]!.revision, initialBase.revision);
    expect(targetStore.states[targetNamespace]!.bytes, initialBase.bytes);
    expect(
      await targetDb.select(targetDb.companyAuthorityFacts).get(),
      isEmpty,
    );
    expect(
      await targetDb.select(targetDb.companyBootstrapWitnesses).get(),
      isEmpty,
    );
    expect(destination.existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cold pending recovery reopens on Recover and can finish', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'pending-recover-gate-',
    );
    final sourceDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'source.sqlite'))),
    );
    var targetDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'target.sqlite'))),
    );
    addTearDown(() async {
      await sourceDb.close();
      await targetDb.close();
      directory.deleteSync(recursive: true);
    });
    final sourceStore = _Store();
    final sourceInstallation = InstallationSecurity(
      store: sourceStore,
      namespace: 'synthetic.pending-gate-source',
    );
    await sourceInstallation.start(sourceDb);
    final sourceFile = File(p.join(directory.path, 'source.wpca'));
    await tester.runAsync(
      () => CompanyEnrollment(installation: sourceInstallation, db: sourceDb)
          .create(
            companyName: 'Pending Recovery Crew',
            policy: CompanyContinuityPolicy.localContinuity,
            pin: '1234',
            recoveryPassphrase: 'pending gate source phrase',
            recoveryFile: sourceFile,
          ),
    );

    final store = _Store();
    const namespace = 'synthetic.pending-gate-target';
    var installation = InstallationSecurity(store: store, namespace: namespace);
    await installation.start(targetDb);
    final destination = File(p.join(directory.path, 'replacement.wpca'));
    var interrupted = false;
    store.beforeCas = (name, bytes) async {
      if (interrupted || name != companyCustodyNamespace(namespace)) return;
      final next = jsonDecode(utf8.decode(bytes)) as Map;
      if (next['facts'] != null) {
        interrupted = true;
        throw StateError('simulated recovery facts rollback');
      }
    };
    await tester.runAsync(
      () => expectLater(
        CompanyEnrollment(installation: installation, db: targetDb).recover(
          policy: CompanyContinuityPolicy.localContinuity,
          sourceFile: sourceFile,
          sourcePassphrase: 'pending gate source phrase',
          newPin: '0123',
          newRecoveryPassphrase: 'pending gate replacement phrase',
          newRecoveryFile: destination,
        ),
        throwsA(isA<StateError>()),
      ),
    );
    expect(interrupted, isTrue);
    store.beforeCas = null;
    await targetDb.close();
    targetDb = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, 'target.sqlite'))),
    );
    installation = InstallationSecurity(store: store, namespace: namespace);
    await installation.start(targetDb);
    expect(
      await CompanyEnrollment(
        installation: installation,
        db: targetDb,
      ).readStatus(),
      CompanyBootstrapStatus.pendingRecovery,
    );
    await tester.pumpWidget(
      WiredPartsApp(
        db: targetDb,
        pin: PinService(targetDb.settingsDao),
        deviceId: await targetDb.settingsDao.ensureDeviceId(),
        installation: installation,
        enableCompanyBootstrap: true,
        pickCompanySourcePath: () async => sourceFile.path,
        pickCompanyRecoveryPath: () async => destination.path,
        reset: LocalDataReset(supportDir: directory),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Finish authority recovery'), findsOneWidget);
    expect(find.byKey(const Key('choose-source-package')), findsOneWidget);
    expect(find.byKey(const Key('company-name')), findsNothing);
    await tester.tap(find.byKey(const Key('choose-source-package')));
    await tester.enterText(
      find.byKey(const Key('source-passphrase')),
      'pending gate source phrase',
    );
    await tester.enterText(find.byKey(const Key('company-pin')), '0123');
    await tester.enterText(
      find.byKey(const Key('recovery-passphrase')),
      'pending gate replacement phrase',
    );
    await tester.enterText(
      find.byKey(const Key('recovery-passphrase-confirm')),
      'pending gate replacement phrase',
    );
    await tester.ensureVisible(
      find.byKey(const Key('local-continuity-consent')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('local-continuity-consent')));
    await tester.ensureVisible(find.byKey(const Key('authority-only-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authority-only-consent')));
    await tester.scrollUntilVisible(
      find.text('Choose encrypted recovery file'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Choose encrypted recovery file'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('create-company')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('create-company')));
    await tester.binding.setSurfaceSize(const Size(800, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (
      var attempt = 0;
      attempt < 50 && find.textContaining('Company ID:').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.textContaining('Company ID:'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('company-signout')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('company-signout')), findsOneWidget);
    expect(destination.existsSync(), isTrue);
    expect(find.text('Parts'), findsNothing);
    expect(find.text('Jobs'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unavailable desktop security never enters legacy routes', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final installation = InstallationSecurity(
      store: _Store()..unavailable = true,
      namespace: 'synthetic.unavailable-gate',
    );
    await installation.start(db);
    expect(installation.readiness, InstallationReadiness.unavailable);
    final support = Directory.systemTemp.createTempSync('unavailable-gate-');
    addTearDown(() => support.deleteSync(recursive: true));
    await tester.pumpWidget(
      WiredPartsApp(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: await db.settingsDao.ensureDeviceId(),
        installation: installation,
        enableCompanyBootstrap: true,
        reset: LocalDataReset(supportDir: support),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Company recovery needed'), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final marker in [
      'empty',
      'legacy',
      'facts',
      'witness',
      'history',
      'binding',
    ]) {
      testWidgets('$platform $marker routes only clean legacy to HomeShell', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        if (marker == 'legacy') {
          await db.customStatement(
            "INSERT INTO categories (id, origin_device_id, created_at, modified_at, revision, name) "
            "VALUES ('legacy-category', 'old-device', 1, 1, 1, 'Electrical')",
          );
        } else if (marker == 'facts') {
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
        } else if (marker == 'binding') {
          await db.settingsDao.setSetting(
            kInstallationBindingKey,
            'copied-installation-binding',
          );
        }
        final installation = InstallationSecurity(
          store: const NativeInstallationSecureStore(),
          namespace: 'synthetic.unsupported-$marker',
        );
        await installation.start(db);
        debugDefaultTargetPlatformOverride = null;
        expect(installation.readiness, InstallationReadiness.unsupported);
        final support = Directory.systemTemp.createTempSync('mobile-gate-');
        addTearDown(() => support.deleteSync(recursive: true));
        await tester.pumpWidget(
          WiredPartsApp(
            db: db,
            pin: PinService(db.settingsDao),
            deviceId: await db.settingsDao.ensureDeviceId(),
            installation: installation,
            enableCompanyBootstrap: true,
            reset: LocalDataReset(supportDir: support),
          ),
        );
        await tester.pumpAndSettle();
        if (marker == 'empty' || marker == 'legacy') {
          expect(find.byType(HomeShell), findsOneWidget);
          expect(find.text('Jobs'), findsWidgets);
          expect(find.text('Catalog'), findsWidgets);
        } else {
          expect(find.text('Company recovery needed'), findsOneWidget);
          expect(find.byType(HomeShell), findsNothing);
          expect(find.text('Jobs'), findsNothing);
          expect(find.text('Catalog'), findsNothing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final marker in ['facts', 'witness', 'query failure']) {
    testWidgets('ready desktop $marker never opens legacy routes', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final installation = InstallationSecurity(
        store: _Store(),
        namespace: 'synthetic.ready-${marker.replaceAll(' ', '-')}',
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
      } else {
        await db.customStatement('DROP TABLE company_bootstrap_witnesses');
      }
      final support = Directory.systemTemp.createTempSync('ready-gate-');
      addTearDown(() => support.deleteSync(recursive: true));
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: await db.settingsDao.ensureDeviceId(),
          installation: installation,
          enableCompanyBootstrap: true,
          reset: LocalDataReset(supportDir: support),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Company recovery needed'), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);
      expect(find.text('Jobs'), findsNothing);
      expect(find.text('Catalog'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'Create Company uses its own locked shell and never exposes legacy tabs after sign-out',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('company-gate-');
      final dbFile = File(p.join(directory.path, kSqliteFileName));
      final db = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(() async {
        await db.close();
        directory.deleteSync(recursive: true);
      });
      Future<void> waitFor(bool Function() ready) async {
        for (var attempt = 0; attempt < 40 && !ready(); attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
      }

      final store = _Store();
      final installation = InstallationSecurity(
        store: store,
        namespace: 'synthetic.company-gate',
      );
      await installation.start(db);
      final deviceId = await db.settingsDao.ensureDeviceId();
      final package = File(p.join(directory.path, 'authority.wpca'));
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: deviceId,
          installation: installation,
          enableCompanyBootstrap: true,
          pickCompanyRecoveryPath: () async => package.path,
          reset: LocalDataReset(supportDir: directory),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Create company'), findsWidgets);
      await tester.enterText(
        find.byKey(const Key('company-name')),
        'Jobsite Crew',
      );
      await tester.enterText(find.byKey(const Key('company-pin')), '1234');
      await tester.enterText(
        find.byKey(const Key('recovery-passphrase')),
        'separate recovery phrase 123',
      );
      await tester.enterText(
        find.byKey(const Key('recovery-passphrase-confirm')),
        'separate recovery phrase 123',
      );
      await tester.ensureVisible(
        find.byKey(const Key('local-continuity-consent')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('local-continuity-consent')));
      await tester.ensureVisible(
        find.byKey(const Key('authority-only-consent')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('authority-only-consent')));
      await tester.scrollUntilVisible(
        find.text('Choose encrypted recovery file'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Choose encrypted recovery file'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('create-company')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('create-company')));
      await waitFor(package.existsSync);
      await waitFor(
        () => find.textContaining('Company ID:').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(
        package.existsSync(),
        isTrue,
        reason: find
            .byType(Text)
            .evaluate()
            .map((element) => (element.widget as Text).data ?? '')
            .where((value) => value.isNotEmpty)
            .join(' | '),
      );
      expect(find.text('Jobsite Crew'), findsOneWidget);
      expect(find.textContaining('Company ID:'), findsOneWidget);
      expect(find.text('Parts'), findsNothing);
      expect(find.text('Jobs'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('company-signout')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('company-signout')));
      await tester.pumpAndSettle();
      expect(find.text('Company locked'), findsOneWidget);
      expect(find.textContaining('Company ID:'), findsNothing);
      expect(find.text('Parts'), findsNothing);
      expect(find.text('Jobs'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '9999',
      );
      await tester.tap(find.byKey(const Key('company-signin')));
      await waitFor(
        () => find
            .textContaining('Administrator PIN refused')
            .evaluate()
            .isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('Company locked'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '1234',
      );
      await tester.tap(find.byKey(const Key('company-signin')));
      await waitFor(() => find.text('Jobsite Crew').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Jobsite Crew'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('background during Create leaves active company locked', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'company-background-',
    );
    final db = AppDatabase.forTesting(
      NativeDatabase(File(p.join(directory.path, kSqliteFileName))),
    );
    addTearDown(() async {
      await db.close();
      directory.deleteSync(recursive: true);
    });
    final store = _Store();
    final installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.background-create',
    );
    await installation.start(db);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final destination = File(p.join(directory.path, 'authority.wpca'));
    final entered = Completer<void>();
    final release = Completer<void>();
    store.beforeCas = (namespace, bytes) async {
      if (namespace != companyCustodyNamespace('synthetic.background-create')) {
        return;
      }
      final state = jsonDecode(utf8.decode(bytes)) as Map;
      if (state['digest'] != null && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    await tester.pumpWidget(
      WiredPartsApp(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: deviceId,
        installation: installation,
        enableCompanyBootstrap: true,
        pickCompanyRecoveryPath: () async => destination.path,
        reset: LocalDataReset(supportDir: directory),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('company-name')),
      'Background Crew',
    );
    await tester.enterText(find.byKey(const Key('company-pin')), '1234');
    await tester.enterText(
      find.byKey(const Key('recovery-passphrase')),
      'background recovery phrase',
    );
    await tester.enterText(
      find.byKey(const Key('recovery-passphrase-confirm')),
      'background recovery phrase',
    );
    await tester.ensureVisible(
      find.byKey(const Key('local-continuity-consent')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('local-continuity-consent')));
    await tester.ensureVisible(find.byKey(const Key('authority-only-consent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('authority-only-consent')));
    await tester.scrollUntilVisible(
      find.text('Choose encrypted recovery file'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Choose encrypted recovery file'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('create-company')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('create-company')));
    for (var attempt = 0; attempt < 40 && !entered.isCompleted; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(
      entered.isCompleted,
      isTrue,
      reason: find
          .byType(Text)
          .evaluate()
          .map((element) => (element.widget as Text).data ?? '')
          .where((value) => value.isNotEmpty)
          .join(' | '),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    release.complete();
    for (
      var attempt = 0;
      attempt < 40 && !destination.existsSync();
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(destination.existsSync(), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (
      var attempt = 0;
      attempt < 40 && find.text('Company locked').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      find.text('Company locked'),
      findsOneWidget,
      reason: find
          .byType(Text)
          .evaluate()
          .map((element) => (element.widget as Text).data ?? '')
          .where((value) => value.isNotEmpty)
          .join(' | '),
    );
    expect(find.textContaining('Company ID:'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
