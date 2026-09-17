import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';

void main() {
  final codec = BackupCodec(iterations: 1000);

  BackupPayload sample() => BackupPayload(
        createdAt: DateTime.utc(2026, 9, 13, 20, 15),
        sourceDeviceId: 'dev-source-1',
        sqliteBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
        photos: {
          'part-a-1.jpg': Uint8List.fromList([0xFF, 0xD8, 0x01]),
        },
      );

  test('round-trip encrypt and decrypt restores sqlite, photos, meta', () async {
    final payload = sample();
    final file = await codec.encrypt(payload, 'secret-pass');
    final header = BackupCodec.peekHeader(file);
    expect(header.sourceDeviceId, 'dev-source-1');
    expect(header.createdAt, DateTime.utc(2026, 9, 13, 20, 15));

    final back = await codec.decrypt(file, 'secret-pass');
    expect(back.sourceDeviceId, payload.sourceDeviceId);
    expect(back.createdAt, payload.createdAt);
    expect(back.sqliteBytes, payload.sqliteBytes);
    expect(back.photos.keys, ['part-a-1.jpg']);
    expect(back.photos['part-a-1.jpg'], payload.photos['part-a-1.jpg']);
  });

  test('wrong password fails', () async {
    final file = await codec.encrypt(sample(), 'secret-pass');
    await expectLater(
      codec.decrypt(file, 'wrong'),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('empty password is rejected', () async {
    await expectLater(
      codec.encrypt(sample(), ''),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('garbage bytes are not a backup', () {
    expect(
      () => BackupCodec.peekHeader(Uint8List.fromList([1, 2, 3, 4, 5])),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('rejects a newer backup header version', () {
    final header = utf8.encode(
      jsonEncode({
        'v': 2,
        'kdf': 'pbkdf2-sha256',
        'iterations': 1000,
        'salt': base64Encode(Uint8List(16)),
        'nonce': base64Encode(Uint8List(12)),
        'createdAt': '2026-09-13T20:00:00.000Z',
        'sourceDeviceId': 'dev-x',
      }),
    );
    expect(
      () => parseHeaderBytes(Uint8List.fromList(header)),
      throwsA(
        isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('Unsupported backup version'),
        ),
      ),
    );
  });

  test('rejects attacker-chosen huge PBKDF2 iterations', () {
    final header = utf8.encode(
      jsonEncode({
        'v': 1,
        'kdf': 'pbkdf2-sha256',
        'iterations': 999999999,
        'salt': base64Encode(Uint8List(16)),
        'nonce': base64Encode(Uint8List(12)),
        'createdAt': '2026-09-13T20:00:00.000Z',
        'sourceDeviceId': 'dev-x',
      }),
    );
    expect(
      () => parseHeaderBytes(Uint8List.fromList(header)),
      throwsA(isA<BackupFormatException>()),
    );
  });
}
