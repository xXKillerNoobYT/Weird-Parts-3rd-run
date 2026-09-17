import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// File magic `WPB1`. Header JSON is unencrypted (date + source device + KDF).
/// Payload is AES-256-GCM; key is PBKDF2-HMAC-SHA256 of the backup password.
const kBackupMagic = [0x57, 0x50, 0x42, 0x31];
const kBackupHeaderVersion = 1;
const kDefaultPbkdf2Iterations = 120000;
const kMaxPbkdf2Iterations = 250000;

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackupHeader {
  const BackupHeader({
    required this.createdAt,
    required this.sourceDeviceId,
    required this.iterations,
    required this.salt,
    required this.nonce,
  });

  final DateTime createdAt;
  final String sourceDeviceId;
  final int iterations;
  final Uint8List salt;
  final Uint8List nonce;
}

class BackupPayload {
  const BackupPayload({
    required this.createdAt,
    required this.sourceDeviceId,
    required this.sqliteBytes,
    required this.photos,
  });

  final DateTime createdAt;
  final String sourceDeviceId;
  final Uint8List sqliteBytes;
  final Map<String, Uint8List> photos;
}

class BackupCodec {
  BackupCodec({this.iterations = kDefaultPbkdf2Iterations});

  final int iterations;

  static final _gcm = AesGcm.with256bits();

  Future<Uint8List> encrypt(BackupPayload payload, String password) async {
    if (password.isEmpty) {
      throw const BackupFormatException('Backup password required');
    }
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final headerMap = <String, Object>{
      'v': kBackupHeaderVersion,
      'kdf': 'pbkdf2-sha256',
      'iterations': iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'createdAt': payload.createdAt.toUtc().toIso8601String(),
      'sourceDeviceId': payload.sourceDeviceId,
    };
    final headerBytes = Uint8List.fromList(utf8.encode(jsonEncode(headerMap)));
    final key = await _deriveKey(password, salt, iterations);
    final box = await _gcm.encrypt(
      packPayload(payload),
      secretKey: key,
      nonce: nonce,
      aad: headerBytes,
    );
    final cipher = Uint8List.fromList(box.cipherText);
    final mac = Uint8List.fromList(box.mac.bytes);
    final out = BytesBuilder(copy: false);
    out.add(kBackupMagic);
    _putU32(out, headerBytes.length);
    out.add(headerBytes);
    _putU32(out, cipher.length);
    out.add(cipher);
    _putU32(out, mac.length);
    out.add(mac);
    return out.toBytes();
  }

  Future<BackupPayload> decrypt(Uint8List fileBytes, String password) async {
    if (password.isEmpty) {
      throw const BackupFormatException('Backup password required');
    }
    final parsed = _splitFile(fileBytes);
    final header = parseHeaderBytes(parsed.headerBytes);
    final key = await _deriveKey(password, header.salt, header.iterations);
    final secretBox = SecretBox(
      parsed.cipher,
      nonce: header.nonce,
      mac: Mac(parsed.mac),
    );
    final List<int> plain;
    try {
      plain = await _gcm.decrypt(
        secretBox,
        secretKey: key,
        aad: parsed.headerBytes,
      );
    } catch (_) {
      throw const BackupFormatException('Wrong password or damaged backup');
    }
    return unpackPayload(Uint8List.fromList(plain));
  }

  static BackupHeader peekHeader(Uint8List fileBytes) {
    final parsed = _splitFile(fileBytes);
    return parseHeaderBytes(parsed.headerBytes);
  }
}

class _SplitFile {
  const _SplitFile({
    required this.headerBytes,
    required this.cipher,
    required this.mac,
  });
  final Uint8List headerBytes;
  final Uint8List cipher;
  final Uint8List mac;
}

_SplitFile _splitFile(Uint8List fileBytes) {
  if (fileBytes.length < 16) {
    throw const BackupFormatException('Not a Wired Parts backup');
  }
  for (var i = 0; i < 4; i++) {
    if (fileBytes[i] != kBackupMagic[i]) {
      throw const BackupFormatException('Not a Wired Parts backup');
    }
  }
  var offset = 4;
  int readU32() {
    if (offset + 4 > fileBytes.length) {
      throw const BackupFormatException('Truncated backup');
    }
    final n = (fileBytes[offset] << 24) |
        (fileBytes[offset + 1] << 16) |
        (fileBytes[offset + 2] << 8) |
        fileBytes[offset + 3];
    offset += 4;
    return n;
  }

  Uint8List readExact(int n) {
    if (n < 0 || offset + n > fileBytes.length) {
      throw const BackupFormatException('Truncated backup');
    }
    final slice = fileBytes.sublist(offset, offset + n);
    offset += n;
    return slice;
  }

  final header = readExact(readU32());
  final cipher = readExact(readU32());
  final mac = readExact(readU32());
  return _SplitFile(headerBytes: header, cipher: cipher, mac: mac);
}

BackupHeader parseHeaderBytes(Uint8List headerBytes) {
  final Object? decoded = jsonDecode(utf8.decode(headerBytes));
  if (decoded is! Map) {
    throw const BackupFormatException('Invalid backup header');
  }
  final map = Map<String, Object?>.from(decoded);
  if (map['v'] != kBackupHeaderVersion) {
    throw const BackupFormatException('Unsupported backup version');
  }
  final createdRaw = map['createdAt'] as String?;
  final device = map['sourceDeviceId'] as String?;
  final kdf = map['kdf'] as String?;
  final iterations = map['iterations'];
  final saltB64 = map['salt'] as String?;
  final nonceB64 = map['nonce'] as String?;
  if (createdRaw == null ||
      device == null ||
      kdf != 'pbkdf2-sha256' ||
      iterations is! int ||
      iterations < 1000 ||
      iterations > kMaxPbkdf2Iterations ||
      saltB64 == null ||
      nonceB64 == null) {
    throw const BackupFormatException('Invalid backup header');
  }
  final createdAt = DateTime.tryParse(createdRaw);
  if (createdAt == null) {
    throw const BackupFormatException('Invalid backup header');
  }
  return BackupHeader(
    createdAt: createdAt.toUtc(),
    sourceDeviceId: device,
    iterations: iterations,
    salt: Uint8List.fromList(base64Decode(saltB64)),
    nonce: Uint8List.fromList(base64Decode(nonceB64)),
  );
}

Uint8List packPayload(BackupPayload payload) {
  for (final name in payload.photos.keys) {
    if (!_safePhotoName(name)) {
      throw BackupFormatException('Unsafe photo name: $name');
    }
  }
  final names = payload.photos.keys.toList()..sort();
  final meta = utf8.encode(
    jsonEncode({
      'createdAt': payload.createdAt.toUtc().toIso8601String(),
      'sourceDeviceId': payload.sourceDeviceId,
      'photos': names,
    }),
  );
  final out = BytesBuilder(copy: false);
  _putU32(out, meta.length);
  out.add(meta);
  _putU32(out, payload.sqliteBytes.length);
  out.add(payload.sqliteBytes);
  for (final name in names) {
    final nameBytes = utf8.encode(name);
    _putU32(out, nameBytes.length);
    out.add(nameBytes);
    final data = payload.photos[name]!;
    _putU32(out, data.length);
    out.add(data);
  }
  return out.toBytes();
}

BackupPayload unpackPayload(Uint8List plain) {
  var offset = 0;
  int readU32() {
    if (offset + 4 > plain.length) {
      throw const BackupFormatException('Damaged backup payload');
    }
    final n = (plain[offset] << 24) |
        (plain[offset + 1] << 16) |
        (plain[offset + 2] << 8) |
        plain[offset + 3];
    offset += 4;
    return n;
  }

  Uint8List readExact(int n) {
    if (n < 0 || offset + n > plain.length) {
      throw const BackupFormatException('Damaged backup payload');
    }
    final slice = plain.sublist(offset, offset + n);
    offset += n;
    return slice;
  }

  final metaBytes = readExact(readU32());
  final Object? decoded = jsonDecode(utf8.decode(metaBytes));
  if (decoded is! Map) {
    throw const BackupFormatException('Damaged backup payload');
  }
  final map = Map<String, Object?>.from(decoded);
  final createdRaw = map['createdAt'] as String?;
  final device = map['sourceDeviceId'] as String?;
  final createdAt = createdRaw == null ? null : DateTime.tryParse(createdRaw);
  if (createdAt == null || device == null) {
    throw const BackupFormatException('Damaged backup payload');
  }
  final sqlite = readExact(readU32());
  final photos = <String, Uint8List>{};
  while (offset < plain.length) {
    final name = utf8.decode(readExact(readU32()));
    if (!_safePhotoName(name)) {
      throw BackupFormatException('Unsafe photo name: $name');
    }
    photos[name] = readExact(readU32());
  }
  return BackupPayload(
    createdAt: createdAt.toUtc(),
    sourceDeviceId: device,
    sqliteBytes: sqlite,
    photos: photos,
  );
}

bool _safePhotoName(String name) {
  if (name.isEmpty || name.length > 200) return false;
  if (name.contains('/') || name.contains('\\') || name.contains('..')) {
    return false;
  }
  return true;
}

void _putU32(BytesBuilder out, int n) {
  out.add([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Future<SecretKey> _deriveKey(
  String password,
  Uint8List salt,
  int iterations,
) {
  final kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  return kdf.deriveKeyFromPassword(password: password, nonce: salt);
}
