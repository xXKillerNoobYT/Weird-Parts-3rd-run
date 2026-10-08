import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'nearby_protocol.dart';

const _suite = 'X25519-HKDF-SHA256-AES256GCM';

List<int> _encode(List<Object> fields) => utf8.encode(jsonEncode(fields));
String nearbyDigest(List<int> bytes) => hashes.sha256.convert(bytes).toString();

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

List<int> _decode32(Object? value) {
  if (value is! String) throw const NearbyException('Invalid pairing bytes');
  final bytes = base64Decode(value);
  if (bytes.length != 32) throw const NearbyException('Invalid pairing bytes');
  return bytes;
}

String nearbyRandomId() {
  final random = Random.secure();
  return base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
}

class NearbyPairContext {
  NearbyPairContext({
    required this.id,
    required this.guestId,
    required this.hostId,
    required this.guestName,
    required this.hostName,
    required this.guestPort,
    required this.hostPort,
  });

  factory NearbyPairContext.parse(Map<String, Object?> map) {
    String field(String name) {
      final value = map[name];
      if (value is! String || value.isEmpty || value.length > 256) {
        throw const NearbyException('Invalid pairing context');
      }
      return value;
    }

    int port(String name) {
      final value = map[name];
      if (value is! int || value < 1 || value > 65535) {
        throw const NearbyException('Invalid pairing port');
      }
      return value;
    }

    if (map['v'] != kNearbyProtoVersion || map['suite'] != _suite) {
      throw const NearbyException('Update Wired Parts on both devices');
    }
    final id = field('id');
    _decode32(id);
    return NearbyPairContext(
      id: id,
      guestId: field('guestId'),
      hostId: field('hostId'),
      guestName: field('guestName'),
      hostName: field('hostName'),
      guestPort: port('guestPort'),
      hostPort: port('hostPort'),
    );
  }

  final String id;
  final String guestId;
  final String hostId;
  final String guestName;
  final String hostName;
  final int guestPort;
  final int hostPort;

  List<Object> get fields => [
    kNearbyProtoVersion,
    _suite,
    id,
    guestId,
    hostId,
    guestName,
    hostName,
    guestPort,
    hostPort,
  ];

  Map<String, Object?> toJson() => {
    'v': kNearbyProtoVersion,
    'suite': _suite,
    'id': id,
    'guestId': guestId,
    'hostId': hostId,
    'guestName': guestName,
    'hostName': hostName,
    'guestPort': guestPort,
    'hostPort': hostPort,
  };
}

class NearbyPendingPair {
  NearbyPendingPair._(
    this.context,
    this.guest,
    this._keyPair,
    this._publicKey,
    this._nonce,
  );

  static Future<NearbyPendingPair> create(
    NearbyPairContext context, {
    required bool guest,
  }) async {
    final keyPair = await X25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final random = Random.secure();
    return NearbyPendingPair._(
      context,
      guest,
      keyPair,
      publicKey.bytes,
      List.generate(32, (_) => random.nextInt(256)),
    );
  }

  final NearbyPairContext context;
  final bool guest;
  final SimpleKeyPair _keyPair;
  final List<int> _publicKey;
  final List<int> _nonce;
  List<int>? _remoteCommitment;
  bool _revealed = false;
  bool _finished = false;

  List<int> _commit(bool role, List<int> key, List<int> nonce) => hashes.sha256
      .convert(
        _encode([
          'wiredpart-v2-commit',
          ...context.fields,
          role ? 'guest' : 'host',
          base64Encode(key),
          base64Encode(nonce),
        ]),
      )
      .bytes;

  String get commitment => base64Encode(_commit(guest, _publicKey, _nonce));

  void receiveCommitment(Object? commitment) {
    if (_remoteCommitment != null) {
      throw const NearbyException('Pair commitment already received');
    }
    _remoteCommitment = _decode32(commitment);
  }

  Map<String, Object?> reveal() {
    if (_remoteCommitment == null || _revealed) {
      throw const NearbyException('Pair reveal out of order');
    }
    _revealed = true;
    return {
      'id': context.id,
      'key': base64Encode(_publicKey),
      'nonce': base64Encode(_nonce),
    };
  }

  Future<NearbyAwaitingMatch> receiveReveal(
    Map<String, Object?> message,
  ) async {
    final commitment = _remoteCommitment;
    if (commitment == null || _finished || message['id'] != context.id) {
      throw const NearbyException('Pair reveal out of order');
    }
    _finished = true;
    final key = _decode32(message['key']);
    final nonce = _decode32(message['nonce']);
    if (!_equal(commitment, _commit(!guest, key, nonce))) {
      throw const NearbyException('Pair commitment does not match');
    }
    final shared = await X25519().sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: SimplePublicKey(key, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((byte) => byte == 0)) {
      throw const NearbyException('Invalid pair public key');
    }
    final transcript = hashes.sha256
        .convert(
          _encode([
            'wiredpart-v2-transcript',
            ...context.fields,
            base64Encode(guest ? _publicKey : key),
            base64Encode(guest ? _nonce : nonce),
            base64Encode(guest ? key : _publicKey),
            base64Encode(guest ? nonce : _nonce),
          ]),
        )
        .bytes;
    Future<List<int>> derive(String label, {int length = 32}) async =>
        (await Hkdf(hmac: Hmac.sha256(), outputLength: length).deriveKey(
          secretKey: shared,
          nonce: transcript,
          info: utf8.encode('wiredpart-v2/$label'),
        )).extractBytes();
    var counter = 0;
    late int number;
    do {
      final bytes = await derive('sas/${counter++}', length: 4);
      number = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    } while (number >= 4294000000);
    final keys = NearbySessionKeys._(
      await derive(guest ? 'auth/guest' : 'auth/host'),
      await derive(guest ? 'auth/host' : 'auth/guest'),
      id: base64UrlEncode(transcript),
      guest: guest,
      sendKey: await derive(guest ? 'payload/guest' : 'payload/host'),
      receiveKey: await derive(guest ? 'payload/host' : 'payload/guest'),
    );
    return NearbyAwaitingMatch._(
      context.id,
      (number % 1000000).toString().padLeft(6, '0'),
      keys,
      await derive(guest ? 'confirm/guest' : 'confirm/host'),
      await derive(guest ? 'confirm/host' : 'confirm/guest'),
    );
  }
}

class NearbyAwaitingMatch {
  NearbyAwaitingMatch._(
    this.transactionId,
    this.code,
    this._keys,
    this._sendConfirmation,
    this._receiveConfirmation,
  );
  final String transactionId;
  final String code;
  final NearbySessionKeys _keys;
  final List<int> _sendConfirmation;
  final List<int> _receiveConfirmation;
  bool _localMatch = false;
  bool _remoteMatch = false;

  List<int> _confirmation(List<int> key) => hashes.Hmac(
    hashes.sha256,
    key,
  ).convert(_encode(['wiredpart-v2-match', transactionId, _keys.id])).bytes;

  String confirmLocal() {
    _localMatch = true;
    return base64Encode(_confirmation(_sendConfirmation));
  }

  void confirmRemote(Object? proof) {
    if (_remoteMatch ||
        !_equal(_decode32(proof), _confirmation(_receiveConfirmation))) {
      throw const NearbyException('Pair confirmation did not match');
    }
    _remoteMatch = true;
  }

  NearbySessionKeys finish() {
    if (!_localMatch || !_remoteMatch) {
      throw const NearbyException('Tap Match on both devices first');
    }
    return _keys;
  }
}

class NearbyRequestProof {
  const NearbyRequestProof(this.sequence, this.digest, this.mac);
  final int sequence;
  final String digest;
  final String mac;
}

class NearbySessionKeys {
  NearbySessionKeys._(
    this._sendAuth,
    this._receiveAuth, {
    required this.id,
    required this.guest,
    required List<int> sendKey,
    required List<int> receiveKey,
  }) : sendKey = SecretKey(sendKey),
       receiveKey = SecretKey(receiveKey);
  final String id;
  final bool guest;
  final SecretKey sendKey;
  final SecretKey receiveKey;
  final List<int> _sendAuth;
  final List<int> _receiveAuth;
  int _sent = 0;
  int _received = 0;

  String get sendDirection => guest ? 'guest' : 'host';
  String get receiveDirection => guest ? 'host' : 'guest';

  String _mac(List<int> key, List<Object> fields) => base64Encode(
    hashes.Hmac(hashes.sha256, key).convert(_encode(fields)).bytes,
  );

  List<Object> _request(
    String direction,
    int sequence,
    String method,
    String path,
    String digest,
  ) => ['wiredpart-v2-request', id, direction, sequence, method, path, digest];

  NearbyRequestProof signRequest(String method, String path, List<int> body) {
    final sequence = ++_sent;
    final digest = nearbyDigest(body);
    return NearbyRequestProof(
      sequence,
      digest,
      _mac(_sendAuth, _request(sendDirection, sequence, method, path, digest)),
    );
  }

  void acceptRequest(String method, String path, NearbyRequestProof proof) {
    if (proof.sequence <= _received ||
        proof.sequence > 9007199254740991 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(proof.digest) ||
        !_equal(
          _decode32(proof.mac),
          _decode32(
            _mac(
              _receiveAuth,
              _request(
                receiveDirection,
                proof.sequence,
                method,
                path,
                proof.digest,
              ),
            ),
          ),
        )) {
      throw const NearbyException('Invalid or repeated nearby request');
    }
    _received = proof.sequence;
  }

  void verifyBody(NearbyRequestProof proof, List<int> body) {
    if (nearbyDigest(body) != proof.digest) {
      throw const NearbyException('Nearby request was changed');
    }
  }

  List<Object> _response(
    String direction,
    NearbyRequestProof proof,
    String method,
    String path,
    int status,
    List<int> body,
  ) => [
    'wiredpart-v2-response',
    id,
    direction,
    proof.sequence,
    method,
    path,
    proof.digest,
    status,
    nearbyDigest(body),
  ];

  String signResponse(
    NearbyRequestProof proof,
    String method,
    String path,
    int status,
    List<int> body,
  ) => _mac(
    _sendAuth,
    _response(sendDirection, proof, method, path, status, body),
  );

  void verifyResponse(
    NearbyRequestProof proof,
    String method,
    String path,
    int status,
    List<int> body,
    Object? mac,
  ) {
    if (!_equal(
      _decode32(mac),
      _decode32(
        _mac(
          _receiveAuth,
          _response(receiveDirection, proof, method, path, status, body),
        ),
      ),
    )) {
      throw const NearbyException('Nearby reply was changed');
    }
  }
}
