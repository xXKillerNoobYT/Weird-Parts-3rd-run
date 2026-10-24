import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../backup/backup_codec.dart';
import 'nearby_protocol.dart';

/// On-wire nearby transfer. Magic `WPL2`. Header is AAD; body is AES-256-GCM
/// of [packPayload] using a direction-specific session key.
class NearbyCodec {
  NearbyCodec();

  static final _gcm = AesGcm.with256bits();

  Future<Uint8List> encrypt({
    required BackupPayload payload,
    required SecretKey key,
    required String sessionId,
    required String direction,
    required String transferId,
    required NearbyOffer offer,
  }) async {
    final nonce = _randomBytes(12);
    final headerMap = <String, Object>{
      'v': kNearbyProtoVersion,
      'session': sessionId,
      'direction': direction,
      'transferId': transferId,
      'nonce': base64Encode(nonce),
      'sourceDeviceId': offer.sourceDeviceId,
      'sourceName': offer.sourceName,
      'createdAt': payload.createdAt.toUtc().toIso8601String(),
      'jobs': offer.jobs,
      'parts': offer.parts,
      'photos': offer.photos,
      'bytes': offer.bytes,
    };
    final headerBytes = Uint8List.fromList(utf8.encode(jsonEncode(headerMap)));
    final box = await _gcm.encrypt(
      packPayload(payload),
      secretKey: key,
      nonce: nonce,
      aad: headerBytes,
    );
    final out = BytesBuilder(copy: false);
    out.add(kNearbyTransferMagic);
    _putU32(out, headerBytes.length);
    out.add(headerBytes);
    _putU32(out, box.cipherText.length);
    out.add(box.cipherText);
    _putU32(out, box.mac.bytes.length);
    out.add(box.mac.bytes);
    return out.toBytes();
  }

  Future<({BackupPayload payload, NearbyOffer offer})> decrypt(
    Uint8List fileBytes,
    SecretKey key, {
    required String sessionId,
    required String direction,
    required String transferId,
  }) async {
    final parsed = _split(fileBytes);
    final header = _parseHeader(parsed.headerBytes);
    final metadata = jsonDecode(utf8.decode(parsed.headerBytes));
    if (metadata['session'] != sessionId ||
        metadata['direction'] != direction ||
        metadata['transferId'] != transferId) {
      throw const NearbyException('Transfer does not match this session');
    }
    final List<int> plain;
    try {
      plain = await _gcm.decrypt(
        SecretBox(parsed.cipher, nonce: header.nonce, mac: Mac(parsed.mac)),
        secretKey: key,
        aad: parsed.headerBytes,
      );
    } catch (_) {
      throw const NearbyException('Transfer was damaged or the pair expired');
    }
    final payload = unpackPayload(Uint8List.fromList(plain));
    if (payload.sourceDeviceId != header.offer.sourceDeviceId) {
      throw const NearbyException('Transfer does not match the sender');
    }
    return (payload: payload, offer: header.offer);
  }

  static NearbyOffer peekOffer(Uint8List fileBytes) {
    return _parseHeader(_split(fileBytes).headerBytes).offer;
  }
}

class _Split {
  const _Split({
    required this.headerBytes,
    required this.cipher,
    required this.mac,
  });
  final Uint8List headerBytes;
  final Uint8List cipher;
  final Uint8List mac;
}

class _Header {
  const _Header({required this.nonce, required this.offer});
  final Uint8List nonce;
  final NearbyOffer offer;
}

_Split _split(Uint8List fileBytes) {
  if (fileBytes.length < 16) {
    throw const NearbyException('Not a Wired Parts nearby transfer');
  }
  for (var i = 0; i < 4; i++) {
    if (fileBytes[i] != kNearbyTransferMagic[i]) {
      throw const NearbyException('Not a Wired Parts nearby transfer');
    }
  }
  var offset = 4;
  int readU32() {
    if (offset + 4 > fileBytes.length) {
      throw const NearbyException('Truncated nearby transfer');
    }
    final n =
        (fileBytes[offset] << 24) |
        (fileBytes[offset + 1] << 16) |
        (fileBytes[offset + 2] << 8) |
        fileBytes[offset + 3];
    offset += 4;
    return n;
  }

  Uint8List readExact(int n) {
    if (n < 0 || offset + n > fileBytes.length) {
      throw const NearbyException('Truncated nearby transfer');
    }
    final slice = fileBytes.sublist(offset, offset + n);
    offset += n;
    return slice;
  }

  final header = readExact(readU32());
  final cipher = readExact(readU32());
  final mac = readExact(readU32());
  if (offset != fileBytes.length) {
    throw const NearbyException('Damaged nearby transfer');
  }
  return _Split(headerBytes: header, cipher: cipher, mac: mac);
}

_Header _parseHeader(Uint8List headerBytes) {
  final Object? decoded = jsonDecode(utf8.decode(headerBytes));
  if (decoded is! Map) {
    throw const NearbyException('Invalid nearby header');
  }
  final map = Map<String, Object?>.from(decoded);
  if (map['v'] != kNearbyProtoVersion) {
    throw const NearbyException('Unsupported nearby version');
  }
  final nonceB64 = map['nonce'] as String?;
  final sourceId = map['sourceDeviceId'] as String?;
  final sourceName = map['sourceName'] as String? ?? '';
  final jobs = map['jobs'];
  final parts = map['parts'];
  final photos = map['photos'];
  final bytes = map['bytes'];
  if (nonceB64 == null ||
      sourceId == null ||
      jobs is! int ||
      parts is! int ||
      photos is! int ||
      bytes is! int) {
    throw const NearbyException('Invalid nearby header');
  }
  return _Header(
    nonce: Uint8List.fromList(base64Decode(nonceB64)),
    offer: NearbyOffer(
      sourceDeviceId: sourceId,
      sourceName: sourceName,
      jobs: jobs,
      parts: parts,
      photos: photos,
      bytes: bytes,
    ),
  );
}

void _putU32(BytesBuilder out, int n) {
  out.add([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}
