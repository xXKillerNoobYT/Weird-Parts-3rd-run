import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

final class _Store implements InstallationSecureStore, RecoveryFilePublisher {
  final states = <String, ProtectedInstallationState>{};
  Future<void> Function(String namespace, Uint8List bytes)? beforeCas;

  @override
  Future<ProtectedInstallationState?> readState(String namespace) async =>
      states[namespace];

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
      await tester.tap(find.byKey(const Key('local-continuity-consent')));
      await tester.tap(find.byKey(const Key('authority-only-consent')));
      await tester.ensureVisible(find.text('Choose encrypted recovery file'));
      await tester.tap(find.text('Choose encrypted recovery file'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('create-company')));
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
      await tester.ensureVisible(find.byKey(const Key('company-signout')));
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
    await tester.tap(find.byKey(const Key('local-continuity-consent')));
    await tester.tap(find.byKey(const Key('authority-only-consent')));
    await tester.ensureVisible(find.text('Choose encrypted recovery file'));
    await tester.tap(find.text('Choose encrypted recovery file'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('create-company')));
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
