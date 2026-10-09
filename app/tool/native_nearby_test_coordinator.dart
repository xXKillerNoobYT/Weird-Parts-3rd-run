import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'native_nearby_test_crypto.dart';
import 'native_nearby_test_output.dart';

final class TestSourceBinding {
  TestSourceBinding({
    required String bindingId,
    required String hostSessionId,
    required String candidateHash,
    required String nativeImageHash,
    required String kernelHash,
    required int pid,
    required int startedAt,
    required String run,
    required this.role,
    required String deviceId,
    required String peerId,
    required String isolateId,
  }) : bindingId = nativeTestId(bindingId),
       hostSessionId = nativeTestId(hostSessionId),
       candidateHash = _hash(candidateHash, source: true),
       nativeImageHash = _hash(nativeImageHash),
       kernelHash = _hash(kernelHash),
       pid = nativeTestInt(pid, max: 4294967295),
       startedAt = nativeTestInt(startedAt),
       run = nativeTestId(run),
       deviceId = nativeTestId(deviceId),
       peerId = nativeTestId(peerId),
       isolateId = _isolateId(isolateId) {
    if (deviceId == peerId || !run.startsWith('nearby-')) rejectNativeTest();
  }
  factory TestSourceBinding.fromJson(Object? value) {
    final m = nativeTestMap(value, {
      'bindingId',
      'hostSessionId',
      'candidateHash',
      'nativeImageHash',
      'kernelHash',
      'pid',
      'startedAt',
      'run',
      'role',
      'deviceId',
      'peerId',
      'isolateId',
    });
    return TestSourceBinding(
      bindingId: nativeTestId(m['bindingId']),
      hostSessionId: nativeTestId(m['hostSessionId']),
      candidateHash: m['candidateHash'] as String,
      nativeImageHash: m['nativeImageHash'] as String,
      kernelHash: m['kernelHash'] as String,
      pid: nativeTestInt(m['pid']),
      startedAt: nativeTestInt(m['startedAt']),
      run: nativeTestId(m['run']),
      role: nativeTestRole(m['role']),
      deviceId: nativeTestId(m['deviceId']),
      peerId: nativeTestId(m['peerId']),
      isolateId: nativeTestText(m['isolateId']),
    );
  }
  static String _hash(String value, {bool source = false}) {
    if (!(source
            ? RegExp(r'^[0-9a-f]{40}$|^[0-9a-f]{64}$')
            : RegExp(r'^[0-9a-f]{64}$'))
        .hasMatch(value)) {
      rejectNativeTest();
    }
    return value;
  }

  static String _isolateId(String value) {
    if (!RegExp(r'^isolates/[0-9]{1,32}$').hasMatch(value)) rejectNativeTest();
    return value;
  }

  final String bindingId,
      hostSessionId,
      candidateHash,
      nativeImageHash,
      kernelHash,
      run,
      deviceId,
      peerId,
      isolateId;
  final int pid, startedAt;
  final TestRole role;
}

enum ObservationOutcome { accepted, alreadyAccepted }

enum SnapshotComparisonMode { codeOnly, imported }

final class SnapshotComparison {
  const SnapshotComparison({
    required this.domainMatch,
    required this.assetsMatch,
    required this.profileMatch,
    required this.settingsMatch,
    required this.pinMatch,
  });
  final bool domainMatch, assetsMatch, profileMatch, settingsMatch, pinMatch;
  Map<String, Object> toJson() => {
    'domainMatch': domainMatch,
    'assetsMatch': assetsMatch,
    'profileMatch': profileMatch,
    'settingsMatch': settingsMatch,
    'pinMatch': pinMatch,
  };
}

final class _ReceivedSnapshot {
  _ReceivedSnapshot(this.sealed, this.proof);
  final SealedPrivateSnapshot sealed;
  final PrivateSnapshotProof proof;
}

final class _ReceivedObservation {
  _ReceivedObservation(this.sealed, this.plaintext, this.capturedMillis);
  final SealedObservation sealed;
  final RenderedObservation plaintext;
  final int capturedMillis;
}

final class NativeNearbyTestCoordinator {
  NativeNearbyTestCoordinator._(
    this._encryptionKey,
    this._signingKey,
    this._sources,
    this.publicConfig,
    this._elapsedMillis,
  );
  static Future<NativeNearbyTestCoordinator> create({
    required List<TestSourceBinding> expectedBindings,
    int Function()? elapsedMillis,
  }) async {
    if (expectedBindings.length != 2) rejectNativeTest('source-rejected');
    final a = expectedBindings[0], b = expectedBindings[1];
    if (a.bindingId == b.bindingId ||
        a.hostSessionId == b.hostSessionId ||
        a.role == b.role ||
        a.run != b.run ||
        a.candidateHash != b.candidateHash ||
        a.deviceId != b.peerId ||
        b.deviceId != a.peerId) {
      rejectNativeTest('source-rejected');
    }
    final encryption = await X25519().newKeyPair();
    final signing = await Ed25519().newKeyPair();
    final epoch = 'epoch-${nativeTestRandom(32).replaceAll('=', '')}';
    final encryptionPublic = base64Url.encode(
      (await encryption.extractPublicKey()).bytes,
    );
    final signingPublic = base64Url.encode(
      (await signing.extractPublicKey()).bytes,
    );
    final timer = Stopwatch()..start();
    return NativeNearbyTestCoordinator._(
      encryption,
      signing,
      Map.unmodifiable({
        for (final source in expectedBindings) source.bindingId: source,
      }),
      Map.unmodifiable({
        for (final source in expectedBindings)
          source.role: TestSession(
            epoch: epoch,
            run: source.run,
            role: source.role,
            deviceId: source.deviceId,
            peerId: source.peerId,
            encryptionPublicKey: encryptionPublic,
            signingPublicKey: signingPublic,
          ),
      }),
      elapsedMillis ?? () => timer.elapsedMilliseconds,
    );
  }

  final KeyPair _encryptionKey, _signingKey;
  final Map<String, TestSourceBinding> _sources;
  final Map<TestRole, TestSession> publicConfig;
  final int Function() _elapsedMillis;
  final Map<TestRole, _ReceivedObservation> _observations = {};
  final Map<TestRole, Map<PrivateSnapshotStage, _ReceivedSnapshot>> _snapshots =
      {};
  final Map<TestRole, int> _snapshotOrdinals = {};
  ComparisonChallenge? _comparison;
  Map<TestRole, MatchGrant>? _grants;
  int? _grantsIssuedMillis;
  int _comparisonSequence = 0;
  ComparisonChallenge newComparison(int leg) {
    if (_comparisonSequence >= 64 || leg < (_comparison?.leg ?? 1)) {
      rejectNativeTest('comparison-rejected');
    }
    final next = ComparisonChallenge(
      epoch: publicConfig[TestRole.sender]!.epoch,
      leg: leg,
      comparisonId: ++_comparisonSequence,
      challenge: nativeTestRandom(32),
    );
    _observations.clear();
    _grants = null;
    _grantsIssuedMillis = null;
    return _comparison = next;
  }

  Future<ObservationOutcome> acceptObserved(
    String sourceBindingId,
    SealedObservation sealed,
  ) async {
    final source = _sources[sourceBindingId];
    final comparison = _comparison;
    if (source == null || comparison == null || source.role != sealed.role) {
      rejectNativeTest('source-rejected');
    }
    final session = publicConfig[source.role]!;
    final existing = _observations[source.role];
    if (existing != null) {
      if (await existing.sealed.identityHash() == await sealed.identityHash()) {
        return ObservationOutcome.alreadyAccepted;
      }
      rejectNativeTest('source-rejected');
    }
    final captured = _elapsedMillis();
    final plaintext = await openRenderedObservation(
      encryptionKey: _encryptionKey,
      session: session,
      challenge: comparison,
      sealed: sealed,
    );
    if (!identical(_comparison, comparison) ||
        _observations.containsKey(source.role)) {
      rejectNativeTest('comparison-rejected');
    }
    if (_elapsedMillis() - captured >= plaintext.remainingMillis) {
      rejectNativeTest('expired');
    }
    _observations[source.role] = _ReceivedObservation(
      sealed,
      plaintext,
      captured,
    );
    return ObservationOutcome.accepted;
  }

  Future<Map<TestRole, MatchGrant>> matchGrants() async {
    final comparison = _comparison;
    final a = _observations[TestRole.sender],
        b = _observations[TestRole.receiver];
    if (comparison == null || a == null || b == null) {
      rejectNativeTest('not-ready');
    }
    final now = _elapsedMillis();
    var ttl = nativeTestMaxGrantMillis;
    for (final observation in [a, b]) {
      final age = now - observation.capturedMillis;
      if (age < 0) rejectNativeTest('expired');
      ttl = min(ttl, observation.plaintext.remainingMillis - age - 1000);
    }
    if (ttl <= 0) rejectNativeTest('expired');
    if (a.plaintext.attemptId != b.plaintext.attemptId ||
        !nativeTestEqual(
          utf8.encode(a.plaintext.renderedCode),
          utf8.encode(b.plaintext.renderedCode),
        )) {
      rejectNativeTest('comparison-mismatch');
    }
    if (_grants != null) {
      if (now - _grantsIssuedMillis! >= _grants!.values.first.ttlMillis) {
        rejectNativeTest('expired');
      }
      return _grants!;
    }
    final grants = <TestRole, MatchGrant>{};
    for (final entry in _observations.entries) {
      final observation = entry.value.plaintext;
      final unsigned = MatchGrant(
        session: publicConfig[entry.key]!,
        comparison: comparison,
        attemptId: observation.attemptId,
        sealedCiphertextHash: await entry.value.sealed.identityHash(),
        localExpiresAtMillis: observation.localExpiresAtMillis,
        ttlMillis: ttl,
        signature: base64Url.encode(List.filled(64, 0)),
      );
      final signature = await Ed25519().sign(
        unsigned.signingBytes(),
        keyPair: _signingKey,
      );
      grants[entry.key] = MatchGrant(
        session: unsigned.session,
        comparison: comparison,
        attemptId: unsigned.attemptId,
        sealedCiphertextHash: unsigned.sealedCiphertextHash,
        localExpiresAtMillis: unsigned.localExpiresAtMillis,
        ttlMillis: ttl,
        signature: base64Url.encode(signature.bytes),
      );
    }
    if (!identical(_comparison, comparison) || _elapsedMillis() - now >= ttl) {
      rejectNativeTest('expired');
    }
    _grantsIssuedMillis = now;
    return _grants = Map.unmodifiable(grants);
  }

  Future<ObservationOutcome> acceptSnapshot(
    String sourceBindingId,
    SealedPrivateSnapshot sealed,
  ) async {
    final source = _sources[sourceBindingId];
    if (source == null || source.role != sealed.role) {
      rejectNativeTest('source-rejected');
    }
    final stages = _snapshots.putIfAbsent(source.role, () => {});
    final existing = stages[sealed.stage];
    if (existing != null) {
      if (await existing.sealed.identityHash() == await sealed.identityHash()) {
        return ObservationOutcome.alreadyAccepted;
      }
      rejectNativeTest('snapshot-rejected');
    }
    if (sealed.ordinal <= (_snapshotOrdinals[source.role] ?? 0)) {
      rejectNativeTest('snapshot-rejected');
    }
    final proof = await openPrivateSnapshot(
      encryptionKey: _encryptionKey,
      session: publicConfig[source.role]!,
      sealed: sealed,
    );
    if (stages.containsKey(sealed.stage) ||
        sealed.ordinal <= (_snapshotOrdinals[source.role] ?? 0)) {
      rejectNativeTest('snapshot-rejected');
    }
    stages[sealed.stage] = _ReceivedSnapshot(sealed, proof);
    _snapshotOrdinals[source.role] = sealed.ordinal;
    return ObservationOutcome.accepted;
  }

  SnapshotComparison compareSnapshots({
    required TestRole sourceRole,
    required PrivateSnapshotStage sourceStage,
    required TestRole targetRole,
    required PrivateSnapshotStage targetStage,
    required SnapshotComparisonMode mode,
  }) {
    if ((mode == SnapshotComparisonMode.codeOnly && sourceRole != targetRole) ||
        (mode == SnapshotComparisonMode.imported && sourceRole == targetRole)) {
      rejectNativeTest('snapshot-rejected');
    }
    final source = _snapshots[sourceRole]?[sourceStage]?.proof;
    final target = _snapshots[targetRole]?[targetStage]?.proof;
    final baseline =
        _snapshots[targetRole]?[PrivateSnapshotStage.baseline]?.proof;
    if (source == null ||
        target == null ||
        (mode == SnapshotComparisonMode.imported && baseline == null)) {
      rejectNativeTest('not-ready');
    }
    return SnapshotComparison(
      domainMatch:
          source.integrityValid &&
          target.integrityValid &&
          source.referencesValid &&
          target.referencesValid &&
          source.schemaVersion == target.schemaVersion &&
          source.tableCount == target.tableCount &&
          source.rowCount == target.rowCount &&
          source.referenceCount == target.referenceCount &&
          source.domainDigest == target.domainDigest,
      assetsMatch:
          source.assetCount == target.assetCount &&
          source.assetsDigest == target.assetsDigest,
      profileMatch:
          target.profileDigest ==
          (mode == SnapshotComparisonMode.imported
              ? baseline!.profileDigest
              : source.profileDigest),
      settingsMatch: mode == SnapshotComparisonMode.imported
          ? source.sharedSettingsDigestIncludingPin ==
                target.sharedSettingsDigestIncludingPin
          : source.completeSettingsDigest == target.completeSettingsDigest,
      pinMatch: source.pinDigest == target.pinDigest,
    );
  }
}

final class NativeNearbyCoordinatorProtocol {
  NativeNearbyTestCoordinator? _coordinator;
  static const maxRequestBytes = 8192;
  Future<Map<String, Object>> handle(String line) async {
    try {
      if (utf8.encode(line).length > maxRequestBytes) rejectNativeTest();
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) rejectNativeTest();
      switch (value['operation']) {
        case 'initialize':
          final m = nativeTestMap(value, {'operation', 'sources'});
          if (_coordinator != null ||
              m['sources'] is! List ||
              (m['sources'] as List).length != 2) {
            rejectNativeTest();
          }
          _coordinator = await NativeNearbyTestCoordinator.create(
            expectedBindings: (m['sources'] as List)
                .map(TestSourceBinding.fromJson)
                .toList(),
          );
          return {
            'outcome': 'initialized',
            'sessions': {
              for (final entry in _coordinator!.publicConfig.entries)
                entry.key.name: entry.value.toJson(),
            },
          };
        case 'newComparison':
          final m = nativeTestMap(value, {'operation', 'leg'});
          final coordinator = _coordinator;
          if (coordinator == null) rejectNativeTest('not-ready');
          return {
            'outcome': 'comparison-issued',
            'comparison': coordinator
                .newComparison(nativeTestInt(m['leg'], max: 3))
                .toJson(),
          };
        case 'acceptObserved':
          final m = nativeTestMap(value, {
            'operation',
            'sourceBindingId',
            'sealed',
          });
          final coordinator = _coordinator;
          if (coordinator == null) rejectNativeTest('not-ready');
          final outcome = await coordinator.acceptObserved(
            nativeTestId(m['sourceBindingId']),
            SealedObservation.fromJson(m['sealed']),
          );
          return {
            'outcome': outcome == ObservationOutcome.accepted
                ? 'accepted'
                : 'already-accepted',
          };
        case 'matchGrants':
          nativeTestMap(value, {'operation'});
          final coordinator = _coordinator;
          if (coordinator == null) rejectNativeTest('not-ready');
          final grants = await coordinator.matchGrants();
          return {
            'outcome': 'grants-issued',
            'grants': {
              for (final entry in grants.entries)
                entry.key.name: entry.value.toJson(),
            },
          };
        case 'acceptSnapshot':
          final m = nativeTestMap(value, {
            'operation',
            'sourceBindingId',
            'sealedProof',
          });
          final coordinator = _coordinator;
          if (coordinator == null) rejectNativeTest('not-ready');
          final outcome = await coordinator.acceptSnapshot(
            nativeTestId(m['sourceBindingId']),
            SealedPrivateSnapshot.fromJson(m['sealedProof']),
          );
          return {
            'outcome': outcome == ObservationOutcome.accepted
                ? 'accepted'
                : 'already-accepted',
          };
        case 'compareSnapshots':
          final m = nativeTestMap(value, {
            'operation',
            'sourceRole',
            'sourceStage',
            'targetRole',
            'targetStage',
            'mode',
          });
          final coordinator = _coordinator;
          if (coordinator == null) rejectNativeTest('not-ready');
          final mode = switch (m['mode']) {
            'codeOnly' => SnapshotComparisonMode.codeOnly,
            'import' => SnapshotComparisonMode.imported,
            _ => rejectNativeTest(),
          };
          return coordinator
              .compareSnapshots(
                sourceRole: nativeTestRole(m['sourceRole']),
                sourceStage: PrivateSnapshotStage.parse(m['sourceStage']),
                targetRole: nativeTestRole(m['targetRole']),
                targetStage: PrivateSnapshotStage.parse(m['targetStage']),
                mode: mode,
              )
              .toJson();
        default:
          rejectNativeTest();
      }
    } on NativeTestFailure catch (failure) {
      return {'outcome': failure.outcome};
    } catch (_) {
      return {'outcome': 'invalid-input'};
    }
  }
}

void guardNativeCoordinatorOutput(
  Future<void> done,
  void Function() onFailure,
) {
  // IOSink reports broken pipes asynchronously through done, even when the
  // corresponding writeln returned normally. Consume only this output error.
  unawaited(done.then<void>((_) {}, onError: (Object _) => onFailure()));
}

Future<void> main(List<String> args) async {
  guardNativeCoordinatorOutput(stdout.done, () => exitCode = 1);
  final outputEncoder = NativeTestOutputEncoder(
    framed: Platform.isWindows,
    allowGeneric: true,
  );
  void emit(Map<String, Object> result) {
    try {
      final encoded = outputEncoder.encode(result);
      if (encoded.invalidOutput) exitCode = 1;
      stdout.write(encoded.text);
    } catch (_) {
      exitCode = 1;
    }
  }

  if (args.isNotEmpty) {
    emit({'outcome': 'invalid-input'});
    exitCode = 64;
    return;
  }
  final protocol = NativeNearbyCoordinatorProtocol();
  final buffer = <int>[];
  var oversized = false;
  try {
    await for (final chunk in stdin) {
      for (final byte in chunk) {
        if (byte == 10) {
          Map<String, Object> result;
          try {
            result = oversized
                ? {'outcome': 'invalid-input'}
                : await protocol.handle(utf8.decode(buffer));
          } catch (_) {
            result = {'outcome': 'invalid-input'};
          }
          emit(result);
          buffer.clear();
          oversized = false;
        } else if (!oversized) {
          if (buffer.length >=
              NativeNearbyCoordinatorProtocol.maxRequestBytes) {
            buffer.clear();
            oversized = true;
          } else {
            buffer.add(byte);
          }
        }
      }
    }
    if (buffer.isNotEmpty || oversized) {
      emit({'outcome': 'invalid-input'});
    }
  } catch (_) {
    emit({'outcome': 'input-failed'});
    exitCode = 1;
  }
}
