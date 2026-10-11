import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../data/app_database.dart';

const kInstallationBindingKey = 'local_installation_binding_v1';
const kInstallationStateLimit = 2048;

extension type InstallationId(String value) {}

extension type InstallationGeneration(String value) {}

extension type ReceivingStoreGeneration(String value) {}

extension type CompanyId(String value) {}

extension type ShopId(String value) {}

extension type UserId(String value) {}

extension type DeviceId(String value) {}

enum InstallationActivation { unjoined, pending, active, needsRecovery }

enum InstallationReadiness { unsupported, unavailable, needsRecovery, ready }

class InstallationIdentity {
  const InstallationIdentity(
    this.id,
    this.generation,
    this.keyReference,
    this.publicKey,
  );
  final InstallationId id;
  final InstallationGeneration generation;
  final String keyReference;
  final Uint8List publicKey;
}

class ProtectedInstallationState {
  ProtectedInstallationState(this.revision, Uint8List bytes)
    : bytes = Uint8List.fromList(bytes);
  final String revision;
  final Uint8List bytes;
}

abstract interface class InstallationSecureStore {
  Future<ProtectedInstallationState?> readState(String namespace);
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  });
}

class NativeInstallationSecureStore implements InstallationSecureStore {
  const NativeInstallationSecureStore();
  static const _channel = MethodChannel('wired_parts/installation_security');

  Future<Map<String, Object?>?> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.windows &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      throw MissingPluginException('Installation security is unsupported');
    }
    try {
      return await _channel.invokeMapMethod<String, Object?>(method, arguments);
    } on MissingPluginException {
      throw PlatformException(code: 'installation_unavailable');
    }
  }

  @override
  Future<ProtectedInstallationState?> readState(String namespace) async {
    validateInstallationNamespace(namespace);
    final result = await _invoke('readState', {'namespace': namespace});
    if (result == null) return null;
    final revision = result['revision'];
    final bytes = result['bytes'];
    if (revision is! String ||
        !Uuid.isValidUUID(fromString: revision) ||
        bytes is! Uint8List ||
        bytes.length > kInstallationStateLimit) {
      throw StateError('Invalid protected installation state');
    }
    return ProtectedInstallationState(revision, bytes);
  }

  @override
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  }) async {
    validateInstallationNamespace(namespace);
    if (bytes.length > kInstallationStateLimit) {
      throw StateError('Protected installation state is full');
    }
    final result = await _invoke('compareAndSwapState', {
      'namespace': namespace,
      'expectedRevision': expectedRevision,
      'nextRevision': nextRevision,
      'bytes': bytes,
    });
    if (result?['revision'] != nextRevision) {
      throw StateError('Protected installation write was not confirmed');
    }
    return nextRevision;
  }
}

void validateInstallationNamespace(String namespace) {
  if (namespace.length > 64 ||
      !(namespace == 'production' ||
          RegExp(r'^synthetic\.[a-z0-9][a-z0-9._-]*$').hasMatch(namespace))) {
    throw ArgumentError.value(
      namespace,
      'namespace',
      'Invalid installation namespace',
    );
  }
}

class InstallationRestoreIntent {
  const InstallationRestoreIntent._(this.binding);
  final String binding;
}

class _InstallationRecord {
  const _InstallationRecord(
    this.identity,
    this.seed,
    this.activation,
    this.storeGeneration,
    this.floors, [
    this.previousStoreGeneration,
  ]);
  final InstallationIdentity identity;
  final Uint8List seed;
  final InstallationActivation activation;
  final ReceivingStoreGeneration storeGeneration;
  final Map<String, int> floors;
  final ReceivingStoreGeneration? previousStoreGeneration;

  _InstallationRecord withActivation(InstallationActivation activation) =>
      _InstallationRecord(
        identity,
        seed,
        activation,
        storeGeneration,
        floors,
        activation == InstallationActivation.active
            ? null
            : previousStoreGeneration,
      );

  String get binding => jsonEncode({
    'v': 1,
    'id': identity.id.value,
    'generation': identity.generation.value,
    'key': identity.keyReference,
    'public': base64Encode(identity.publicKey),
    'store': storeGeneration.value,
  });

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'id': identity.id.value,
        'generation': identity.generation.value,
        'key': identity.keyReference,
        'public': base64Encode(identity.publicKey),
        'seed': base64Encode(seed),
        'activation': activation.name,
        'store': storeGeneration.value,
        'floors': floors,
        'previousStore': previousStoreGeneration?.value,
      }),
    ),
  );

  static _InstallationRecord decode(Uint8List bytes) {
    if (bytes.length > kInstallationStateLimit) {
      throw const FormatException('Protected state exceeds capacity');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['v'] != 1 ||
        value.length != 10) {
      throw const FormatException('Unsupported protected installation state');
    }
    String id(String key) {
      final item = value[key];
      if (item is! String || !Uuid.isValidUUID(fromString: item)) {
        throw FormatException('Invalid $key');
      }
      return item;
    }

    Uint8List keyBytes(String key) {
      final item = value[key];
      if (item is! String) throw FormatException('Invalid $key');
      final decoded = base64Decode(item);
      if (decoded.length != 32) throw FormatException('Invalid $key');
      return decoded;
    }

    final rawFloors = value['floors'];
    if (rawFloors is! Map<String, dynamic>) {
      throw const FormatException('Invalid security floors');
    }
    final floors = <String, int>{};
    for (final entry in rawFloors.entries) {
      if (entry.key.isEmpty ||
          entry.value is! int ||
          (entry.value as int) < 0) {
        throw const FormatException('Invalid security floor');
      }
      floors[entry.key] = entry.value as int;
    }
    return _InstallationRecord(
      InstallationIdentity(
        InstallationId(id('id')),
        InstallationGeneration(id('generation')),
        id('key'),
        keyBytes('public'),
      ),
      keyBytes('seed'),
      InstallationActivation.values.byName(value['activation'] as String),
      ReceivingStoreGeneration(id('store')),
      Map.unmodifiable(floors),
      value['previousStore'] == null
          ? null
          : ReceivingStoreGeneration(id('previousStore')),
    );
  }
}

class InstallationSecurity {
  InstallationSecurity({required this.store, required this.namespace}) {
    validateInstallationNamespace(namespace);
  }
  final InstallationSecureStore store;
  final String namespace;
  InstallationReadiness readiness = InstallationReadiness.unavailable;
  InstallationIdentity? identity;
  String? failure;
  ProtectedInstallationState? _persisted;
  _InstallationRecord? _record;

  // Enrollment is a separate protocol. A ready local key conveys no authority.
  bool get canUseCompanyOperations => false;

  Future<void> start(AppDatabase db) async {
    readiness = InstallationReadiness.unavailable;
    failure = null;
    try {
      _persisted = await store.readState(namespace);
      final binding = await db.settingsDao.getSetting(kInstallationBindingKey);
      if (_persisted == null) {
        if (binding != null) {
          throw StateError(
            'Protected identity is missing; recovery is required',
          );
        }
        _record = await _newRecord(const {});
        await _write(_record!);
        await db.settingsDao.setSetting(
          kInstallationBindingKey,
          _record!.binding,
        );
      } else {
        _record = _InstallationRecord.decode(_persisted!.bytes);
      }
      await reconcile(db);
    } on MissingPluginException {
      readiness = InstallationReadiness.unsupported;
      failure = 'Installation security is unavailable on this platform';
    } on PlatformException catch (error) {
      readiness = InstallationReadiness.unavailable;
      failure = 'Installation security is unavailable (${error.code})';
    } catch (_) {
      readiness = InstallationReadiness.needsRecovery;
      failure = 'Installation identity needs recovery';
    }
  }

  Future<_InstallationRecord> _newRecord(Map<String, int> floors) async {
    final pair = await Ed25519().newKeyPair();
    final seed = Uint8List.fromList(await pair.extractPrivateKeyBytes());
    final publicKey = await pair.extractPublicKey();
    const uuid = Uuid();
    return _InstallationRecord(
      InstallationIdentity(
        InstallationId(uuid.v4()),
        InstallationGeneration(uuid.v4()),
        uuid.v4(),
        Uint8List.fromList(publicKey.bytes),
      ),
      seed,
      InstallationActivation.pending,
      ReceivingStoreGeneration(uuid.v4()),
      floors,
    );
  }

  Future<void> _write(_InstallationRecord next) async {
    final bytes = next.encode();
    if (bytes.length > kInstallationStateLimit) {
      throw StateError('Protected installation state is full');
    }
    final revision = const Uuid().v4();
    await store.compareAndSwapState(
      namespace,
      expectedRevision: _persisted?.revision,
      nextRevision: revision,
      bytes: bytes,
    );
    _persisted = ProtectedInstallationState(revision, bytes);
    _record = next;
  }

  Future<void> reconcile(AppDatabase db) async {
    readiness = InstallationReadiness.needsRecovery;
    final persisted = await store.readState(namespace);
    if (persisted == null) throw StateError('Protected identity is missing');
    _persisted = persisted;
    final record = _InstallationRecord.decode(persisted.bytes);
    _record = record;
    identity = record.identity;
    if (record.activation == InstallationActivation.needsRecovery ||
        record.activation == InstallationActivation.unjoined ||
        await db.settingsDao.getSetting(kInstallationBindingKey) !=
            record.binding) {
      failure = 'Installation binding needs recovery';
      return;
    }
    final algorithm = Ed25519();
    final pair = await algorithm.newKeyPairFromSeed(record.seed);
    final challenge = utf8.encode(const Uuid().v4());
    final signature = await algorithm.sign(challenge, keyPair: pair);
    final proof = Signature(
      signature.bytes,
      publicKey: SimplePublicKey(
        record.identity.publicKey,
        type: KeyPairType.ed25519,
      ),
    );
    if (!await algorithm.verify(challenge, signature: proof)) {
      throw StateError('Installation key proof failed');
    }
    if (record.activation == InstallationActivation.pending) {
      await _write(record.withActivation(InstallationActivation.active));
    }
    readiness = InstallationReadiness.ready;
    failure = null;
  }

  Future<InstallationRestoreIntent?> prepareBusinessRestore(
    AppDatabase db,
  ) async {
    if (readiness == InstallationReadiness.unsupported) return null;
    if (readiness == InstallationReadiness.unavailable) {
      throw StateError('Installation security is unavailable');
    }
    await reconcile(db);
    if (readiness != InstallationReadiness.ready) {
      throw StateError('Recover installation identity before restoring');
    }
    final record = _record!;
    await _write(
      _InstallationRecord(
        record.identity,
        record.seed,
        InstallationActivation.pending,
        ReceivingStoreGeneration(const Uuid().v4()),
        record.floors,
        record.storeGeneration,
      ),
    );
    readiness = InstallationReadiness.needsRecovery;
    return InstallationRestoreIntent._(_record!.binding);
  }

  Future<void> prepareReset() async {
    if (readiness == InstallationReadiness.unsupported) return;
    if (readiness == InstallationReadiness.unavailable) {
      throw StateError('Installation security is unavailable');
    }
    final persisted = await store.readState(namespace);
    if (persisted == null) throw StateError('Protected identity is missing');
    _persisted = persisted;
    final previous = _InstallationRecord.decode(persisted.bytes);
    await _write(await _newRecord(previous.floors));
    readiness = InstallationReadiness.needsRecovery;
  }

  Future<void> completeReset(AppDatabase db) async {
    if (readiness == InstallationReadiness.unsupported) return;
    await db.settingsDao.setSetting(kInstallationBindingKey, _record!.binding);
    await reconcile(db);
  }

  Future<void> abortBusinessRestore(
    AppDatabase db,
    InstallationRestoreIntent intent,
  ) async {
    final persisted = await store.readState(namespace);
    if (persisted == null) throw StateError('Protected identity is missing');
    final pending = _InstallationRecord.decode(persisted.bytes);
    if (pending.activation != InstallationActivation.pending ||
        pending.binding != intent.binding ||
        pending.previousStoreGeneration == null) {
      throw StateError('Restore intent cannot be rolled back');
    }
    final previous = _InstallationRecord(
      pending.identity,
      pending.seed,
      InstallationActivation.active,
      pending.previousStoreGeneration!,
      pending.floors,
    );
    if (await db.settingsDao.getSetting(kInstallationBindingKey) !=
        previous.binding) {
      throw StateError('Previous store binding was not retained');
    }
    _persisted = persisted;
    await _write(previous);
    await reconcile(db);
  }
}
