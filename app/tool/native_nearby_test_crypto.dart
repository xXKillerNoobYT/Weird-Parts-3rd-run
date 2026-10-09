import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

const nativeTestDomain = 'wired-parts/native-nearby-test/v1';
const nativeTestMaxEnvelopeBytes = 4096;
const nativeTestMaxGrantMillis = 20000;

enum TestRole { sender, receiver }

final class NativeTestFailure implements Exception {
  const NativeTestFailure(this.outcome);
  final String outcome;
  @override
  String toString() => 'NativeTestFailure';
}

Never rejectNativeTest([String outcome = 'invalid-input']) =>
    throw NativeTestFailure(outcome);

String nativeTestText(Object? value) {
  if (value is! String) rejectNativeTest();
  return value;
}

String nativeTestId(Object? value) {
  if (value is! String ||
      !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$').hasMatch(value)) {
    rejectNativeTest();
  }
  return value;
}

String nativeTestAttemptId(Object? value) {
  if (value is String && value.length == 44) {
    nativeTestBytes(value, 32);
    return value;
  }
  return nativeTestId(value);
}

int nativeTestInt(Object? value, {int max = 9007199254740991}) {
  if (value is! int || value <= 0 || value > max) rejectNativeTest();
  return value;
}

TestRole nativeTestRole(Object? value) => switch (value) {
  'sender' => TestRole.sender,
  'receiver' => TestRole.receiver,
  _ => rejectNativeTest(),
};

List<int> nativeTestBytes(Object? value, int length) {
  if (value is! String || value.length > 1024) rejectNativeTest();
  try {
    final bytes = base64Url.decode(value);
    if (bytes.length != length || base64Url.encode(bytes) != value) {
      rejectNativeTest();
    }
    return List<int>.unmodifiable(bytes);
  } catch (_) {
    rejectNativeTest();
  }
}

Map<String, dynamic> nativeTestMap(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    rejectNativeTest();
  }
  return value;
}

List<int> nativeTestCanonical(List<Object?> values) =>
    utf8.encode(jsonEncode(values));
String nativeTestRandom(int count) => base64Url.encode(
  List<int>.generate(count, (_) => Random.secure().nextInt(256)),
);
bool nativeTestEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

final class TestSession {
  TestSession({
    required String epoch,
    required String run,
    required this.role,
    required String deviceId,
    required String peerId,
    required String encryptionPublicKey,
    required String signingPublicKey,
  }) : epoch = nativeTestId(epoch),
       run = nativeTestId(run),
       deviceId = nativeTestId(deviceId),
       peerId = nativeTestId(peerId),
       encryptionPublicKey = base64Url.encode(
         nativeTestBytes(encryptionPublicKey, 32),
       ),
       signingPublicKey = base64Url.encode(
         nativeTestBytes(signingPublicKey, 32),
       ) {
    if (deviceId == peerId) rejectNativeTest();
  }
  final String epoch, run, deviceId, peerId;
  final TestRole role;
  final String encryptionPublicKey, signingPublicKey;
  factory TestSession.fromJson(Object? value) {
    final m = nativeTestMap(value, {
      'epoch',
      'run',
      'role',
      'deviceId',
      'peerId',
      'encryptionPublicKey',
      'signingPublicKey',
    });
    return TestSession(
      epoch: nativeTestId(m['epoch']),
      run: nativeTestId(m['run']),
      role: nativeTestRole(m['role']),
      deviceId: nativeTestId(m['deviceId']),
      peerId: nativeTestId(m['peerId']),
      encryptionPublicKey: nativeTestText(m['encryptionPublicKey']),
      signingPublicKey: nativeTestText(m['signingPublicKey']),
    );
  }
  Map<String, Object> toJson() => {
    'epoch': epoch,
    'run': run,
    'role': role.name,
    'deviceId': deviceId,
    'peerId': peerId,
    'encryptionPublicKey': encryptionPublicKey,
    'signingPublicKey': signingPublicKey,
  };
}

final class ComparisonChallenge {
  ComparisonChallenge({
    required String epoch,
    required int leg,
    required int comparisonId,
    required String challenge,
  }) : epoch = nativeTestId(epoch),
       leg = nativeTestInt(leg, max: 3),
       comparisonId = nativeTestInt(comparisonId),
       challenge = base64Url.encode(nativeTestBytes(challenge, 32));
  factory ComparisonChallenge.fromJson(Object? value) {
    final m = nativeTestMap(value, {
      'epoch',
      'leg',
      'comparisonId',
      'challenge',
    });
    return ComparisonChallenge(
      epoch: nativeTestId(m['epoch']),
      leg: nativeTestInt(m['leg'], max: 3),
      comparisonId: nativeTestInt(m['comparisonId']),
      challenge: nativeTestText(m['challenge']),
    );
  }
  final String epoch, challenge;
  final int leg, comparisonId;
  Map<String, Object> toJson() => {
    'epoch': epoch,
    'leg': leg,
    'comparisonId': comparisonId,
    'challenge': challenge,
  };
  List<int> aad(TestSession session) => nativeTestCanonical([
    nativeTestDomain,
    1,
    'rendered-observation',
    session.epoch,
    session.run,
    session.role.name,
    leg,
    comparisonId,
    challenge,
  ]);
}

final class SealedObservation {
  SealedObservation._(
    this.epoch,
    this.run,
    this.role,
    this.challenge,
    this.ephemeralPublicKey,
    this.nonce,
    this.ciphertext,
    this.tag,
  );
  factory SealedObservation.fromJson(Object? value) {
    final m = nativeTestMap(value, {
      'version',
      'epoch',
      'run',
      'role',
      'comparison',
      'ephemeralPublicKey',
      'nonce',
      'ciphertext',
      'tag',
    });
    if (m['version'] is! int || m['version'] != 1) rejectNativeTest();
    final challenge = ComparisonChallenge.fromJson(m['comparison']);
    final epoch = nativeTestId(m['epoch']);
    if (challenge.epoch != epoch) rejectNativeTest();
    final cipher = m['ciphertext'];
    if (cipher is! String || cipher.length > 1024) rejectNativeTest();
    final List<int> bytes;
    try {
      bytes = base64Url.decode(cipher);
    } catch (_) {
      rejectNativeTest();
    }
    if (bytes.isEmpty ||
        bytes.length > 768 ||
        base64Url.encode(bytes) != cipher) {
      rejectNativeTest();
    }
    return SealedObservation._(
      epoch,
      nativeTestId(m['run']),
      nativeTestRole(m['role']),
      challenge,
      nativeTestBytes(m['ephemeralPublicKey'], 32),
      nativeTestBytes(m['nonce'], 12),
      List<int>.unmodifiable(bytes),
      nativeTestBytes(m['tag'], 16),
    );
  }
  final String epoch, run;
  final TestRole role;
  final ComparisonChallenge challenge;
  final List<int> ephemeralPublicKey, nonce, ciphertext, tag;
  Map<String, Object> toJson() => {
    'version': 1,
    'epoch': epoch,
    'run': run,
    'role': role.name,
    'comparison': challenge.toJson(),
    'ephemeralPublicKey': base64Url.encode(ephemeralPublicKey),
    'nonce': base64Url.encode(nonce),
    'ciphertext': base64Url.encode(ciphertext),
    'tag': base64Url.encode(tag),
  };
  Future<String> identityHash() async => base64Url.encode(
    (await Sha256().hash(
      nativeTestCanonical([
        nativeTestDomain,
        1,
        'sealed-identity',
        epoch,
        run,
        role.name,
        challenge.leg,
        challenge.comparisonId,
        challenge.challenge,
        base64Url.encode(ephemeralPublicKey),
        base64Url.encode(nonce),
        base64Url.encode(ciphertext),
        base64Url.encode(tag),
      ]),
    )).bytes,
  );
}

final class RenderedObservation {
  RenderedObservation({
    required String renderedCode,
    required String attemptId,
    required int localExpiresAtMillis,
    required int remainingMillis,
    required String deviceId,
    required String peerId,
  }) : renderedCode = _code(renderedCode),
       attemptId = nativeTestAttemptId(attemptId),
       localExpiresAtMillis = nativeTestInt(localExpiresAtMillis),
       remainingMillis = nativeTestInt(remainingMillis, max: 120000),
       deviceId = nativeTestId(deviceId),
       peerId = nativeTestId(peerId);
  factory RenderedObservation.fromJson(Object? value) {
    final m = nativeTestMap(value, {
      'renderedCode',
      'attemptId',
      'localExpiresAtMillis',
      'remainingMillis',
      'deviceId',
      'peerId',
    });
    return RenderedObservation(
      renderedCode: nativeTestText(m['renderedCode']),
      attemptId: nativeTestAttemptId(m['attemptId']),
      localExpiresAtMillis: nativeTestInt(m['localExpiresAtMillis']),
      remainingMillis: nativeTestInt(m['remainingMillis'], max: 120000),
      deviceId: nativeTestId(m['deviceId']),
      peerId: nativeTestId(m['peerId']),
    );
  }
  static String _code(String code) {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) rejectNativeTest();
    return code;
  }

  final String renderedCode, attemptId, deviceId, peerId;
  final int localExpiresAtMillis, remainingMillis;
  Map<String, Object> _toJson() => {
    'renderedCode': renderedCode,
    'attemptId': attemptId,
    'localExpiresAtMillis': localExpiresAtMillis,
    'remainingMillis': remainingMillis,
    'deviceId': deviceId,
    'peerId': peerId,
  };
}

Future<SecretKey> _observationKey(
  KeyPair local,
  List<int> remote,
  List<int> aad,
) async {
  final shared = await X25519().sharedSecretKey(
    keyPair: local,
    remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
  );
  if ((await shared.extractBytes()).every((b) => b == 0)) {
    rejectNativeTest('invalid-envelope');
  }
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: utf8.encode(nativeTestDomain),
    info: aad,
  );
}

Future<SealedObservation> sealRenderedObservation({
  required TestSession session,
  required ComparisonChallenge challenge,
  required RenderedObservation observation,
}) async {
  if (challenge.epoch != session.epoch ||
      observation.deviceId != session.deviceId ||
      observation.peerId != session.peerId) {
    rejectNativeTest('context-mismatch');
  }
  try {
    final ephemeral = await X25519().newKeyPair();
    final aad = challenge.aad(session);
    final key = await _observationKey(
      ephemeral,
      nativeTestBytes(session.encryptionPublicKey, 32),
      aad,
    );
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(observation._toJson())),
      secretKey: key,
      nonce: nativeTestBytes(nativeTestRandom(12), 12),
      aad: aad,
    );
    return SealedObservation._(
      session.epoch,
      session.run,
      session.role,
      challenge,
      List<int>.unmodifiable((await ephemeral.extractPublicKey()).bytes),
      List<int>.unmodifiable(box.nonce),
      List<int>.unmodifiable(box.cipherText),
      List<int>.unmodifiable(box.mac.bytes),
    );
  } catch (_) {
    rejectNativeTest('invalid-envelope');
  }
}

Future<RenderedObservation> openRenderedObservation({
  required KeyPair encryptionKey,
  required TestSession session,
  required ComparisonChallenge challenge,
  required SealedObservation sealed,
}) async {
  if (sealed.epoch != session.epoch ||
      sealed.run != session.run ||
      sealed.role != session.role ||
      jsonEncode(sealed.challenge.toJson()) != jsonEncode(challenge.toJson())) {
    rejectNativeTest('context-mismatch');
  }
  try {
    final aad = challenge.aad(session);
    final key = await _observationKey(
      encryptionKey,
      sealed.ephemeralPublicKey,
      aad,
    );
    final bytes = await AesGcm.with256bits().decrypt(
      SecretBox(sealed.ciphertext, nonce: sealed.nonce, mac: Mac(sealed.tag)),
      secretKey: key,
      aad: aad,
    );
    final observation = RenderedObservation.fromJson(
      jsonDecode(utf8.decode(bytes)),
    );
    if (observation.deviceId != session.deviceId ||
        observation.peerId != session.peerId) {
      rejectNativeTest();
    }
    return observation;
  } catch (_) {
    rejectNativeTest('invalid-envelope');
  }
}

final class MatchGrant {
  MatchGrant({
    required this.session,
    required this.comparison,
    required String attemptId,
    required String sealedCiphertextHash,
    required int localExpiresAtMillis,
    required int ttlMillis,
    required String signature,
  }) : attemptId = nativeTestAttemptId(attemptId),
       sealedCiphertextHash = base64Url.encode(
         nativeTestBytes(sealedCiphertextHash, 32),
       ),
       localExpiresAtMillis = nativeTestInt(localExpiresAtMillis),
       ttlMillis = nativeTestInt(ttlMillis, max: nativeTestMaxGrantMillis),
       signature = base64Url.encode(nativeTestBytes(signature, 64));
  final TestSession session;
  final ComparisonChallenge comparison;
  final String attemptId, sealedCiphertextHash, signature;
  final int localExpiresAtMillis, ttlMillis;
  List<int> signingBytes() => nativeTestCanonical([
    nativeTestDomain,
    1,
    'match-grant',
    session.epoch,
    session.run,
    session.role.name,
    session.deviceId,
    session.peerId,
    comparison.leg,
    comparison.comparisonId,
    comparison.challenge,
    attemptId,
    sealedCiphertextHash,
    localExpiresAtMillis,
    ttlMillis,
  ]);
  Map<String, Object> toJson() => {
    'version': 1,
    'session': session.toJson(),
    'comparison': comparison.toJson(),
    'attemptId': attemptId,
    'sealedCiphertextHash': sealedCiphertextHash,
    'localExpiresAtMillis': localExpiresAtMillis,
    'ttlMillis': ttlMillis,
    'signature': signature,
  };
  factory MatchGrant.fromJson(Object? value, TestSession expectedSession) {
    final m = nativeTestMap(value, {
      'version',
      'session',
      'comparison',
      'attemptId',
      'sealedCiphertextHash',
      'localExpiresAtMillis',
      'ttlMillis',
      'signature',
    });
    final sessionFields = expectedSession.toJson();
    final suppliedSession = nativeTestMap(
      m['session'],
      sessionFields.keys.toSet(),
    );
    if (m['version'] is! int ||
        m['version'] != 1 ||
        !sessionFields.entries.every(
          (e) => suppliedSession[e.key] == e.value,
        )) {
      rejectNativeTest('context-mismatch');
    }
    return MatchGrant(
      session: expectedSession,
      comparison: ComparisonChallenge.fromJson(m['comparison']),
      attemptId: nativeTestAttemptId(m['attemptId']),
      sealedCiphertextHash: nativeTestText(m['sealedCiphertextHash']),
      localExpiresAtMillis: nativeTestInt(m['localExpiresAtMillis']),
      ttlMillis: nativeTestInt(m['ttlMillis'], max: nativeTestMaxGrantMillis),
      signature: nativeTestText(m['signature']),
    );
  }
}

final class MatchGrantVerifier {
  MatchGrantVerifier(this.session);
  final TestSession session;
  int _comparisonHighWater = 0;
  bool _verifying = false;
  Future<void> consume({
    required MatchGrant grant,
    required SealedObservation savedObservation,
    required ComparisonChallenge challenge,
    required RenderedObservation savedPlaintext,
    required String activeAttemptId,
    required String currentRenderedCode,
    required int localExpiresAtMillis,
    required int observationCapturedElapsedMillis,
    required int nowElapsedMillis,
    required int nowMillis,
    required bool Function() isStillCurrent,
  }) async {
    if (_verifying) rejectNativeTest('grant-rejected');
    _verifying = true;
    try {
      final age = nowElapsedMillis - observationCapturedElapsedMillis;
      if (jsonEncode(grant.session.toJson()) != jsonEncode(session.toJson()) ||
          jsonEncode(grant.comparison.toJson()) !=
              jsonEncode(challenge.toJson()) ||
          challenge.epoch != session.epoch ||
          challenge.comparisonId <= _comparisonHighWater ||
          savedObservation.epoch != session.epoch ||
          savedObservation.run != session.run ||
          savedObservation.role != session.role ||
          jsonEncode(savedObservation.challenge.toJson()) !=
              jsonEncode(challenge.toJson()) ||
          savedPlaintext.deviceId != session.deviceId ||
          savedPlaintext.peerId != session.peerId ||
          grant.attemptId != savedPlaintext.attemptId ||
          grant.attemptId != activeAttemptId ||
          currentRenderedCode != savedPlaintext.renderedCode ||
          grant.localExpiresAtMillis != localExpiresAtMillis ||
          savedPlaintext.localExpiresAtMillis != localExpiresAtMillis ||
          nowMillis >= localExpiresAtMillis ||
          age < 0 ||
          age >= grant.ttlMillis ||
          age >= savedPlaintext.remainingMillis ||
          grant.sealedCiphertextHash != await savedObservation.identityHash()) {
        rejectNativeTest('grant-rejected');
      }
      final valid = await Ed25519().verify(
        grant.signingBytes(),
        signature: Signature(
          nativeTestBytes(grant.signature, 64),
          publicKey: SimplePublicKey(
            nativeTestBytes(session.signingPublicKey, 32),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!valid || !isStillCurrent()) rejectNativeTest('grant-rejected');
      _comparisonHighWater = challenge.comparisonId;
    } finally {
      _verifying = false;
    }
  }
}

enum PrivateSnapshotStage {
  baseline,
  preLeg1,
  postLeg1,
  preLeg2,
  postLeg2,
  preLeg3,
  postLeg3,
  finalState;

  String get wireName => this == finalState ? 'final' : name;
  static PrivateSnapshotStage parse(Object? value) {
    for (final stage in values) {
      if (stage.wireName == value) return stage;
    }
    rejectNativeTest();
  }
}

int _snapshotCount(Object? value) {
  if (value is! int || value < 0 || value > 1000000) rejectNativeTest();
  return value;
}

bool _snapshotBool(Object? value) {
  if (value is! bool) rejectNativeTest();
  return value;
}

String _snapshotDigest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    rejectNativeTest();
  }
  return value;
}

final class PrivateSnapshotProof {
  PrivateSnapshotProof({
    required String domainDigest,
    required String assetsDigest,
    required String completeSettingsDigest,
    required String sharedSettingsDigestIncludingPin,
    required String profileDigest,
    required String pinDigest,
    required int schemaVersion,
    required int tableCount,
    required int rowCount,
    required int assetCount,
    required int referenceCount,
    required this.integrityValid,
    required this.referencesValid,
  }) : domainDigest = _snapshotDigest(domainDigest),
       assetsDigest = _snapshotDigest(assetsDigest),
       completeSettingsDigest = _snapshotDigest(completeSettingsDigest),
       sharedSettingsDigestIncludingPin = _snapshotDigest(
         sharedSettingsDigestIncludingPin,
       ),
       profileDigest = _snapshotDigest(profileDigest),
       pinDigest = _snapshotDigest(pinDigest),
       schemaVersion = nativeTestInt(schemaVersion, max: 1000),
       tableCount = nativeTestInt(tableCount, max: 1000),
       rowCount = _snapshotCount(rowCount),
       assetCount = _snapshotCount(assetCount),
       referenceCount = _snapshotCount(referenceCount);
  factory PrivateSnapshotProof.fromJson(Object? value) {
    final m = nativeTestMap(value, {
      'domainDigest',
      'assetsDigest',
      'completeSettingsDigest',
      'sharedSettingsDigestIncludingPin',
      'profileDigest',
      'pinDigest',
      'schemaVersion',
      'tableCount',
      'rowCount',
      'assetCount',
      'referenceCount',
      'integrityValid',
      'referencesValid',
    });
    return PrivateSnapshotProof(
      domainDigest: _snapshotDigest(m['domainDigest']),
      assetsDigest: _snapshotDigest(m['assetsDigest']),
      completeSettingsDigest: _snapshotDigest(m['completeSettingsDigest']),
      sharedSettingsDigestIncludingPin: _snapshotDigest(
        m['sharedSettingsDigestIncludingPin'],
      ),
      profileDigest: _snapshotDigest(m['profileDigest']),
      pinDigest: _snapshotDigest(m['pinDigest']),
      schemaVersion: nativeTestInt(m['schemaVersion'], max: 1000),
      tableCount: nativeTestInt(m['tableCount'], max: 1000),
      rowCount: _snapshotCount(m['rowCount']),
      assetCount: _snapshotCount(m['assetCount']),
      referenceCount: _snapshotCount(m['referenceCount']),
      integrityValid: _snapshotBool(m['integrityValid']),
      referencesValid: _snapshotBool(m['referencesValid']),
    );
  }
  final String domainDigest,
      assetsDigest,
      completeSettingsDigest,
      sharedSettingsDigestIncludingPin,
      profileDigest,
      pinDigest;
  final int schemaVersion, tableCount, rowCount, assetCount, referenceCount;
  final bool integrityValid, referencesValid;
  Map<String, Object> _toJson() => {
    'domainDigest': domainDigest,
    'assetsDigest': assetsDigest,
    'completeSettingsDigest': completeSettingsDigest,
    'sharedSettingsDigestIncludingPin': sharedSettingsDigestIncludingPin,
    'profileDigest': profileDigest,
    'pinDigest': pinDigest,
    'schemaVersion': schemaVersion,
    'tableCount': tableCount,
    'rowCount': rowCount,
    'assetCount': assetCount,
    'referenceCount': referenceCount,
    'integrityValid': integrityValid,
    'referencesValid': referencesValid,
  };
}

List<int> _privateSnapshotAad(
  TestSession session,
  PrivateSnapshotStage stage,
  int ordinal,
) => nativeTestCanonical([
  nativeTestDomain,
  1,
  'private-snapshot',
  session.epoch,
  session.run,
  session.role.name,
  session.deviceId,
  session.peerId,
  stage.wireName,
  ordinal,
]);

final class SealedPrivateSnapshot {
  SealedPrivateSnapshot._(
    this.epoch,
    this.run,
    this.role,
    this.stage,
    this.ordinal,
    this.ephemeralPublicKey,
    this.nonce,
    this.ciphertext,
    this.tag,
  );
  factory SealedPrivateSnapshot.fromJson(Object? value) {
    final m = nativeTestMap(value, {
      'version',
      'epoch',
      'run',
      'role',
      'stage',
      'ordinal',
      'ephemeralPublicKey',
      'nonce',
      'ciphertext',
      'tag',
    });
    if (m['version'] is! int || m['version'] != 1) rejectNativeTest();
    final cipher = nativeTestText(m['ciphertext']);
    if (cipher.isEmpty || cipher.length > 2048) rejectNativeTest();
    final List<int> bytes;
    try {
      bytes = base64Url.decode(cipher);
    } catch (_) {
      rejectNativeTest();
    }
    if (bytes.isEmpty ||
        bytes.length > 1536 ||
        base64Url.encode(bytes) != cipher) {
      rejectNativeTest();
    }
    return SealedPrivateSnapshot._(
      nativeTestId(m['epoch']),
      nativeTestId(m['run']),
      nativeTestRole(m['role']),
      PrivateSnapshotStage.parse(m['stage']),
      nativeTestInt(m['ordinal']),
      nativeTestBytes(m['ephemeralPublicKey'], 32),
      nativeTestBytes(m['nonce'], 12),
      List<int>.unmodifiable(bytes),
      nativeTestBytes(m['tag'], 16),
    );
  }
  final String epoch, run;
  final TestRole role;
  final PrivateSnapshotStage stage;
  final int ordinal;
  final List<int> ephemeralPublicKey, nonce, ciphertext, tag;
  Map<String, Object> toJson() => {
    'version': 1,
    'epoch': epoch,
    'run': run,
    'role': role.name,
    'stage': stage.wireName,
    'ordinal': ordinal,
    'ephemeralPublicKey': base64Url.encode(ephemeralPublicKey),
    'nonce': base64Url.encode(nonce),
    'ciphertext': base64Url.encode(ciphertext),
    'tag': base64Url.encode(tag),
  };
  Future<String> identityHash() async => base64Url.encode(
    (await Sha256().hash(
      nativeTestCanonical([
        nativeTestDomain,
        1,
        'sealed-private-snapshot',
        epoch,
        run,
        role.name,
        stage.wireName,
        ordinal,
        base64Url.encode(ephemeralPublicKey),
        base64Url.encode(nonce),
        base64Url.encode(ciphertext),
        base64Url.encode(tag),
      ]),
    )).bytes,
  );
}

Future<SealedPrivateSnapshot> sealPrivateSnapshot({
  required TestSession session,
  required PrivateSnapshotStage stage,
  required int ordinal,
  required PrivateSnapshotProof proof,
}) async {
  nativeTestInt(ordinal);
  try {
    final ephemeral = await X25519().newKeyPair();
    final aad = _privateSnapshotAad(session, stage, ordinal);
    final key = await _observationKey(
      ephemeral,
      nativeTestBytes(session.encryptionPublicKey, 32),
      aad,
    );
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(proof._toJson())),
      secretKey: key,
      nonce: nativeTestBytes(nativeTestRandom(12), 12),
      aad: aad,
    );
    return SealedPrivateSnapshot._(
      session.epoch,
      session.run,
      session.role,
      stage,
      ordinal,
      List<int>.unmodifiable((await ephemeral.extractPublicKey()).bytes),
      List<int>.unmodifiable(box.nonce),
      List<int>.unmodifiable(box.cipherText),
      List<int>.unmodifiable(box.mac.bytes),
    );
  } catch (_) {
    rejectNativeTest('invalid-envelope');
  }
}

Future<PrivateSnapshotProof> openPrivateSnapshot({
  required KeyPair encryptionKey,
  required TestSession session,
  required SealedPrivateSnapshot sealed,
}) async {
  if (sealed.epoch != session.epoch ||
      sealed.run != session.run ||
      sealed.role != session.role) {
    rejectNativeTest('context-mismatch');
  }
  try {
    final aad = _privateSnapshotAad(session, sealed.stage, sealed.ordinal);
    final key = await _observationKey(
      encryptionKey,
      sealed.ephemeralPublicKey,
      aad,
    );
    final bytes = await AesGcm.with256bits().decrypt(
      SecretBox(sealed.ciphertext, nonce: sealed.nonce, mac: Mac(sealed.tag)),
      secretKey: key,
      aad: aad,
    );
    return PrivateSnapshotProof.fromJson(jsonDecode(utf8.decode(bytes)));
  } catch (_) {
    rejectNativeTest('invalid-envelope');
  }
}
