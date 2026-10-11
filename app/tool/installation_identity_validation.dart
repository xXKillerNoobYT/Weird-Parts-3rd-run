import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import 'backup_recovery_scenario.dart';

// Uses the existing guarded synthetic recovery workspaces. It never opens the
// default business directories or writes private key material into receipts.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('RECOVERY_RUN');
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$').hasMatch(run)) {
    throw ArgumentError('A fresh 1-32 character synthetic run is required');
  }
  final action = RecoveryScenario.actionForRun(run);
  final scenario = RecoveryScenario.open(run: run, action: action);
  PathProviderPlatform.instance = scenario.receiver;
  const store = NativeInstallationSecureStore();
  InstallationSecurity security(String role) => InstallationSecurity(
    store: store,
    namespace: 'synthetic.identity.$run.$role',
  );
  final manifest = File(
    p.join(scenario.receiver.root.path, 'identity-validation.json'),
  );
  final receiver = security('receiver');
  Map<String, Object?>? sourceReceipt;
  Map<String, Object?>? senderIdentity;
  if (action == RecoveryAction.exercise) {
    await scenario.seed();
    final senderDb = scenario.openDatabase(scenario.source);
    try {
      final sender = security('sender');
      await sender.start(senderDb);
      senderIdentity = identityReceipt(sender);
      await checkpointWalForExport(senderDb);
    } finally {
      await senderDb.close();
    }
    sourceReceipt = await scenario.export();
    await nativeCasProof(store, 'synthetic.identity.$run.cas');
  }
  final db = AppDatabase();
  await receiver.start(db);
  final before = identityReceipt(receiver);
  final beforeBinding = await db.settingsDao.getSetting(
    kInstallationBindingKey,
  );
  final appKey = GlobalKey();
  runApp(
    WiredPartsApp(
      key: appKey,
      db: db,
      pin: PinService(db.settingsDao),
      deviceId: await db.settingsDao.ensureDeviceId(),
      installation: receiver,
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  AppScope scope() {
    AppScope? found;
    appKey.currentContext!.visitChildElements((element) {
      if (element.widget is AppScope) found = element.widget as AppScope;
    });
    return found ?? (throw StateError('Production AppScope is missing'));
  }

  try {
    if (action == RecoveryAction.exercise) {
      require(
        before['id'] != senderIdentity!['id'],
        'Installations share an ID',
      );
      require(
        before['publicKeySha256'] != senderIdentity['publicKeySha256'],
        'Installations share a key',
      );
      await scenario.exercise(
        scope: scope,
        settle: () => WidgetsBinding.instance.endOfFrame,
        sourceReceipt: sourceReceipt!,
      );
      final after = identityReceipt(receiver);
      require(
        jsonEncode(before) == jsonEncode(after),
        'Business restore replaced the recipient identity',
      );
      final afterBinding = await scope().db.settingsDao.getSetting(
        kInstallationBindingKey,
      );
      require(
        beforeBinding != afterBinding,
        'Restore reused a receiving-store generation',
      );
      manifest.writeAsStringSync(
        jsonEncode({
          'format': 1,
          'run': run,
          'state': 'restored',
          'sender': senderIdentity,
          'receiver': after,
          'bindingSha256': sha256
              .convert(utf8.encode(afterBinding!))
              .toString(),
          'nativeCas': 'passed',
        }),
        flush: true,
      );
    } else {
      final saved = jsonDecode(manifest.readAsStringSync()) as Map;
      require(
        saved['format'] == 1 &&
            saved['run'] == run &&
            saved['state'] == 'restored',
        'Identity receipt is invalid',
      );
      require(
        jsonEncode(saved['receiver']) == jsonEncode(before),
        'Identity changed across process restart',
      );
      require(
        saved['bindingSha256'] ==
            sha256.convert(utf8.encode(beforeBinding!)).toString(),
        'Receiving-store binding changed across restart',
      );
      await scenario.restart(scope().db);
      File(p.join(scenario.receiver.receipts.path, 'identity-restart.json'))
          .writeAsStringSync(
            jsonEncode({
              'format': 1,
              'run': run,
              'passed': true,
              'receiver': before,
            }),
            flush: true,
          );
    }
    debugPrint('IDENTITY ${action.name} PASS: ${scenario.receiver.root.path}');
  } catch (_) {
    exitCode = 1;
    debugPrint('IDENTITY ${action.name} FAIL');
    rethrow;
  }
}

Map<String, Object?> identityReceipt(InstallationSecurity installation) {
  require(
    installation.readiness == InstallationReadiness.ready,
    'Native installation is not ready: ${installation.failure}',
  );
  require(
    !installation.canUseCompanyOperations,
    'Local identity granted company authority',
  );
  final identity = installation.identity!;
  return {
    'id': identity.id.value,
    'generation': identity.generation.value,
    'publicKeySha256': sha256.convert(identity.publicKey).toString(),
  };
}

Future<void> nativeCasProof(
  NativeInstallationSecureStore store,
  String namespace,
) async {
  require(
    await store.readState(namespace) == null,
    'Native CAS namespace is not fresh',
  );
  final revision = const Uuid().v4();
  final bytes = Uint8List.fromList([1, 2, 3]);
  Future<String> write(String? expected, String next, Uint8List payload) =>
      store.compareAndSwapState(
        namespace,
        expectedRevision: expected,
        nextRevision: next,
        bytes: payload,
      );
  require(
    await write(null, revision, bytes) == revision,
    'Native create was not confirmed',
  );
  require(
    await write(null, revision, bytes) == revision,
    'Lost-response replay was not idempotent',
  );
  Future<void> rejects(
    Future<Object?> Function() operation,
    String code,
  ) async {
    try {
      await operation();
    } on PlatformException catch (error) {
      require(error.code == code, 'Unexpected native refusal code');
      return;
    }
    throw StateError('Native adapter accepted an invalid write');
  }

  await rejects(
    () => write(null, revision, Uint8List.fromList([4])),
    'installation_integrity',
  );
  await rejects(
    () => write(const Uuid().v4(), const Uuid().v4(), bytes),
    'installation_conflict',
  );
  final secondRevision = const Uuid().v4();
  require(
    await write(revision, secondRevision, bytes) == secondRevision,
    'Native CAS update failed',
  );
  final finalState = await store.readState(namespace);
  require(
    finalState?.revision == secondRevision &&
        finalState!.bytes.join(',') == bytes.join(','),
    'Native CAS readback differs',
  );
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
