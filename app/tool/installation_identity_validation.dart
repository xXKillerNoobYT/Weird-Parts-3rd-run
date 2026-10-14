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
import 'identity_nearby_receipts.dart';

// Uses the existing guarded synthetic recovery workspaces. It never opens the
// default business directories or writes private key material into receipts.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('RECOVERY_RUN');
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$').hasMatch(run)) {
    throw ArgumentError('A fresh 1-32 character synthetic run is required');
  }
  final action = RecoveryScenario.actionForRun(run);
  const nearbyRole = String.fromEnvironment('IDENTITY_NEARBY_ROLE');
  if (nearbyRole.isNotEmpty &&
      nearbyRole != 'source' &&
      nearbyRole != 'receiver') {
    throw ArgumentError('IDENTITY_NEARBY_ROLE must be source or receiver');
  }
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
  String? senderBindingSha256;
  if (action == RecoveryAction.exercise) {
    await scenario.seed();
    final senderDb = scenario.openDatabase(scenario.source);
    try {
      final sender = security('sender');
      await sender.start(senderDb);
      senderIdentity = identityReceipt(sender);
      senderBindingSha256 = await bindingSha256(senderDb);
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
    Future<void> nearbyValidation() async {
      final nearby = IdentityNearbyReceipts(scenario, nearbyRole);
      Future<Map<String, Object?>> observe() async {
        final pin = scope().pin;
        late bool syntheticPinUnlocks;
        late bool wrongPinRejected;
        try {
          syntheticPinUnlocks = await pin.unlock('1234');
          pin.lock();
          wrongPinRejected = !await pin.unlock('9999');
        } finally {
          pin.lock();
        }
        return {
          'syntheticPinUnlocks': syntheticPinUnlocks,
          'wrongPinRejected': wrongPinRejected,
          'identity': identityReceipt(receiver),
          'floors': await readSecurityFloors(store, receiver.namespace),
          'bindingSha256': await bindingSha256(scope().db),
          'pinSha256': sha256
              .convert(
                utf8.encode(
                  (await scope().db.settingsDao.getSetting(
                        'editor_pin_hash',
                      )) ??
                      '',
                ),
              )
              .toString(),
          'shop': await scenario.receipt(scope().db, scenario.receiver),
        };
      }

      await nearby.captureOrRestart(observe);
    }

    if (nearbyRole.isNotEmpty && action == RecoveryAction.restart) {
      await nearbyValidation();
      return;
    }
    if (action == RecoveryAction.exercise) {
      require(
        before['id'] != senderIdentity!['id'],
        'Installations share an ID',
      );
      require(
        before['publicKeySha256'] != senderIdentity['publicKeySha256'],
        'Installations share a key',
      );
      final localStore = BackupStore(
        supportDir: scenario.receiver.support,
        photosDir: scenario.receiver.photos,
      );
      await checkpointWalForExport(scope().db);
      final localPayload = await localStore.collect(
        sourceDeviceId: scenario.receiver.deviceId,
        createdAt: DateTime.utc(2026, 10, 7),
        sqliteBytes: await (await localStore.sqliteFile()).readAsBytes(),
      );
      const localPassword = 'synthetic identity same-install backup';
      final localArchive = await scenario.codec.encrypt(
        localPayload,
        localPassword,
      );
      await seedSyntheticSecurityFloors(store, receiver, scope().db);
      final localBefore = await scenario.receipt(scope().db, scenario.receiver);
      await scope().restoreFromBackup(localArchive, localPassword);
      await WidgetsBinding.instance.endOfFrame;
      final localAfter = await scenario.receipt(scope().db, scenario.receiver);
      RecoveryScenario.compareShop(
        withoutRestoreMetadata(localBefore),
        withoutRestoreMetadata(localAfter),
      );
      require(
        jsonEncode(before) == jsonEncode(identityReceipt(receiver)),
        'Same-install restore replaced the installation identity',
      );
      final localBinding = await scope().db.settingsDao.getSetting(
        kInstallationBindingKey,
      );
      require(
        localBinding != beforeBinding,
        'Same-install restore reused a receiving-store generation',
      );
      final localFloors = await readSecurityFloors(store, receiver.namespace);
      require(
        jsonEncode(localFloors) == jsonEncode(syntheticSecurityFloors),
        'Same-install restore rolled back protected security floors',
      );
      File(
        p.join(scenario.receiver.receipts.path, 'identity-same-install.json'),
      ).writeAsStringSync(
        jsonEncode({
          'format': 1,
          'run': run,
          'passed': true,
          'identity': identityReceipt(receiver),
          'fixtureSeededFloors': localFloors,
          'archiveSha256': sha256.convert(localArchive).toString(),
          'receivingStoreChanged': true,
          'before': localBefore,
          'after': localAfter,
        }),
        flush: true,
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
        localBinding != afterBinding,
        'Restore reused a receiving-store generation',
      );
      final restoredFloors = await readSecurityFloors(
        store,
        receiver.namespace,
      );
      require(
        jsonEncode(restoredFloors) == jsonEncode(syntheticSecurityFloors),
        'Foreign restore replaced protected security floors',
      );
      manifest.writeAsStringSync(
        jsonEncode({
          'format': 2,
          'run': run,
          'state': 'restored',
          'sender': senderIdentity,
          'senderBindingSha256': senderBindingSha256,
          'receiver': after,
          'fixtureSeededFloors': restoredFloors,
          'bindingSha256': sha256
              .convert(utf8.encode(afterBinding!))
              .toString(),
          'nativeCas': 'passed',
          'sameInstallRestore': 'passed',
        }),
        flush: true,
      );
    } else {
      final saved = jsonDecode(manifest.readAsStringSync()) as Map;
      require(
        saved['format'] == 2 &&
            saved['run'] == run &&
            saved['state'] == 'restored' &&
            saved['sameInstallRestore'] == 'passed',
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
      final restartedFloors = await readSecurityFloors(
        store,
        receiver.namespace,
      );
      require(
        jsonEncode(saved['fixtureSeededFloors']) ==
                jsonEncode(restartedFloors) &&
            jsonEncode(restartedFloors) == jsonEncode(syntheticSecurityFloors),
        'Protected security floors changed across restart',
      );
      final senderDb = scenario.openDatabase(scenario.source);
      try {
        final sender = security('sender');
        await sender.start(senderDb);
        senderIdentity = identityReceipt(sender);
        senderBindingSha256 = await bindingSha256(senderDb);
        require(
          jsonEncode(saved['sender']) == jsonEncode(senderIdentity),
          'Sender identity changed across process restart',
        );
        require(
          saved['senderBindingSha256'] == senderBindingSha256,
          'Sender store binding changed across process restart',
        );
      } finally {
        await senderDb.close();
      }
      await scenario.restart(scope().db);
      File(p.join(scenario.receiver.receipts.path, 'identity-restart.json'))
          .writeAsStringSync(
            jsonEncode({
              'format': 1,
              'run': run,
              'passed': true,
              'receiver': before,
              'sender': senderIdentity,
              'senderBindingSha256': senderBindingSha256,
              'fixtureSeededFloors': restartedFloors,
            }),
            flush: true,
          );
    }
    debugPrint('IDENTITY ${action.name} PASS: ${scenario.receiver.root.path}');
    if (nearbyRole.isNotEmpty) await nearbyValidation();
  } catch (_) {
    exitCode = 1;
    debugPrint('IDENTITY ${action.name} FAIL');
    rethrow;
  }
}

const syntheticSecurityFloors = {
  'authority.test-company': 7,
  'revocation.test-device': 11,
};

Future<void> seedSyntheticSecurityFloors(
  NativeInstallationSecureStore store,
  InstallationSecurity installation,
  AppDatabase db,
) async {
  require(
    installation.namespace.startsWith('synthetic.identity.'),
    'Security-floor fixture requires a synthetic namespace',
  );
  final current = await store.readState(installation.namespace);
  require(current != null, 'Synthetic protected state is missing');
  final record =
      jsonDecode(utf8.decode(current!.bytes)) as Map<String, dynamic>;
  require(
    (record['floors'] as Map).isEmpty,
    'Security-floor fixture requires fresh protected state',
  );
  // Fixture-only CAS matches the focused tests; enrollment is outside this slice.
  record['floors'] = syntheticSecurityFloors;
  await store.compareAndSwapState(
    installation.namespace,
    expectedRevision: current.revision,
    nextRevision: const Uuid().v4(),
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
  );
  await installation.reconcile(db);
  identityReceipt(installation);
  require(
    jsonEncode(await readSecurityFloors(store, installation.namespace)) ==
        jsonEncode(syntheticSecurityFloors),
    'Synthetic security-floor CAS readback differs',
  );
}

Future<Map<String, int>> readSecurityFloors(
  NativeInstallationSecureStore store,
  String namespace,
) async {
  final state = await store.readState(namespace);
  require(state != null, 'Protected security floors are missing');
  final record = jsonDecode(utf8.decode(state!.bytes)) as Map<String, dynamic>;
  return Map<String, int>.from(record['floors'] as Map);
}

Future<String> bindingSha256(AppDatabase db) async {
  final binding = await db.settingsDao.getSetting(kInstallationBindingKey);
  require(binding != null, 'Installation binding is missing');
  return sha256.convert(utf8.encode(binding!)).toString();
}

Map<String, Object?> withoutRestoreMetadata(Map<String, Object?> receipt) {
  final settings = Map<String, Object?>.from(receipt['settings'] as Map)
    ..remove(kInstallationBindingKey)
    ..remove(kLastBackupSourceKey)
    ..remove(kLastBackupAtKey);
  return {...receipt, 'settings': settings};
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
