import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_coordinator.dart';
import '../../tool/native_nearby_test_crypto.dart';

Map<String, dynamic> copyJson(Map<String, Object> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
final failure = throwsA(isA<NativeTestFailure>());

Map<String, Object> sourceJson(TestRole role, {String? host}) => {
  'bindingId': role.name,
  'hostSessionId': host ?? 'host-${role.name}',
  'candidateHash': 'a' * 40,
  'nativeImageHash': 'b' * 64,
  'kernelHash': 'c' * 64,
  'pid': role == TestRole.sender ? 1 : 2,
  'startedAt': 1000,
  'run': 'nearby-test-a',
  'role': role.name,
  'deviceId': 'device-${role.name}',
  'peerId': 'device-${role == TestRole.sender ? 'receiver' : 'sender'}',
  'isolateId': role == TestRole.sender ? 'isolates/1001' : 'isolates/1002',
};

final class Fixture {
  int clock = 0;
  late NativeNearbyTestCoordinator root;
  late ComparisonChallenge challenge;
  final plains = <TestRole, RenderedObservation>{};
  final sealed = <TestRole, SealedObservation>{};
  Future<void> initialize({
    String receiverCode = '739281',
    String receiverAttempt = 'attempt-a',
    int remaining = 120000,
  }) async {
    root = await NativeNearbyTestCoordinator.create(
      expectedBindings: [
        for (final role in TestRole.values)
          TestSourceBinding.fromJson(sourceJson(role)),
      ],
      elapsedMillis: () => clock,
    );
    challenge = root.newComparison(1);
    for (final role in TestRole.values) {
      final session = root.publicConfig[role]!;
      final plain = RenderedObservation(
        renderedCode: role == TestRole.sender ? '739281' : receiverCode,
        attemptId: role == TestRole.sender ? 'attempt-a' : receiverAttempt,
        localExpiresAtMillis: 1000000,
        remainingMillis: remaining,
        deviceId: session.deviceId,
        peerId: session.peerId,
      );
      plains[role] = plain;
      sealed[role] = await sealRenderedObservation(
        session: session,
        challenge: challenge,
        observation: plain,
      );
    }
  }

  Future<Map<TestRole, MatchGrant>> grants() async {
    for (final role in TestRole.values) {
      await root.acceptObserved(role.name, sealed[role]!);
    }
    return root.matchGrants();
  }

  Future<void> consume(
    MatchGrantVerifier verifier,
    MatchGrant grant, {
    String attempt = 'attempt-a',
    String code = '739281',
    int elapsed = 1,
    int now = 1,
    int expiry = 1000000,
    ComparisonChallenge? context,
    SealedObservation? observation,
    bool Function()? current,
  }) => verifier.consume(
    grant: grant,
    savedObservation: observation ?? sealed[TestRole.sender]!,
    challenge: context ?? challenge,
    savedPlaintext: plains[TestRole.sender]!,
    activeAttemptId: attempt,
    currentRenderedCode: code,
    localExpiresAtMillis: expiry,
    observationCapturedElapsedMillis: 0,
    nowElapsedMillis: elapsed,
    nowMillis: now,
    isStillCurrent: current ?? () => true,
  );
}

PrivateSnapshotProof snapshotProof({
  String domain = 'a',
  String profile = 'b',
  String completeSettings = 'c',
  String sharedSettings = 'd',
  String pin = 'e',
  int rowCount = 15,
  bool integrityValid = true,
}) => PrivateSnapshotProof(
  domainDigest: domain * 64,
  assetsDigest: 'f' * 64,
  completeSettingsDigest: completeSettings * 64,
  sharedSettingsDigestIncludingPin: sharedSettings * 64,
  profileDigest: profile * 64,
  pinDigest: pin * 64,
  schemaVersion: 2,
  tableCount: 13,
  rowCount: rowCount,
  assetCount: 1,
  referenceCount: 18,
  integrityValid: integrityValid,
  referencesValid: true,
);

Future<SealedPrivateSnapshot> saveSnapshot(
  Fixture f,
  TestRole role,
  PrivateSnapshotStage stage,
  int ordinal,
  PrivateSnapshotProof proof,
) async {
  final sealed = await sealPrivateSnapshot(
    session: f.root.publicConfig[role]!,
    stage: stage,
    ordinal: ordinal,
    proof: proof,
  );
  expect(
    await f.root.acceptSnapshot(role.name, sealed),
    ObservationOutcome.accepted,
  );
  return sealed;
}

Future<
  ({
    NativeNearbyCoordinatorProtocol protocol,
    Map<TestRole, TestSession> sessions,
    ComparisonChallenge challenge,
    List<Map<String, Object>> observations,
  })
>
pairProtocolFixture() async {
  final protocol = NativeNearbyCoordinatorProtocol();
  final initialized = await protocol.handle(
    jsonEncode({
      'operation': 'initialize',
      'sources': [for (final role in TestRole.values) sourceJson(role)],
    }),
  );
  final sessions = {
    for (final role in TestRole.values)
      role: TestSession.fromJson((initialized['sessions'] as Map)[role.name]),
  };
  final issued = await protocol.handle(
    jsonEncode({'operation': 'newComparison', 'leg': 1}),
  );
  final challenge = ComparisonChallenge.fromJson(issued['comparison']);
  final observations = <Map<String, Object>>[];
  for (final role in TestRole.values) {
    final session = sessions[role]!;
    final sealed = await sealRenderedObservation(
      session: session,
      challenge: challenge,
      observation: RenderedObservation(
        renderedCode: '739281',
        attemptId: 'attempt-a',
        localExpiresAtMillis: 1000000,
        remainingMillis: 120000,
        deviceId: session.deviceId,
        peerId: session.peerId,
      ),
    );
    observations.add({'sourceBindingId': role.name, 'sealed': sealed.toJson()});
  }
  return (
    protocol: protocol,
    sessions: sessions,
    challenge: challenge,
    observations: observations,
  );
}

void main() {
  test('combined pair protocol issues verifiable grants', () async {
    final f = await pairProtocolFixture();
    final result = await f.protocol.handle(
      jsonEncode({
        'operation': 'acceptObservedPairAndMatch',
        'observations': f.observations,
      }),
    );
    expect(result.keys.toSet(), {'outcome', 'grants'});
    expect(result['outcome'], 'grants-issued');
    for (final role in TestRole.values) {
      final session = f.sessions[role]!;
      final grant = MatchGrant.fromJson(
        (result['grants'] as Map)[role.name],
        session,
      );
      expect(
        await Ed25519().verify(
          grant.signingBytes(),
          signature: Signature(
            nativeTestBytes(grant.signature, 64),
            publicKey: SimplePublicKey(
              nativeTestBytes(session.signingPublicKey, 32),
              type: KeyPairType.ed25519,
            ),
          ),
        ),
        isTrue,
      );
      final observation = f.observations.singleWhere(
        (entry) => entry['sourceBindingId'] == role.name,
      );
      expect(
        grant.sealedCiphertextHash,
        await SealedObservation.fromJson(observation['sealed']).identityHash(),
      );
      expect(grant.comparison.toJson(), f.challenge.toJson());
    }
    expect(jsonEncode(result).contains('renderedCode'), isFalse);
  });

  test(
    'combined pair accepts reversed roles and exact cached replay',
    () async {
      final f = await pairProtocolFixture();
      final request = jsonEncode({
        'operation': 'acceptObservedPairAndMatch',
        'observations': f.observations.reversed.toList(),
      });
      final result = await f.protocol.handle(request);
      expect(result['outcome'], 'grants-issued');
      expect(await f.protocol.handle(request), result);
      expect(
        await f.protocol.handle(jsonEncode({'operation': 'matchGrants'})),
        result,
      );
    },
  );

  test('combined pair parses both entries before accepting either', () async {
    final f = await pairProtocolFixture();
    final a = f.observations.first, b = f.observations.last;
    final malformed = [
      {'operation': 'acceptObservedPairAndMatch'},
      {'operation': 'acceptObservedPairAndMatch', 'observations': null},
      {'operation': 'acceptObservedPairAndMatch', 'observations': []},
      {
        'operation': 'acceptObservedPairAndMatch',
        'observations': [a],
      },
      {
        'operation': 'acceptObservedPairAndMatch',
        'observations': [a, b, a],
      },
      {
        'operation': 'acceptObservedPairAndMatch',
        'observations': [a, null],
      },
      {
        'operation': 'acceptObservedPairAndMatch',
        'observations': [
          a,
          {...b, 'extra': 'PRIVATE-CANARY'},
        ],
      },
      {
        'operation': 'acceptObservedPairAndMatch',
        'observations': [
          a,
          {'sourceBindingId': 'receiver', 'sealed': 'PRIVATE-CANARY'},
        ],
      },
      {
        'operation': 'acceptObservedPairAndMatch',
        'observations': [a, b],
        'extra': 'PRIVATE-CANARY',
      },
    ];
    for (final request in malformed) {
      expect(await f.protocol.handle(jsonEncode(request)), {
        'outcome': 'invalid-input',
      });
    }
    expect(
      await f.protocol.handle(
        jsonEncode({'operation': 'acceptObserved', ...a}),
      ),
      {'outcome': 'accepted'},
    );
    expect(await f.protocol.handle(jsonEncode({'operation': 'matchGrants'})), {
      'outcome': 'not-ready',
    });
  });

  for (final invalid in [
    'duplicate-binding',
    'same-role',
    'wrong-binding',
    'wrong-role-binding',
    'wrong-challenge',
  ]) {
    test('combined pair rejects $invalid before acceptance', () async {
      final f = await pairProtocolFixture();
      final observations = [
        for (final entry in f.observations) copyJson(entry),
      ];
      switch (invalid) {
        case 'duplicate-binding':
          observations[1]['sourceBindingId'] = 'sender';
        case 'same-role':
          observations[1]['sealed'] = observations[0]['sealed'];
        case 'wrong-binding':
          observations[1]['sourceBindingId'] = 'unregistered';
        case 'wrong-role-binding':
          observations[0]['sourceBindingId'] = 'receiver';
          observations[1]['sourceBindingId'] = 'sender';
        case 'wrong-challenge':
          ((observations[1]['sealed'] as Map)['comparison']
              as Map)['challenge'] = nativeTestRandom(
            32,
          );
      }
      expect(
        await f.protocol.handle(
          jsonEncode({
            'operation': 'acceptObservedPairAndMatch',
            'observations': observations,
          }),
        ),
        {
          'outcome': invalid == 'wrong-challenge'
              ? 'comparison-rejected'
              : 'source-rejected',
        },
      );
      expect(
        await f.protocol.handle(
          jsonEncode({'operation': 'acceptObserved', ...f.observations.first}),
        ),
        {'outcome': 'accepted'},
      );
      expect(
        await f.protocol.handle(jsonEncode({'operation': 'matchGrants'})),
        {'outcome': 'not-ready'},
      );
    });
  }

  test(
    'combined pair rejects prior comparison replay without grants',
    () async {
      final f = await pairProtocolFixture();
      final request = jsonEncode({
        'operation': 'acceptObservedPairAndMatch',
        'observations': f.observations,
      });
      expect((await f.protocol.handle(request))['outcome'], 'grants-issued');
      await f.protocol.handle(
        jsonEncode({'operation': 'newComparison', 'leg': 1}),
      );
      expect(await f.protocol.handle(request), {
        'outcome': 'comparison-rejected',
      });
      expect(
        await f.protocol.handle(jsonEncode({'operation': 'matchGrants'})),
        {'outcome': 'not-ready'},
      );
    },
  );

  test(
    'combined pair second authentication failure retains first safely',
    () async {
      final f = await pairProtocolFixture();
      final observations = [
        for (final entry in f.observations) copyJson(entry),
      ];
      final second = observations[1]['sealed'] as Map;
      final tag = base64Url.decode(second['tag'] as String)..[0] ^= 1;
      second['tag'] = base64Url.encode(tag);
      final result = await f.protocol.handle(
        jsonEncode({
          'operation': 'acceptObservedPairAndMatch',
          'observations': observations,
        }),
      );
      expect(result, {'outcome': 'invalid-envelope'});
      expect(
        await f.protocol.handle(jsonEncode({'operation': 'matchGrants'})),
        {'outcome': 'not-ready'},
      );
      expect(
        await f.protocol.handle(
          jsonEncode({'operation': 'acceptObserved', ...f.observations.first}),
        ),
        {'outcome': 'already-accepted'},
      );
      expect(
        (await f.protocol.handle(
          jsonEncode({
            'operation': 'acceptObservedPairAndMatch',
            'observations': f.observations,
          }),
        ))['outcome'],
        'grants-issued',
      );
    },
  );

  test(
    'combined pair preserves retained observation age and cached grant TTL',
    () async {
      final f = Fixture();
      await f.initialize(remaining: 5000);
      final pair = [
        for (final role in TestRole.values)
          (sourceBindingId: role.name, sealed: f.sealed[role]!),
      ];
      await f.root.acceptObserved('sender', f.sealed[TestRole.sender]!);
      f.clock = 1500;
      final grants = await f.root.acceptObservedPairAndMatch(pair);
      expect(grants[TestRole.sender]!.ttlMillis, 2500);
      f.clock = 3999;
      expect(await f.root.acceptObservedPairAndMatch(pair), same(grants));
      f.clock = 4000;
      await expectLater(f.root.acceptObservedPairAndMatch(pair), failure);
    },
  );

  test(
    'combined pair cannot refresh partial authentication capture on retry',
    () async {
      final f = Fixture();
      await f.initialize(remaining: 5000);
      final damaged = f.sealed[TestRole.receiver]!.toJson();
      final tag = base64Url.decode(damaged['tag'] as String)..[0] ^= 1;
      damaged['tag'] = base64Url.encode(tag);
      await expectLater(
        f.root.acceptObservedPairAndMatch([
          (sourceBindingId: 'sender', sealed: f.sealed[TestRole.sender]!),
          (
            sourceBindingId: 'receiver',
            sealed: SealedObservation.fromJson(damaged),
          ),
        ]),
        failure,
      );
      f.clock = 4000;
      await expectLater(
        f.root.acceptObservedPairAndMatch([
          for (final role in TestRole.values)
            (sourceBindingId: role.name, sealed: f.sealed[role]!),
        ]),
        failure,
      );
      await expectLater(f.root.matchGrants(), failure);
    },
  );

  test(
    'combined pair mismatched private comparison never issues grants',
    () async {
      for (final codeMismatch in [true, false]) {
        final f = Fixture();
        await f.initialize(
          receiverCode: codeMismatch ? '123456' : '739281',
          receiverAttempt: codeMismatch ? 'attempt-a' : 'attempt-b',
        );
        await expectLater(
          f.root.acceptObservedPairAndMatch([
            for (final role in TestRole.values)
              (sourceBindingId: role.name, sealed: f.sealed[role]!),
          ]),
          failure,
        );
        await expectLater(f.root.matchGrants(), failure);
      }
    },
  );

  test(
    'combined pair request caps and failure outcomes never echo input',
    () async {
      final f = await pairProtocolFixture();
      for (final secret in [
        'PRIVATE-CANARY',
        '739281',
        'ws://127.0.0.1/auth-canary=/ws',
      ]) {
        final result = await f.protocol.handle(
          jsonEncode({
            'operation': 'acceptObservedPairAndMatch',
            'observations': [
              f.observations.first,
              {'sourceBindingId': 'receiver', 'sealed': secret * 9000},
            ],
          }),
        );
        expect(result, {'outcome': 'invalid-input'});
        expect(jsonEncode(result).contains(secret), isFalse);
      }
      final tooManyBytes =
          'é' * (NativeNearbyCoordinatorProtocol.maxRequestBytes ~/ 2 + 1);
      expect(await f.protocol.handle(tooManyBytes), {
        'outcome': 'invalid-input',
      });
      expect(
        await f.protocol.handle(
          jsonEncode({'operation': 'acceptObserved', ...f.observations.first}),
        ),
        {'outcome': 'accepted'},
      );
    },
  );

  test(
    'asynchronous coordinator output failure is consumed without logging',
    () async {
      final done = Completer<void>();
      var failures = 0;
      guardNativeCoordinatorOutput(done.future, () => failures++);
      done.completeError(StateError('PRIVATE_OUTPUT_FAILURE_CANARY/1234'));
      await Future<void>.delayed(Duration.zero);
      expect(failures, 1);
      guardNativeCoordinatorOutput(Future<void>.value(), () => failures++);
      await Future<void>.delayed(Duration.zero);
      expect(failures, 1);
    },
  );
  test('native padded base64 pairing attempt IDs survive observation and grant binding', () async {
    final f = Fixture();
    await f.initialize();
    final attempt = base64Url.encode(List.filled(32, 255));
    expect(attempt.startsWith('_'), isTrue);
    expect(attempt.endsWith('='), isTrue);
    expect(nativeTestAttemptId(attempt), attempt);
    expect(
      nativeTestAttemptId(base64Url.encode(List.filled(32, 251)))
          .startsWith('-'),
      isTrue,
    );
    for (final role in TestRole.values) {
      final session = f.root.publicConfig[role]!;
      final plain = RenderedObservation(
        renderedCode: '739281',
        attemptId: attempt,
        localExpiresAtMillis: 1000000,
        remainingMillis: 120000,
        deviceId: session.deviceId,
        peerId: session.peerId,
      );
      f.plains[role] = plain;
      f.sealed[role] = await sealRenderedObservation(
        session: session,
        challenge: f.challenge,
        observation: plain,
      );
    }
    final grant = (await f.grants())[TestRole.sender]!;
    final session = f.root.publicConfig[TestRole.sender]!;
    expect(MatchGrant.fromJson(grant.toJson(), session).attemptId, attempt);
    await f.consume(MatchGrantVerifier(session), grant, attempt: attempt);
    expect(() => nativeTestAttemptId('${attempt.substring(0, 43)}!'), failure);
    expect(() => nativeTestAttemptId('A' * 44), failure);
  });
  test('source ledger preserves actual VM isolate IDs and rejects URLs or fake IDs', () {
    expect(
      TestSourceBinding.fromJson(sourceJson(TestRole.sender)).isolateId,
      'isolates/1001',
    );
    for (final isolate in [
      'isolate-a',
      'isolates/',
      'isolates/abc',
      'isolates/123/ws',
      'ws://127.0.0.1/auth-canary=/ws',
      'isolates/${'1' * 33}',
    ]) {
      expect(
        () => TestSourceBinding.fromJson({
          ...sourceJson(TestRole.sender),
          'isolateId': isolate,
        }),
        failure,
      );
    }
  });
  test('private code-only proof compares exact full settings without revealing digests', () async {
    final f = Fixture();
    await f.initialize();
    final sealed = await saveSnapshot(
      f,
      TestRole.sender,
      PrivateSnapshotStage.baseline,
      1,
      snapshotProof(),
    );
    await saveSnapshot(
      f,
      TestRole.sender,
      PrivateSnapshotStage.preLeg1,
      2,
      snapshotProof(),
    );
    final result = f.root.compareSnapshots(
      sourceRole: TestRole.sender,
      sourceStage: PrivateSnapshotStage.baseline,
      targetRole: TestRole.sender,
      targetStage: PrivateSnapshotStage.preLeg1,
      mode: SnapshotComparisonMode.codeOnly,
    );
    expect(result.toJson(), {
      'domainMatch': true,
      'assetsMatch': true,
      'profileMatch': true,
      'settingsMatch': true,
      'pinMatch': true,
    });
    expect(
      await f.root.acceptSnapshot('sender', sealed),
      ObservationOutcome.alreadyAccepted,
    );
    final changed = await sealPrivateSnapshot(
      session: f.root.publicConfig[TestRole.sender]!,
      stage: PrivateSnapshotStage.baseline,
      ordinal: 1,
      proof: snapshotProof(),
    );
    await expectLater(f.root.acceptSnapshot('sender', changed), failure);
    final public = jsonEncode([sealed.toJson(), result.toJson()]);
    for (final digest in ['a', 'b', 'c', 'd', 'e', 'f']) {
      expect(public.contains(digest * 64), isFalse);
    }
    expect(public.contains('pinDigest'), isFalse);
    expect(public.contains('completeSettingsDigest'), isFalse);
  });

  test('private import proof compares sender settings/PIN and retained target baseline profile', () async {
    final f = Fixture();
    await f.initialize();
    await saveSnapshot(
      f,
      TestRole.sender,
      PrivateSnapshotStage.preLeg1,
      1,
      snapshotProof(profile: 'a'),
    );
    await saveSnapshot(
      f,
      TestRole.receiver,
      PrivateSnapshotStage.baseline,
      1,
      snapshotProof(
        domain: 'b',
        profile: 'f',
        completeSettings: 'a',
        sharedSettings: 'a',
        pin: 'a',
      ),
    );
    await saveSnapshot(
      f,
      TestRole.receiver,
      PrivateSnapshotStage.postLeg1,
      2,
      snapshotProof(profile: 'f', completeSettings: 'b'),
    );
    final result = f.root.compareSnapshots(
      sourceRole: TestRole.sender,
      sourceStage: PrivateSnapshotStage.preLeg1,
      targetRole: TestRole.receiver,
      targetStage: PrivateSnapshotStage.postLeg1,
      mode: SnapshotComparisonMode.imported,
    );
    expect(result.toJson(), {
      'domainMatch': true,
      'assetsMatch': true,
      'profileMatch': true,
      'settingsMatch': true,
      'pinMatch': true,
    });
    await saveSnapshot(
      f,
      TestRole.receiver,
      PrivateSnapshotStage.postLeg2,
      3,
      snapshotProof(
        domain: 'c',
        profile: 'a',
        completeSettings: 'b',
        sharedSettings: 'a',
        pin: 'a',
        rowCount: 14,
      ),
    );
    expect(
      f.root
          .compareSnapshots(
            sourceRole: TestRole.sender,
            sourceStage: PrivateSnapshotStage.preLeg1,
            targetRole: TestRole.receiver,
            targetStage: PrivateSnapshotStage.postLeg2,
            mode: SnapshotComparisonMode.imported,
          )
          .toJson(),
      {
        'domainMatch': false,
        'assetsMatch': true,
        'profileMatch': false,
        'settingsMatch': false,
        'pinMatch': false,
      },
    );
  });

  test(
    'private snapshot schema, counts, source and ordinal replay fail closed',
    () async {
      final f = Fixture();
      await f.initialize();
      final sealed = await sealPrivateSnapshot(
        session: f.root.publicConfig[TestRole.sender]!,
        stage: PrivateSnapshotStage.baseline,
        ordinal: 2,
        proof: snapshotProof(),
      );
      await expectLater(f.root.acceptSnapshot('receiver', sealed), failure);
      await expectLater(f.root.acceptSnapshot('unknown', sealed), failure);
      await f.root.acceptSnapshot('sender', sealed);
      final old = await sealPrivateSnapshot(
        session: f.root.publicConfig[TestRole.sender]!,
        stage: PrivateSnapshotStage.preLeg1,
        ordinal: 1,
        proof: snapshotProof(),
      );
      await expectLater(f.root.acceptSnapshot('sender', old), failure);
      await saveSnapshot(
        f,
        TestRole.sender,
        PrivateSnapshotStage.preLeg1,
        3,
        snapshotProof(integrityValid: false),
      );
      expect(
        f.root
            .compareSnapshots(
              sourceRole: TestRole.sender,
              sourceStage: PrivateSnapshotStage.baseline,
              targetRole: TestRole.sender,
              targetStage: PrivateSnapshotStage.preLeg1,
              mode: SnapshotComparisonMode.codeOnly,
            )
            .domainMatch,
        isFalse,
      );
      expect(
        () => f.root.compareSnapshots(
          sourceRole: TestRole.sender,
          sourceStage: PrivateSnapshotStage.baseline,
          targetRole: TestRole.receiver,
          targetStage: PrivateSnapshotStage.baseline,
          mode: SnapshotComparisonMode.codeOnly,
        ),
        failure,
      );
      expect(() => PrivateSnapshotStage.parse('finalState'), failure);
      expect(
        PrivateSnapshotStage.parse('final'),
        PrivateSnapshotStage.finalState,
      );
      expect(() => snapshotProof(rowCount: -1), failure);
      final malformed = sealed.toJson()..['ordinal'] = 0;
      expect(() => SealedPrivateSnapshot.fromJson(malformed), failure);
    },
  );

  for (final field in [
    'epoch',
    'run',
    'role',
    'stage',
    'ordinal',
    'ephemeralPublicKey',
    'nonce',
    'ciphertext',
    'tag',
  ]) {
    test(
      'private snapshot tampered $field cannot disclose or be admitted',
      () async {
        final f = Fixture();
        await f.initialize();
        final sealed = await sealPrivateSnapshot(
          session: f.root.publicConfig[TestRole.sender]!,
          stage: PrivateSnapshotStage.baseline,
          ordinal: 1,
          proof: snapshotProof(),
        );
        final m = copyJson(sealed.toJson());
        if (field == 'epoch') {
          m[field] = 'other';
        } else if (field == 'run') {
          m[field] = 'nearby-other';
        } else if (field == 'role') {
          m[field] = 'receiver';
        } else if (field == 'stage') {
          m[field] = 'preLeg1';
        } else if (field == 'ordinal') {
          m[field] = 2;
        } else {
          final bytes = base64Url.decode(m[field] as String);
          bytes[0] ^= 1;
          m[field] = base64Url.encode(bytes);
        }
        await expectLater(
          f.root.acceptSnapshot('sender', SealedPrivateSnapshot.fromJson(m)),
          failure,
        );
      },
    );
  }

  test(
    'encrypted snapshot and rendered observation purposes cannot cross',
    () async {
      final f = Fixture();
      await f.initialize();
      final session = f.root.publicConfig[TestRole.sender]!;
      final sealed = await sealPrivateSnapshot(
        session: session,
        stage: PrivateSnapshotStage.baseline,
        ordinal: 1,
        proof: snapshotProof(),
      );
      await expectLater(
        openPrivateSnapshot(
          encryptionKey: await X25519().newKeyPair(),
          session: session,
          sealed: sealed,
        ),
        failure,
      );
      final observation = f.sealed[TestRole.sender]!.toJson();
      final forgedSnapshot = sealed.toJson();
      for (final field in [
        'ephemeralPublicKey',
        'nonce',
        'ciphertext',
        'tag',
      ]) {
        forgedSnapshot[field] = observation[field]!;
      }
      await expectLater(
        f.root.acceptSnapshot(
          'sender',
          SealedPrivateSnapshot.fromJson(forgedSnapshot),
        ),
        failure,
      );
      final forgedObservation = f.sealed[TestRole.sender]!.toJson();
      for (final field in [
        'ephemeralPublicKey',
        'nonce',
        'ciphertext',
        'tag',
      ]) {
        forgedObservation[field] = sealed.toJson()[field]!;
      }
      await expectLater(
        f.root.acceptObserved(
          'sender',
          SealedObservation.fromJson(forgedObservation),
        ),
        failure,
      );
    },
  );

  test('private snapshot CLI emits exactly comparison booleans and sanitized failures', () async {
    final protocol = NativeNearbyCoordinatorProtocol();
    final initialized = await protocol.handle(
      jsonEncode({
        'operation': 'initialize',
        'sources': [for (final role in TestRole.values) sourceJson(role)],
      }),
    );
    final sessions = initialized['sessions'] as Map;
    final session = TestSession.fromJson(sessions['sender']);
    for (final stage in [
      PrivateSnapshotStage.baseline,
      PrivateSnapshotStage.preLeg1,
    ]) {
      final sealed = await sealPrivateSnapshot(
        session: session,
        stage: stage,
        ordinal: stage.index + 1,
        proof: snapshotProof(),
      );
      expect(
        await protocol.handle(
          jsonEncode({
            'operation': 'acceptSnapshot',
            'sourceBindingId': 'sender',
            'sealedProof': sealed.toJson(),
          }),
        ),
        {'outcome': 'accepted'},
      );
    }
    final result = await protocol.handle(
      jsonEncode({
        'operation': 'compareSnapshots',
        'sourceRole': 'sender',
        'sourceStage': 'baseline',
        'targetRole': 'sender',
        'targetStage': 'preLeg1',
        'mode': 'codeOnly',
      }),
    );
    expect(result, {
      'domainMatch': true,
      'assetsMatch': true,
      'profileMatch': true,
      'settingsMatch': true,
      'pinMatch': true,
    });
    for (final canary in [
      '739281',
      '1234',
      'ws://127.0.0.1/auth-canary=/ws',
      'PRIVATE-KEY-CANARY',
      '192.168.1.179:4230',
    ]) {
      final malformed = await protocol.handle(
        jsonEncode({
          'operation': 'acceptSnapshot',
          'sourceBindingId': 'sender',
          'sealedProof': canary,
        }),
      );
      expect(malformed, {'outcome': 'invalid-input'});
      expect(jsonEncode(malformed).contains(canary), isFalse);
    }
  });

  test(
    'shared challenge grants both roles and each grant is consumed once',
    () async {
      final f = Fixture();
      await f.initialize();
      final grants = await f.grants();
      expect(grants.keys.toSet(), TestRole.values.toSet());
      expect(grants[TestRole.sender]!.ttlMillis, 20000);
      final verifier = MatchGrantVerifier(
        f.root.publicConfig[TestRole.sender]!,
      );
      await f.consume(verifier, grants[TestRole.sender]!);
      await expectLater(f.consume(verifier, grants[TestRole.sender]!), failure);
      final output = jsonEncode({
        'sessions': {
          for (final e in f.root.publicConfig.entries)
            e.key.name: e.value.toJson(),
        },
        'sealed': {
          for (final e in f.sealed.entries) e.key.name: e.value.toJson(),
        },
        'grants': {
          for (final e in grants.entries) e.key.name: e.value.toJson(),
        },
      });
      for (final secret in ['739281', '1234', 'renderedCode', 'privateKey']) {
        expect(output.contains(secret), isFalse);
      }
      expect(await f.root.matchGrants(), same(grants));
    },
  );

  test(
    'source authority requires two distinct hosts and inverse device bindings',
    () async {
      for (final mutation in [
        {'hostSessionId': 'host-sender'},
        {'bindingId': 'sender'},
        {'role': 'sender'},
        {'peerId': 'unrelated'},
        {'candidateHash': 'd' * 40},
        {'run': 'nearby-other'},
      ]) {
        final receiver = {...sourceJson(TestRole.receiver), ...mutation};
        await expectLater(
          NativeNearbyTestCoordinator.create(
            expectedBindings: [
              TestSourceBinding.fromJson(sourceJson(TestRole.sender)),
              TestSourceBinding.fromJson(receiver),
            ],
          ),
          failure,
        );
      }
      final f = Fixture();
      await f.initialize();
      await expectLater(
        f.root.acceptObserved('unregistered', f.sealed[TestRole.sender]!),
        failure,
      );
      await expectLater(
        f.root.acceptObserved('receiver', f.sealed[TestRole.sender]!),
        failure,
      );
      expect(
        await f.root.acceptObserved('sender', f.sealed[TestRole.sender]!),
        ObservationOutcome.accepted,
      );
      expect(
        await f.root.acceptObserved('sender', f.sealed[TestRole.sender]!),
        ObservationOutcome.alreadyAccepted,
      );
      final another = await sealRenderedObservation(
        session: f.root.publicConfig[TestRole.sender]!,
        challenge: f.challenge,
        observation: f.plains[TestRole.sender]!,
      );
      await expectLater(f.root.acceptObserved('sender', another), failure);
      await expectLater(f.root.matchGrants(), failure);
    },
  );

  for (final field in [
    'epoch',
    'run',
    'role',
    'challenge',
    'comparisonId',
    'leg',
  ]) {
    test('wrong $field cannot authenticate an observation', () async {
      final f = Fixture();
      await f.initialize();
      final m = copyJson(f.sealed[TestRole.sender]!.toJson());
      if (field == 'epoch') {
        m[field] = 'other';
        (m['comparison'] as Map)['epoch'] = 'other';
      } else if (field == 'run') {
        m[field] = 'nearby-other';
      } else if (field == 'role') {
        m[field] = 'receiver';
      } else {
        (m['comparison'] as Map)[field] = field == 'challenge'
            ? nativeTestRandom(32)
            : 2;
      }
      await expectLater(
        f.root.acceptObserved('sender', SealedObservation.fromJson(m)),
        failure,
      );
    });
  }

  for (final field in ['ephemeralPublicKey', 'nonce', 'ciphertext', 'tag']) {
    test('tampered $field cannot decrypt or grant', () async {
      final f = Fixture();
      await f.initialize();
      final m = copyJson(f.sealed[TestRole.sender]!.toJson());
      final bytes = base64Url.decode(m[field] as String);
      bytes[0] ^= 1;
      m[field] = base64Url.encode(bytes);
      await expectLater(
        f.root.acceptObserved('sender', SealedObservation.fromJson(m)),
        failure,
      );
      await expectLater(f.root.matchGrants(), failure);
    });
  }

  test('wrong recipient and zero shared secret fail closed', () async {
    final f = Fixture();
    await f.initialize();
    await expectLater(
      openRenderedObservation(
        encryptionKey: await X25519().newKeyPair(),
        session: f.root.publicConfig[TestRole.sender]!,
        challenge: f.challenge,
        sealed: f.sealed[TestRole.sender]!,
      ),
      failure,
    );
    final good = f.root.publicConfig[TestRole.sender]!;
    final zero = TestSession(
      epoch: good.epoch,
      run: good.run,
      role: good.role,
      deviceId: good.deviceId,
      peerId: good.peerId,
      encryptionPublicKey: base64Url.encode(List.filled(32, 0)),
      signingPublicKey: good.signingPublicKey,
    );
    await expectLater(
      sealRenderedObservation(
        session: zero,
        challenge: f.challenge,
        observation: f.plains[TestRole.sender]!,
      ),
      failure,
    );
  });

  for (final mismatch in ['code', 'attempt']) {
    test('different $mismatch never yields a Match grant', () async {
      final f = Fixture();
      await f.initialize(
        receiverCode: mismatch == 'code' ? '482917' : '739281',
        receiverAttempt: mismatch == 'attempt' ? 'attempt-b' : 'attempt-a',
      );
      await expectLater(f.grants(), failure);
    });
  }

  test(
    'root monotonic receipt age expires observations and caps TTL',
    () async {
      final f = Fixture();
      await f.initialize(remaining: 5000);
      await f.root.acceptObserved('sender', f.sealed[TestRole.sender]!);
      f.clock = 1500;
      await f.root.acceptObserved('receiver', f.sealed[TestRole.receiver]!);
      expect((await f.root.matchGrants())[TestRole.sender]!.ttlMillis, 2500);
      f.clock = 5000;
      await expectLater(f.root.matchGrants(), failure);
    },
  );

  for (final field in [
    'signature',
    'attemptId',
    'sealedCiphertextHash',
    'localExpiresAtMillis',
    'ttlMillis',
  ]) {
    test('altered grant $field is rejected before consumption', () async {
      final f = Fixture();
      await f.initialize();
      final grants = await f.grants();
      final m = copyJson(grants[TestRole.sender]!.toJson());
      m[field] = switch (field) {
        'signature' => base64Url.encode(List.filled(64, 0)),
        'attemptId' => 'attempt-b',
        'sealedCiphertextHash' => nativeTestRandom(32),
        'localExpiresAtMillis' => 1000001,
        _ => 19999,
      };
      final session = f.root.publicConfig[TestRole.sender]!;
      await expectLater(
        f.consume(MatchGrantVerifier(session), MatchGrant.fromJson(m, session)),
        failure,
      );
    });
  }

  test(
    'role, peer, session, challenge, live attempt and live code remain bound',
    () async {
      final f = Fixture();
      await f.initialize();
      final grants = await f.grants();
      final session = f.root.publicConfig[TestRole.sender]!;
      await expectLater(
        f.consume(MatchGrantVerifier(session), grants[TestRole.receiver]!),
        failure,
      );
      for (final mutation in [
        {'epoch': 'other'},
        {'run': 'nearby-other'},
        {'peerId': 'other'},
        {'deviceId': 'other'},
      ]) {
        final m = copyJson(grants[TestRole.sender]!.toJson());
        (m['session'] as Map).addAll(mutation);
        expect(() => MatchGrant.fromJson(m, session), failure);
      }
      await expectLater(
        f.consume(
          MatchGrantVerifier(session),
          grants[TestRole.sender]!,
          attempt: 'attempt-b',
        ),
        failure,
      );
      await expectLater(
        f.consume(
          MatchGrantVerifier(session),
          grants[TestRole.sender]!,
          code: '482917',
        ),
        failure,
      );
      await expectLater(
        f.consume(
          MatchGrantVerifier(session),
          grants[TestRole.sender]!,
          context: ComparisonChallenge(
            epoch: f.challenge.epoch,
            leg: 1,
            comparisonId: 1,
            challenge: nativeTestRandom(32),
          ),
        ),
        failure,
      );
      final alternate = await sealRenderedObservation(
        session: session,
        challenge: f.challenge,
        observation: f.plains[TestRole.sender]!,
      );
      await expectLater(
        f.consume(
          MatchGrantVerifier(session),
          grants[TestRole.sender]!,
          observation: alternate,
        ),
        failure,
      );
    },
  );

  test(
    'local expiry, capture age and state changes across awaits fail closed',
    () async {
      final f = Fixture();
      await f.initialize();
      final grant = (await f.grants())[TestRole.sender]!;
      final session = f.root.publicConfig[TestRole.sender]!;
      for (final age in [-1, 20000, 120000]) {
        await expectLater(
          f.consume(MatchGrantVerifier(session), grant, elapsed: age),
          failure,
        );
      }
      await expectLater(
        f.consume(MatchGrantVerifier(session), grant, now: 1000000),
        failure,
      );
      await expectLater(
        f.consume(MatchGrantVerifier(session), grant, expiry: 1000001),
        failure,
      );
      await expectLater(
        f.consume(MatchGrantVerifier(session), grant, current: () => false),
        failure,
      );
      final verifier = MatchGrantVerifier(session);
      final first = f.consume(verifier, grant);
      await expectLater(f.consume(verifier, grant), failure);
      await first;
    },
  );

  test('new root challenge rejects old observation and saved grant', () async {
    final f = Fixture();
    await f.initialize();
    final grant = (await f.grants())[TestRole.sender]!;
    final next = f.root.newComparison(1);
    await expectLater(
      f.root.acceptObserved('sender', f.sealed[TestRole.sender]!),
      failure,
    );
    await expectLater(
      f.consume(
        MatchGrantVerifier(f.root.publicConfig[TestRole.sender]!),
        grant,
        context: next,
      ),
      failure,
    );
  });

  test(
    'malformed protocol input produces allowlisted outcomes without canaries',
    () async {
      final protocol = NativeNearbyCoordinatorProtocol();
      const canaries = [
        '739281',
        '1234',
        'ws://127.0.0.1:54321/auth-canary=/ws',
        'PRIVATE-KEY-CANARY',
        '192.168.1.179:4230',
      ];
      for (final secret in canaries) {
        for (final request in [
          secret,
          jsonEncode({'operation': secret}),
          jsonEncode({
            'operation': 'acceptObserved',
            'sourceBindingId': 'sender',
            'sealed': secret,
          }),
          jsonEncode({
            'operation': 'initialize',
            'sources': [secret, secret],
          }),
          jsonEncode({'operation': 'newComparison', 'leg': secret}),
          jsonEncode({'operation': 'matchGrants', 'extra': secret}),
          secret * 9000,
        ]) {
          final result = await protocol.handle(request);
          expect(result.keys.toList(), ['outcome']);
          expect(
            {'invalid-input', 'not-ready'}.contains(result['outcome']),
            isTrue,
          );
          expect(jsonEncode(result).contains(secret), isFalse);
        }
      }
    },
  );

  test('persistent protocol initializes once and handles comparison/grants without raw echo', () async {
    final protocol = NativeNearbyCoordinatorProtocol();
    final request = jsonEncode({
      'operation': 'initialize',
      'sources': [for (final role in TestRole.values) sourceJson(role)],
    });
    expect((await protocol.handle(request))['outcome'], 'initialized');
    expect(await protocol.handle(request), {'outcome': 'invalid-input'});
    final challenge = await protocol.handle(
      '{"operation":"newComparison","leg":1}',
    );
    expect(challenge['outcome'], 'comparison-issued');
    expect(await protocol.handle('{"operation":"matchGrants"}'), {
      'outcome': 'not-ready',
    });
    expect(await protocol.handle('{"operation":"newComparison","leg":4}'), {
      'outcome': 'invalid-input',
    });
    expect(await protocol.handle('{"operation":"quit","secret":"1234"}'), {
      'outcome': 'invalid-input',
    });
  });

  test(
    'protocol issues verifiable grants with only public typed success fields',
    () async {
      final protocol = NativeNearbyCoordinatorProtocol();
      final initialized = await protocol.handle(
        jsonEncode({
          'operation': 'initialize',
          'sources': [for (final role in TestRole.values) sourceJson(role)],
        }),
      );
      final sessions = initialized['sessions'] as Map;
      final issued = await protocol.handle(
        '{"operation":"newComparison","leg":1}',
      );
      final challenge = ComparisonChallenge.fromJson(issued['comparison']);
      final observations = <TestRole, SealedObservation>{};
      for (final role in TestRole.values) {
        final session = TestSession.fromJson(sessions[role.name]);
        final sealed = await sealRenderedObservation(
          session: session,
          challenge: challenge,
          observation: RenderedObservation(
            renderedCode: '739281',
            attemptId: 'attempt-a',
            localExpiresAtMillis: 1000000,
            remainingMillis: 120000,
            deviceId: session.deviceId,
            peerId: session.peerId,
          ),
        );
        observations[role] = sealed;
        final result = await protocol.handle(
          jsonEncode({
            'operation': 'acceptObserved',
            'sourceBindingId': role.name,
            'sealed': sealed.toJson(),
          }),
        );
        expect(result, {'outcome': 'accepted'});
        final malformed = sealed.toJson()
          ..['ciphertext'] = 'ws://127.0.0.1/auth-canary=/ws';
        expect(
          await protocol.handle(
            jsonEncode({
              'operation': 'acceptObserved',
              'sourceBindingId': role.name,
              'sealed': malformed,
            }),
          ),
          {'outcome': 'invalid-input'},
        );
      }
      final result = await protocol.handle('{"operation":"matchGrants"}');
      expect(result.keys.toSet(), {'outcome', 'grants'});
      expect(result['outcome'], 'grants-issued');
      for (final role in TestRole.values) {
        final session = TestSession.fromJson(sessions[role.name]);
        final grant = MatchGrant.fromJson(
          (result['grants'] as Map)[role.name],
          session,
        );
        expect(
          await Ed25519().verify(
            grant.signingBytes(),
            signature: Signature(
              nativeTestBytes(grant.signature, 64),
              publicKey: SimplePublicKey(
                nativeTestBytes(session.signingPublicKey, 32),
                type: KeyPairType.ed25519,
              ),
            ),
          ),
          isTrue,
        );
        expect(
          grant.sealedCiphertextHash,
          await observations[role]!.identityHash(),
        );
      }
      for (final canary in [
        '739281',
        'renderedCode',
        '1234',
        'PRIVATE-KEY-CANARY',
        'ws://',
        '192.168.1.179',
      ]) {
        expect(jsonEncode(result).contains(canary), isFalse);
      }
    },
  );

  test('grant retries stop at root TTL and strict parser tolerates JSON key ordering', () async {
    final f = Fixture();
    await f.initialize();
    final grants = await f.grants();
    final session = f.root.publicConfig[TestRole.sender]!;
    final m = copyJson(grants[TestRole.sender]!.toJson());
    m['session'] = Map.fromEntries(
      (m['session'] as Map<String, dynamic>).entries.toList().reversed,
    );
    expect(MatchGrant.fromJson(m, session).attemptId, 'attempt-a');
    m['version'] = 1.0;
    expect(() => MatchGrant.fromJson(m, session), failure);
    f.clock = 20000;
    await expectLater(f.root.matchGrants(), failure);
  });

  test(
    'envelope schema bounds and malformed cryptographic lengths reject',
    () async {
      final f = Fixture();
      await f.initialize();
      for (final mutation in [
        {'version': 2},
        {'version': 1.0},
        {'extra': '739281'},
        {'nonce': nativeTestRandom(11)},
        {'ephemeralPublicKey': nativeTestRandom(31)},
        {'tag': nativeTestRandom(15)},
        {'ciphertext': ''},
        {'ciphertext': 'not!base64'},
        {'ciphertext': 'A' * 2000},
      ]) {
        final m = {...f.sealed[TestRole.sender]!.toJson(), ...mutation};
        expect(() => SealedObservation.fromJson(m), failure);
      }
      expect(
        () => RenderedObservation(
          renderedCode: '12',
          attemptId: 'a',
          localExpiresAtMillis: 1,
          remainingMillis: 1,
          deviceId: 'a',
          peerId: 'b',
        ),
        failure,
      );
      expect(
        () => RenderedObservation(
          renderedCode: '739281',
          attemptId: 'a',
          localExpiresAtMillis: 1,
          remainingMillis: 120001,
          deviceId: 'a',
          peerId: 'b',
        ),
        failure,
      );
    },
  );
}
