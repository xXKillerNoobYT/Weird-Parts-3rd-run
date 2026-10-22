import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../data/app_database.dart';
import '../job_line_commands/job_line_commands.dart'
    show
        VerifiedJobLineSession,
        VerifiedJobLineReceiptAdmission,
        JobLineCommandReceipt,
        decodeJobLineReceipt;

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

/// A small pin in protected storage. Signed facts remain in the business DB.
/// This slice reads pins; company enrollment is the separate authorized writer.
final class CompanyTrustAnchor {
  CompanyTrustAnchor({
    required this.companyId,
    required Uint8List rootKey,
    required this.authorityVersion,
    required this.factsCommitment,
    required this.policy,
  }) : _rootKey = Uint8List.fromList(rootKey);
  final CompanyId companyId;
  final Uint8List _rootKey;
  Uint8List get rootKey => Uint8List.fromList(_rootKey);
  final int authorityVersion;
  final String factsCommitment;
  final String policy;
  Map<String, Object?> encode() => {
    'company': companyId.value,
    'root': base64Encode(rootKey),
    'authority': authorityVersion,
    'facts': factsCommitment,
    'policy': policy,
  };
  static CompanyTrustAnchor decode(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 5 ||
        raw['company'] is! String ||
        !Uuid.isValidUUID(fromString: raw['company'] as String) ||
        raw['root'] is! String ||
        raw['authority'] is! int ||
        (raw['authority'] as int) < 1 ||
        raw['facts'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['facts'] as String) ||
        raw['policy'] != 'localContinuity') {
      throw const FormatException('Unsupported company trust anchor');
    }
    final root = base64Decode(raw['root'] as String);
    if (root.length != 32) throw const FormatException('Invalid company root');
    return CompanyTrustAnchor(
      companyId: CompanyId(raw['company'] as String),
      rootKey: root,
      authorityVersion: raw['authority'] as int,
      factsCommitment: raw['facts'] as String,
      policy: 'localContinuity',
    );
  }
}

Future<String> _companyStorePath(AppDatabase db) async {
  final databases = await db.customSelect('PRAGMA database_list').get();
  final main = databases
      .where((r) => r.read<String>('name') == 'main')
      .toList();
  if (main.length != 1 || main.single.read<String>('file').isEmpty) {
    throw StateError('Company operations require one bound file-backed store');
  }
  final resolved = await File(main.single.read<String>('file'))
      .resolveSymbolicLinks();
  final canonical = p.normalize(
    Platform.isWindows ? resolved.toLowerCase() : resolved,
  );
  return hashes.sha256.convert(utf8.encode(canonical)).toString();
}

String _securityCanonical(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(v[key])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

Future<String> _companyCommandWitness(
  AppDatabase db,
  CompanyCommandIntent intent,
) async {
  final evidence = <String, Object?>{};
  for (final table in [
    'job_line_baselines',
    'job_line_operations',
    'job_line_conflicts',
  ]) {
    final rows = await db
        .customSelect(
          'SELECT * FROM $table WHERE company_id = ? AND line_id = ? ORDER BY 1, 2, 3',
          variables: [Variable(intent.companyId), Variable(intent.lineId)],
        )
        .get();
    if (rows.length > 512) {
      throw StateError('Command recovery capacity reached');
    }
    evidence[table] = rows.map((r) => r.data).toList();
  }
  for (final table in ['job_line_receipts', 'job_line_audits']) {
    evidence[table] =
        (await db
                .customSelect(
                  'SELECT * FROM $table WHERE receipt_key = ?',
                  variables: [Variable(intent.receiptKey)],
                )
                .get())
            .map((r) => r.data)
            .toList();
  }
  evidence['outgoing'] =
      (await db
              .customSelect(
                'SELECT * FROM job_line_outgoing WHERE company_id = ? AND origin_generation = ? AND request_id = ?',
                variables: [
                  Variable(intent.companyId),
                  Variable(intent.originGeneration),
                  Variable(intent.requestId),
                ],
              )
              .get())
          .map((r) => r.data)
          .toList();
  evidence['projection'] =
      (await (db.select(
            db.jobLines,
          )..where((t) => t.id.equals(intent.lineId))).get())
          .map((r) => r.toJson())
          .toList();
  final splits = await db
      .customSelect(
        'SELECT * FROM order_splits WHERE job_line_id = ? ORDER BY id LIMIT 513',
        variables: [Variable(intent.lineId)],
      )
      .get();
  if (splits.length > 512) {
    throw StateError('Command recovery capacity reached');
  }
  if (splits.isNotEmpty) {
    evidence['order_splits'] = splits.map((r) => r.data).toList();
  }
  return hashes.sha256
      .convert(utf8.encode(_securityCanonical(evidence)))
      .toString();
}

Future<void> _validateCompanyCommit(
  AppDatabase db,
  CompanyCommandIntent intent,
) async {
  final receipt = await (db.select(
    db.jobLineReceipts,
  )..where((t) => t.receiptKey.equals(intent.receiptKey))).getSingleOrNull();
  final operation =
      await (db.select(db.jobLineOperations)..where(
            (t) =>
                t.companyId.equals(intent.companyId) &
                t.originGeneration.equals(intent.originGeneration) &
                t.requestId.equals(intent.requestId),
          ))
          .getSingleOrNull();
  final audit = await (db.select(
    db.jobLineAudits,
  )..where((t) => t.receiptKey.equals(intent.receiptKey))).getSingleOrNull();
  final baseline =
      await (db.select(db.jobLineBaselines)..where(
            (t) =>
                t.companyId.equals(intent.companyId) &
                t.lineId.equals(intent.lineId),
          ))
          .getSingleOrNull();
  final row = await (db.select(
    db.jobLines,
  )..where((t) => t.id.equals(intent.lineId))).getSingleOrNull();
  if (receipt == null ||
      operation == null ||
      audit == null ||
      baseline == null ||
      row == null ||
      receipt.operationCommitment != intent.operationCommitment ||
      receipt.commandCommitment != intent.commandCommitment ||
      operation.commitment != intent.operationCommitment ||
      operation.lineId != intent.lineId ||
      baseline.projectionBytes != _securityCanonical(row.toJson())) {
    throw StateError('Company commit evidence is incomplete');
  }
  final encodedReceipt = decodeJobLineReceipt(
    receipt.receiptBytes,
    requireSeal: false,
  );
  final encodedOperation =
      jsonDecode(operation.operationBytes) as Map<String, dynamic>;
  final encodedAudit = jsonDecode(audit.auditBytes) as Map<String, dynamic>;
  if (encodedReceipt['key'] != intent.receiptKey ||
      encodedReceipt['operation'] != intent.operationCommitment ||
      encodedReceipt['command'] != intent.commandCommitment ||
      encodedReceipt['store'] != intent.storeGeneration ||
      utf8.decode(base64Decode(encodedReceipt['bytes'] as String)) !=
          operation.operationBytes ||
      hashes.sha256
              .convert(
                utf8.encode(_securityCanonical(encodedOperation['body'])),
              )
              .toString() !=
          operation.commitment ||
      encodedAudit['operation'] != intent.operationCommitment ||
      encodedAudit['receipt'] != intent.receiptKey ||
      encodedAudit['originalUser'] !=
          (encodedOperation['body'] as Map)['user'] ||
      encodedAudit['originalDevice'] !=
          (encodedOperation['body'] as Map)['device'] ||
      encodedAudit['status'] != encodedReceipt['status'] ||
      (encodedReceipt['status'] == 'deferred') == operation.admitted) {
    throw StateError('Company commit receipt or attribution differs');
  }
  if (encodedAudit['outgoing'] == true) {
    final outgoing =
        await (db.select(db.jobLineOutgoing)..where(
              (t) =>
                  t.companyId.equals(intent.companyId) &
                  t.originGeneration.equals(intent.originGeneration) &
                  t.requestId.equals(intent.requestId),
            ))
            .getSingleOrNull();
    if (outgoing?.operationCommitment != intent.operationCommitment) {
      throw StateError('Company commit outgoing record is missing');
    }
  }
}

final class CompanyCommandIntent {
  const CompanyCommandIntent({
    required this.receiptKey,
    required this.operationCommitment,
    required this.commandCommitment,
    required this.storeGeneration,
    required this.companyId,
    required this.lineId,
    required this.originGeneration,
    required this.requestId,
    this.beforeWitness,
    this.afterWitness,
  });
  final String receiptKey;
  final String operationCommitment;
  final String commandCommitment;
  final String storeGeneration;
  final String companyId;
  final String lineId;
  final String originGeneration;
  final String requestId;
  final String? beforeWitness;
  final String? afterWitness;
  CompanyCommandIntent withWitness({String? before, String? after}) =>
      CompanyCommandIntent(
        receiptKey: receiptKey,
        operationCommitment: operationCommitment,
        commandCommitment: commandCommitment,
        storeGeneration: storeGeneration,
        companyId: companyId,
        lineId: lineId,
        originGeneration: originGeneration,
        requestId: requestId,
        beforeWitness: before ?? beforeWitness,
        afterWitness: after ?? afterWitness,
      );
  Map<String, Object?> encode() => {
    'receipt': receiptKey,
    'operation': operationCommitment,
    'command': commandCommitment,
    'store': storeGeneration,
    'company': companyId,
    'line': lineId,
    'origin': originGeneration,
    'request': requestId,
    'before': beforeWitness,
    'after': afterWitness,
  };
  static CompanyCommandIntent decode(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 10 ||
        [
          'receipt',
          'operation',
          'command',
          'store',
          'company',
          'line',
          'origin',
          'request',
        ].any((k) => raw[k] is! String)) {
      throw const FormatException('Invalid pending company command');
    }
    for (final key in ['receipt', 'operation', 'command', 'before', 'after']) {
      if ((key == 'before' || key == 'after') && raw[key] == null) continue;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(raw[key] as String)) {
        throw const FormatException('Invalid pending command commitment');
      }
    }
    for (final key in ['store', 'company', 'line', 'origin', 'request']) {
      if (!Uuid.isValidUUID(fromString: raw[key] as String)) {
        throw const FormatException('Invalid pending command scope');
      }
    }
    return CompanyCommandIntent(
      receiptKey: raw['receipt'] as String,
      operationCommitment: raw['operation'] as String,
      commandCommitment: raw['command'] as String,
      storeGeneration: raw['store'] as String,
      companyId: raw['company'] as String,
      lineId: raw['line'] as String,
      originGeneration: raw['origin'] as String,
      requestId: raw['request'] as String,
      beforeWitness: raw['before'] as String?,
      afterWitness: raw['after'] as String?,
    );
  }
}

final class InstallationIdentity {
  InstallationIdentity(
    this.id,
    this.generation,
    this.keyReference,
    Uint8List publicKey,
  ) : _publicKey = Uint8List.fromList(publicKey);
  final InstallationId id;
  final InstallationGeneration generation;
  final String keyReference;
  final Uint8List _publicKey;
  Uint8List get publicKey => Uint8List.fromList(_publicKey);
}

final class ProtectedInstallationState {
  ProtectedInstallationState(this.revision, Uint8List bytes)
    : _bytes = Uint8List.fromList(bytes);
  final String revision;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
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
    this.floors, {
    this.previousStoreGeneration,
    this.companyTrust,
    this.pendingCommand,
    this.storePathFingerprint,
  });
  final InstallationIdentity identity;
  final Uint8List seed;
  final InstallationActivation activation;
  final ReceivingStoreGeneration storeGeneration;
  final Map<String, int> floors;
  final ReceivingStoreGeneration? previousStoreGeneration;
  final CompanyTrustAnchor? companyTrust;
  final CompanyCommandIntent? pendingCommand;
  final String? storePathFingerprint;

  _InstallationRecord withActivation(InstallationActivation activation) =>
      _InstallationRecord(
        identity,
        seed,
        activation,
        storeGeneration,
        floors,
        previousStoreGeneration: activation == InstallationActivation.active
            ? null
            : previousStoreGeneration,
        companyTrust: companyTrust,
        pendingCommand: pendingCommand,
        storePathFingerprint: storePathFingerprint,
      );

  String get binding => jsonEncode({
    'v': 1,
    'id': identity.id.value,
    'generation': identity.generation.value,
    'key': identity.keyReference,
    'public': base64Encode(identity.publicKey),
    'store': storeGeneration.value,
    if (companyTrust != null) 'storePath': storePathFingerprint,
  });

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': companyTrust == null ? 1 : 2,
        'id': identity.id.value,
        'generation': identity.generation.value,
        'key': identity.keyReference,
        'public': base64Encode(identity.publicKey),
        'seed': base64Encode(seed),
        'activation': activation.name,
        'store': storeGeneration.value,
        'floors': floors,
        'previousStore': previousStoreGeneration?.value,
        if (companyTrust != null) 'companyTrust': companyTrust!.encode(),
        if (companyTrust != null) 'pendingCommand': pendingCommand?.encode(),
        if (companyTrust != null) 'storePath': storePathFingerprint,
      }),
    ),
  );

  static _InstallationRecord decode(Uint8List bytes) {
    if (bytes.length > kInstallationStateLimit) {
      throw const FormatException('Protected state exceeds capacity');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        !((value['v'] == 1 && value.length == 10) ||
            (value['v'] == 2 &&
                value.length == 13 &&
                value['storePath'] is String &&
                RegExp(r'^[a-f0-9]{64}$')
                    .hasMatch(value['storePath'] as String)))) {
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
      previousStoreGeneration: value['previousStore'] == null
          ? null
          : ReceivingStoreGeneration(id('previousStore')),
      companyTrust: value['v'] == 2
          ? CompanyTrustAnchor.decode(value['companyTrust'])
          : null,
      pendingCommand: value['v'] == 2 && value['pendingCommand'] != null
          ? CompanyCommandIntent.decode(value['pendingCommand'])
          : null,
      storePathFingerprint: value['v'] == 2
          ? value['storePath'] as String
          : null,
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

  ReceivingStoreGeneration? get receivingStoreGeneration =>
      _record?.storeGeneration;

  Map<String, int> get knownSecurityFloors =>
      Map.unmodifiable(_record?.floors ?? {});

  Future<CompanyTrustAnchor?> readCompanyTrust(AppDatabase db) async {
    await reconcile(db);
    if (readiness != InstallationReadiness.ready) {
      throw StateError('Installation cannot authorize company operations');
    }
    return _record!.companyTrust;
  }

  Future<Signature> signCompanyOperation(
    AppDatabase db,
    VerifiedJobLineSession session,
    Uint8List bytes,
  ) async {
    final operationBytes = Uint8List.fromList(bytes);
    final trust = await readCompanyTrust(db);
    if (trust == null) throw StateError('Company enrollment is unavailable');
    session.validateOperationSigningContent(operationBytes, _record!.identity);
    final pair = await Ed25519().newKeyPairFromSeed(_record!.seed);
    return Ed25519().sign([
      ...utf8.encode('wiredpart.job.line.operation@1:'),
      ...operationBytes,
    ], keyPair: pair);
  }

  Future<Signature> signCompanyReceipt(
    AppDatabase db,
    VerifiedJobLineReceiptAdmission admission,
  ) async {
    if (!db.hasCallerTransaction) {
      throw StateError(
        'Receipt signing requires the owning command transaction',
      );
    }
    final persisted = await store.readState(namespace);
    if (persisted == null) throw StateError('Protected identity is missing');
    final record = _InstallationRecord.decode(persisted.bytes);
    final pending = record.pendingCommand;
    final trust = record.companyTrust;
    if (record.activation != InstallationActivation.active ||
        pending == null ||
        pending.afterWitness != null ||
        trust == null ||
        await db.settingsDao.getSetting(kInstallationBindingKey) !=
            record.binding ||
        record.storePathFingerprint != await _companyStorePath(db) ||
        record.storeGeneration.value != pending.storeGeneration) {
      throw StateError(
        'Receipt signing requires exact active protected intent',
      );
    }
    final bytes = await admission.validateSigningContent(
      db,
      record.identity,
      pending,
      trust,
      record.floors,
    );
    await _validateCompanyCommit(db, pending);
    // No reconciliation here. The candidate is deliberately unsigned and the
    // protected intent remains held until its sealed receipt is witnessed.
    final unchanged = await store.readState(namespace);
    if (unchanged?.revision != persisted.revision ||
        _securityCanonical(jsonDecode(utf8.decode(unchanged!.bytes))) !=
            _securityCanonical(jsonDecode(utf8.decode(persisted.bytes)))) {
      throw StateError('Protected receipt intent changed during signing');
    }
    final pair = await Ed25519().newKeyPairFromSeed(record.seed);
    return Ed25519().sign([
      ...utf8.encode('wiredpart.job.line.receipt@2:'),
      ...bytes,
    ], keyPair: pair);
  }

  /// Called while the command owns a SQLite write lock. CAS binds the authority
  /// revision and installation generation until the database transaction ends.
  Future<CompanyCommandIntent> beginCompanyCommand(
    AppDatabase db,
    CompanyCommandIntent intent, {
    required CompanyTrustAnchor expectedTrust,
    required Map<String, int> expectedFloors,
  }) async {
    final persisted = await store.readState(namespace);
    if (persisted == null) throw StateError('Protected identity is missing');
    final record = _InstallationRecord.decode(persisted.bytes);
    if (record.activation != InstallationActivation.active ||
        record.pendingCommand != null ||
        record.companyTrust == null ||
        jsonEncode(record.companyTrust!.encode()) !=
            jsonEncode(expectedTrust.encode()) ||
        jsonEncode(record.floors) != jsonEncode(expectedFloors) ||
        record.storeGeneration.value != intent.storeGeneration ||
        await db.settingsDao.getSetting(kInstallationBindingKey) !=
            record.binding ||
        record.storePathFingerprint != await _companyStorePath(db)) {
      throw StateError('Company authority changed or command is pending');
    }
    _persisted = persisted;
    final held = intent.withWitness(
      before: await _companyCommandWitness(db, intent),
    );
    await _write(
      _InstallationRecord(
        record.identity,
        record.seed,
        record.activation,
        record.storeGeneration,
        record.floors,
        companyTrust: record.companyTrust,
        pendingCommand: held,
        storePathFingerprint: record.storePathFingerprint,
      ),
      expectedRevision: persisted.revision,
    );
    return held;
  }

  Future<CompanyCommandIntent> sealCompanyCommand(
    AppDatabase db,
    CompanyCommandIntent intent,
  ) async {
    await _validateCompanyCommit(db, intent);
    final current = await store.readState(namespace);
    if (current == null) throw StateError('Protected identity is missing');
    final record = _InstallationRecord.decode(current.bytes);
    if (jsonEncode(record.pendingCommand?.encode()) !=
        jsonEncode(intent.encode())) {
      throw StateError('Pending command changed before commit');
    }
    final receipt = await (db.select(
      db.jobLineReceipts,
    )..where((t) => t.receiptKey.equals(intent.receiptKey))).getSingle();
    await JobLineCommandReceipt.verifyAdmissionSeal(
      receipt.receiptBytes,
      record.identity,
      record.storeGeneration.value,
    );
    final sealed = intent.withWitness(
      after: await _companyCommandWitness(db, intent),
    );
    _persisted = current;
    await _write(
      _InstallationRecord(
        record.identity,
        record.seed,
        record.activation,
        record.storeGeneration,
        record.floors,
        companyTrust: record.companyTrust,
        pendingCommand: sealed,
        storePathFingerprint: record.storePathFingerprint,
      ),
      expectedRevision: current.revision,
    );
    return sealed;
  }

  Future<void> completeCompanyCommand(
    AppDatabase db,
    CompanyCommandIntent intent,
  ) async {
    // Reconciliation takes the SQLite write lock before checking a receipt.
    // It can also finish an intent committed by another process before a reply.
    await reconcile(db);
    if (readiness != InstallationReadiness.ready ||
        _record!.pendingCommand != null) {
      throw StateError('Company command recovery is required');
    }
  }

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
        await _write(_record!, expectedRevision: null);
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

  Future<void> _write(
    _InstallationRecord next, {
    required String? expectedRevision,
  }) async {
    final bytes = next.encode();
    if (bytes.length > kInstallationStateLimit) {
      throw StateError('Protected installation state is full');
    }
    final revision = const Uuid().v4();
    await store.compareAndSwapState(
      namespace,
      expectedRevision: expectedRevision,
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
    if (record.companyTrust != null &&
        record.storePathFingerprint != await _companyStorePath(db)) {
      throw StateError('Company store path does not match protected binding');
    }
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
      await _write(
        record.withActivation(InstallationActivation.active),
        expectedRevision: persisted.revision,
      );
    }
    if (record.pendingCommand case final intent?) {
      if (db.hasCallerTransaction) {
        throw StateError('Pending recovery requires its own transaction');
      }
      await db.transaction(() async {
        await db.customStatement(
          'UPDATE app_settings SET value = value WHERE key = ?',
          [kInstallationBindingKey],
        );
        final current = await store.readState(namespace);
        if (current == null) throw StateError('Protected identity is missing');
        final next = _InstallationRecord.decode(current.bytes);
        if (next.binding != record.binding ||
            jsonEncode(next.pendingCommand?.encode()) !=
                jsonEncode(intent.encode())) {
          throw StateError('Pending company command changed');
        }
        final receipt =
            await (db.select(db.jobLineReceipts)
                  ..where((t) => t.receiptKey.equals(intent.receiptKey)))
                .getSingleOrNull();
        if (intent.storeGeneration != next.storeGeneration.value ||
            (receipt != null &&
                (receipt.operationCommitment != intent.operationCommitment ||
                    receipt.commandCommitment != intent.commandCommitment))) {
          throw StateError('Pending company command receipt differs');
        }
        final witness = await _companyCommandWitness(db, intent);
        if (receipt == null) {
          if (intent.beforeWitness == null || witness != intent.beforeWitness) {
            throw StateError('Uncommitted company command has partial effects');
          }
        } else {
          await _validateCompanyCommit(db, intent);
          await JobLineCommandReceipt.verifyAdmissionSeal(
            receipt.receiptBytes,
            next.identity,
            next.storeGeneration.value,
          );
          final value = decodeJobLineReceipt(receipt.receiptBytes);
          if (value['parent'] case final String parentKey) {
            final parent = await (db.select(
              db.jobLineReceipts,
            )..where((t) => t.receiptKey.equals(parentKey))).getSingle();
            await JobLineCommandReceipt.verifyAdmissionSeal(
              parent.receiptBytes,
              next.identity,
              next.storeGeneration.value,
            );
            final parentValue = decodeJobLineReceipt(parent.receiptBytes);
            if (parentValue['parent'] != null ||
                parentValue['status'] != 'deferred' ||
                parentValue['bytes'] != value['bytes'] ||
                parent.operationCommitment != intent.operationCommitment ||
                parent.commandCommitment != intent.commandCommitment) {
              throw StateError('Committed receipt parent differs');
            }
          }
          if (intent.afterWitness == null || witness != intent.afterWitness) {
            throw StateError('Committed company command evidence differs');
          }
        }
        _persisted = current;
        await _write(
          _InstallationRecord(
            next.identity,
            next.seed,
            next.activation,
            next.storeGeneration,
            next.floors,
            companyTrust: next.companyTrust,
            storePathFingerprint: next.storePathFingerprint,
          ),
          expectedRevision: current.revision,
        );
      });
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
    final protected = await store.readState(namespace);
    if (protected != null &&
        _InstallationRecord.decode(protected.bytes).pendingCommand != null) {
      throw StateError('Finish pending company command before restoring');
    }
    await reconcile(db);
    if (readiness != InstallationReadiness.ready) {
      throw StateError('Recover installation identity before restoring');
    }
    final current = await store.readState(namespace);
    if (current == null) throw StateError('Protected identity is missing');
    final record = _InstallationRecord.decode(current.bytes);
    if (record.activation != InstallationActivation.active ||
        record.pendingCommand != null ||
        await db.settingsDao.getSetting(kInstallationBindingKey) !=
            record.binding) {
      throw StateError('Installation changed before restore admission');
    }
    final next = _InstallationRecord(
      record.identity,
      record.seed,
      InstallationActivation.pending,
      ReceivingStoreGeneration(const Uuid().v4()),
      record.floors,
      previousStoreGeneration: record.storeGeneration,
      companyTrust: record.companyTrust,
      storePathFingerprint: record.storePathFingerprint,
    );
    await _write(next, expectedRevision: current.revision);
    readiness = InstallationReadiness.needsRecovery;
    return InstallationRestoreIntent._(next.binding);
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
    if (previous.pendingCommand != null) {
      throw StateError('Finish pending company command before resetting');
    }
    await _write(
      await _newRecord(previous.floors),
      expectedRevision: persisted.revision,
    );
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
      companyTrust: pending.companyTrust,
      storePathFingerprint: pending.storePathFingerprint,
    );
    if (await db.settingsDao.getSetting(kInstallationBindingKey) !=
        previous.binding) {
      throw StateError('Previous store binding was not retained');
    }
    _persisted = persisted;
    await _write(previous, expectedRevision: persisted.revision);
    await reconcile(db);
  }
}
