part of '../installation/installation_security.dart';

const kCompanyJoinPurpose = 'company-join@1';

void _claimCompanyChannel(
  InstallationSecurity installation,
  NearbyJoinChannel channel,
) {
  channel._requireLive();
  final previous = installation._activeCompanyChannel;
  if (previous != null && !identical(previous._pair, channel._pair)) {
    previous.close();
  }
  installation._activeCompanyChannel = channel;
}

final class NearbyJoinChannel {
  NearbyJoinChannel._(this._pair, this._keys, this._send, this._receive);
  final NearbyPairedJoinSession _pair;
  final NearbySessionKeys _keys;
  final SecretKey _send;
  final SecretKey _receive;
  bool _closed = false;

  static Future<NearbyJoinChannel> fromPairedSession(
    NearbyPairedJoinSession pair,
  ) async {
    pair.requireCurrent();
    final keys = pair.keys;
    if (keys.purpose != kCompanyJoinPurpose) {
      throw const CompanyBootstrapRefusal('Pair for company Join first');
    }
    Future<SecretKey> derive(SecretKey key, String direction) =>
        Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
          secretKey: key,
          nonce: utf8.encode(keys.id),
          info: utf8.encode('wiredpart-v2/company-join@1/$direction'),
        );
    final result = NearbyJoinChannel._(
      pair,
      keys,
      await derive(keys.sendKey, keys.sendDirection),
      await derive(keys.receiveKey, keys.receiveDirection),
    );
    pair.requireCurrent();
    return result;
  }

  void close() {
    _closed = true;
    _pair.revoke();
  }

  void _requireLive() {
    _pair.requireCurrent();
    if (_closed) {
      throw const CompanyBootstrapRefusal('Join approval expired. Pair again.');
    }
  }
}

Map<String, Object?> _joinObject(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(raw.keys.toSet()).isNotEmpty) {
    throw const CompanyBootstrapRefusal('Unsupported Join evidence');
  }
  return Map<String, Object?>.from(raw);
}

String _joinString(
  Map<String, Object?> value,
  String key, {
  int maximum = 256,
}) {
  final result = value[key];
  if (result is! String || result.isEmpty || result.length > maximum) {
    throw const CompanyBootstrapRefusal('Invalid Join field');
  }
  return result;
}

String _joinId(Map<String, Object?> value, String key) {
  final result = _joinString(value, key, maximum: 36);
  if (!Uuid.isValidUUID(fromString: result)) {
    throw const CompanyBootstrapRefusal('Invalid Join identity');
  }
  return result;
}

String _joinDigest(Object? value) =>
    hashes.sha256.convert(utf8.encode(_securityCanonical(value))).toString();

Future<String> _joinRecipient(
  SecretKey key,
  String session,
  String recipient,
) async => base64Encode(
  (await Hmac.sha256().calculateMac(
    utf8.encode('wiredpart.company.join.recipient@1:$session:$recipient'),
    secretKey: key,
  )).bytes,
);

Future<void> _checkJoinRecipient(
  NearbyJoinChannel channel,
  Map<String, Object?> wire,
  String recipient,
) async {
  if (wire['recipient'] !=
      await _joinRecipient(channel._receive, channel._keys.id, recipient)) {
    throw const CompanyBootstrapRefusal('Join recipient binding differs');
  }
}

Future<Map<String, Object?>> _sealJoin(
  NearbyJoinChannel channel,
  String kind,
  String request,
  String recipient,
  Map<String, Object?> body,
) async {
  channel._requireLive();
  final bytes = utf8.encode(_securityCanonical(body));
  if (bytes.length > 40 * 1024) {
    throw const CompanyBootstrapRefusal('Join message capacity reached');
  }
  final header = <String, Object?>{
    'v': 1,
    'kind': kind,
    'request': request,
    'recipient': await _joinRecipient(
      channel._send,
      channel._keys.id,
      recipient,
    ),
    'session': channel._keys.id,
    'direction': channel._keys.sendDirection,
  };
  final box = await AesGcm.with256bits().encrypt(
    bytes,
    secretKey: channel._send,
    aad: utf8.encode(_securityCanonical(header)),
  );
  final wire = <String, Object?>{
    ...header,
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'tag': base64Encode(box.mac.bytes),
  };
  if (utf8.encode(_securityCanonical(wire)).length > 65536) {
    throw const CompanyBootstrapRefusal('Join envelope capacity reached');
  }
  channel._requireLive();
  return wire;
}

Future<Map<String, Object?>> _openJoin(
  NearbyJoinChannel channel,
  String kind,
  Map<String, Object?> wire, {
  String? recipient,
}) async {
  channel._requireLive();
  final value = _joinObject(wire, {
    'v',
    'kind',
    'request',
    'recipient',
    'session',
    'direction',
    'nonce',
    'ciphertext',
    'tag',
  });
  if (value['v'] != 1 ||
      value['kind'] != kind ||
      value['session'] != channel._keys.id ||
      value['direction'] != channel._keys.receiveDirection) {
    throw const CompanyBootstrapRefusal('Join channel or recipient differs');
  }
  _joinId(value, 'request');
  _joinString(value, 'recipient', maximum: 44);
  final nonceText = _joinString(value, 'nonce', maximum: 16);
  final cipherText = _joinString(value, 'ciphertext', maximum: 54616);
  final tag = _joinString(value, 'tag', maximum: 24);
  final nonce = base64Decode(nonceText);
  final ciphertext = base64Decode(cipherText);
  final mac = base64Decode(tag);
  if (nonce.length != 12 ||
      mac.length != 16 ||
      base64Encode(nonce) != nonceText ||
      base64Encode(ciphertext) != cipherText ||
      base64Encode(mac) != tag) {
    throw const CompanyBootstrapRefusal('Invalid Join encryption');
  }
  if (recipient != null) await _checkJoinRecipient(channel, value, recipient);
  channel._pair.reserveReceivedNonce(nonceText);
  final header = {...value}
    ..remove('nonce')
    ..remove('ciphertext')
    ..remove('tag');
  final bytes = await AesGcm.with256bits().decrypt(
    SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
    secretKey: channel._receive,
    aad: utf8.encode(_securityCanonical(header)),
  );
  if (bytes.length > 40 * 1024) {
    throw const CompanyBootstrapRefusal('Join message capacity reached');
  }
  channel._requireLive();
  final body = jsonDecode(utf8.decode(bytes));
  if (body is! Map<String, dynamic> ||
      _securityCanonical(body) != utf8.decode(bytes)) {
    throw const CompanyBootstrapRefusal('Noncanonical Join message');
  }
  return body;
}
