import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/nearby/nearby_codec.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

void main() {
  test('beacon round-trip yields a peer', () {
    final bytes = encodeBeacon(
      deviceId: 'dev-1',
      name: 'Shop Mac',
      port: 41234,
      ips: ['192.168.1.10'],
    );
    final peer = peerFromBeacon(decodeBeacon(bytes));
    expect(peer, isNotNull);
    expect(peer!.deviceId, 'dev-1');
    expect(peer.name, 'Shop Mac');
    expect(peer.host, '192.168.1.10');
    expect(peer.port, 41234);
  });

  test('UDP beacon port sits outside the Windows reserved LAN band', () {
    const reservedLo = 44700;
    const reservedHi = 48799;
    expect(kNearbyUdpPort, isNot(45454));
    expect(
      kNearbyUdpPort < reservedLo || kNearbyUdpPort > reservedHi,
      isTrue,
      reason: 'Windows Impure refuses UDP ~44700–48799',
    );
    expect(kNearbyUdpPort, inInclusiveRange(1024, 65535));
  });

  test('who query is not a peer', () {
    final map = decodeBeacon(encodeWhoQuery());
    expect(isWhoQuery(map), isTrue);
    expect(peerFromBeacon(map), isNull);
  });

  test('mDNS announcement names the WiredPart service', () {
    final packet = buildMdnsAnnouncement(
      instanceName: 'Shop Mac',
      port: 41234,
      ipv4: '192.168.1.10',
      deviceId: 'dev-1',
      name: 'Shop Mac',
    );
    final text = String.fromCharCodes(packet);
    expect(text.contains('_wiredpart'), isTrue);
    expect(text.contains('Shop Mac'), isTrue);
  });

  test('nearby codec round-trips a shop payload', () async {
    final payload = BackupPayload(
      createdAt: DateTime.utc(2026, 9, 16, 18),
      sourceDeviceId: 'src-1',
      sqliteBytes: Uint8List.fromList(List<int>.generate(64, (i) => i)),
      photos: {
        'a.jpg': Uint8List.fromList([9, 8, 7]),
      },
    );
    final offer = NearbyOffer(
      sourceDeviceId: 'src-1',
      sourceName: 'Shop Mac',
      jobs: 2,
      parts: 4,
      photos: 1,
      bytes: 64,
    );
    final key = SecretKey(List.filled(32, 1));
    final bytes = await NearbyCodec().encrypt(
      payload: payload,
      key: key,
      sessionId: 'session',
      direction: 'guest',
      transferId: 'transfer',
      offer: offer,
    );
    final out = await NearbyCodec().decrypt(
      bytes,
      key,
      sessionId: 'session',
      direction: 'guest',
      transferId: 'transfer',
    );
    expect(out.offer.sourceName, 'Shop Mac');
    expect(out.offer.jobs, 2);
    expect(out.payload.sourceDeviceId, 'src-1');
    expect(out.payload.photos['a.jpg'], [9, 8, 7]);
  });

  test('wrong session key fails closed', () async {
    final payload = BackupPayload(
      createdAt: DateTime.utc(2026, 9, 16),
      sourceDeviceId: 'src-1',
      sqliteBytes: Uint8List.fromList([1, 2, 3, 4]),
      photos: const {},
    );
    final offer = NearbyOffer(
      sourceDeviceId: 'src-1',
      sourceName: 'Mac',
      jobs: 0,
      parts: 0,
      photos: 0,
      bytes: 4,
    );
    final bytes = await NearbyCodec().encrypt(
      payload: payload,
      key: SecretKey(List.filled(32, 1)),
      sessionId: 'session',
      direction: 'guest',
      transferId: 'transfer',
      offer: offer,
    );
    expect(
      () => NearbyCodec().decrypt(
        bytes,
        SecretKey(List.filled(32, 2)),
        sessionId: 'session',
        direction: 'guest',
        transferId: 'transfer',
      ),
      throwsA(isA<NearbyException>()),
    );
  });

  test('truncated transfer fails closed', () {
    expect(
      () => NearbyCodec.peekOffer(Uint8List.fromList([0x57, 0x50, 0x4c])),
      throwsA(isA<NearbyException>()),
    );
  });
}
