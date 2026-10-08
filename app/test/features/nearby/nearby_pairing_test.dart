import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/nearby/nearby_pairing.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

NearbyPairContext context() => NearbyPairContext(
  id: base64Encode(List.filled(32, 1)),
  guestId: 'guest',
  hostId: 'host',
  guestName: 'Guest',
  hostName: 'Host',
  guestPort: 1234,
  hostPort: 5678,
);

Future<(NearbyAwaitingMatch, NearbyAwaitingMatch)> exchange() async {
  final guest = await NearbyPendingPair.create(context(), guest: true);
  final host = await NearbyPendingPair.create(context(), guest: false);
  guest.receiveCommitment(host.commitment);
  host.receiveCommitment(guest.commitment);
  final guestReveal = guest.reveal();
  final hostReveal = host.reveal();
  return (
    await guest.receiveReveal(hostReveal),
    await host.receiveReveal(guestReveal),
  );
}

Future<(NearbySessionKeys, NearbySessionKeys)> sessions() async {
  final (guest, host) = await exchange();
  final guestProof = guest.confirmLocal();
  final hostProof = host.confirmLocal();
  guest.confirmRemote(hostProof);
  host.confirmRemote(guestProof);
  return (guest.finish(), host.finish());
}

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

void main() {
  test('X25519 RFC 7748 shared secret vector', () async {
    final key = await X25519().newKeyPairFromSeed(
      hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'),
    );
    final secret = await X25519().sharedSecretKey(
      keyPair: key,
      remotePublicKey: SimplePublicKey(
        hex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f'),
        type: KeyPairType.x25519,
      ),
    );
    expect(
      await secret.extractBytes(),
      hex('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'),
    );
  });

  test('HKDF RFC 5869 test case 1', () async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 42).deriveKey(
      secretKey: SecretKey(List.filled(22, 0x0b)),
      nonce: hex('000102030405060708090a0b0c'),
      info: hex('f0f1f2f3f4f5f6f7f8f9'),
    );
    expect(
      await key.extractBytes(),
      hex(
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
      ),
    );
  });

  test('both devices derive same SAS and require both Match proofs', () async {
    final (guest, host) = await exchange();
    expect(guest.code, matches(RegExp(r'^\d{6}$')));
    expect(host.code, guest.code);
    expect(guest.finish, throwsA(isA<NearbyException>()));
    final proof = guest.confirmLocal();
    host.confirmRemote(proof);
    expect(host.finish, throwsA(isA<NearbyException>()));
    expect(guest.finish, throwsA(isA<NearbyException>()));
    guest.confirmRemote(host.confirmLocal());
    final g = guest.finish();
    final h = host.finish();
    expect(await g.sendKey.extractBytes(), await h.receiveKey.extractBytes());
    expect(
      await g.sendKey.extractBytes(),
      isNot(await g.receiveKey.extractBytes()),
    );
    expect(() => host.confirmRemote(proof), throwsA(isA<NearbyException>()));
  });

  test('reflected Match proof and cross-session proof fail', () async {
    final (guest, _) = await exchange();
    final (other, _) = await exchange();
    expect(
      () => guest.confirmRemote(guest.confirmLocal()),
      throwsA(isA<NearbyException>()),
    );
    expect(
      () => guest.confirmRemote(other.confirmLocal()),
      throwsA(isA<NearbyException>()),
    );
  });

  test('commitment must precede reveal and cannot be replaced', () async {
    final guest = await NearbyPendingPair.create(context(), guest: true);
    final host = await NearbyPendingPair.create(context(), guest: false);
    expect(guest.reveal, throwsA(isA<NearbyException>()));
    guest.receiveCommitment(host.commitment);
    expect(
      () => guest.receiveCommitment(host.commitment),
      throwsA(isA<NearbyException>()),
    );
    guest.reveal();
    expect(guest.reveal, throwsA(isA<NearbyException>()));
  });

  test('changed reveal fails before any session is available', () async {
    final guest = await NearbyPendingPair.create(context(), guest: true);
    final host = await NearbyPendingPair.create(context(), guest: false);
    guest.receiveCommitment(host.commitment);
    host.receiveCommitment(guest.commitment);
    final reveal = host.reveal()..['nonce'] = base64Encode(List.filled(32, 0));
    await expectLater(
      guest.receiveReveal(reveal),
      throwsA(isA<NearbyException>()),
    );
    await expectLater(
      guest.receiveReveal(reveal),
      throwsA(isA<NearbyException>()),
    );
  });

  test('committed zero public key is rejected', () async {
    final guest = await NearbyPendingPair.create(context(), guest: true);
    final zero = base64Encode(List.filled(32, 0));
    final commitment = hashes.sha256.convert(
      utf8.encode(
        jsonEncode([
          'wiredpart-v2-commit',
          ...context().fields,
          'host',
          zero,
          zero,
        ]),
      ),
    );
    guest.receiveCommitment(base64Encode(commitment.bytes));
    guest.reveal();
    await expectLater(
      guest.receiveReveal({'id': context().id, 'key': zero, 'nonce': zero}),
      throwsA(isA<NearbyException>()),
    );
  });

  test('identity substitution invalidates committed reveal', () async {
    final original = context();
    final changed = NearbyPairContext(
      id: original.id,
      guestId: 'intruder',
      hostId: original.hostId,
      guestName: original.guestName,
      hostName: original.hostName,
      guestPort: original.guestPort,
      hostPort: original.hostPort,
    );
    final guest = await NearbyPendingPair.create(original, guest: true);
    final host = await NearbyPendingPair.create(changed, guest: false);
    guest.receiveCommitment(host.commitment);
    host.receiveCommitment(guest.commitment);
    await expectLater(
      guest.receiveReveal(host.reveal()),
      throwsA(isA<NearbyException>()),
    );
  });

  test('old protocol and alternate suite have no downgrade path', () {
    final old = context().toJson()..['v'] = 1;
    final alternate = context().toJson()..['suite'] = 'plaintext';
    expect(() => NearbyPairContext.parse(old), throwsA(isA<NearbyException>()));
    expect(
      () => NearbyPairContext.parse(alternate),
      throwsA(isA<NearbyException>()),
    );
  });

  test(
    'fresh exchanges produce different session and encryption keys',
    () async {
      final (first, _) = await sessions();
      final (second, _) = await sessions();
      expect(first.id, isNot(second.id));
      expect(
        await first.sendKey.extractBytes(),
        isNot(await second.sendKey.extractBytes()),
      );
    },
  );

  test(
    'request authenticates role method path body and rejects replay',
    () async {
      final (guest, host) = await sessions();
      final bytes = utf8.encode('{"offer":1}');
      final proof = guest.signRequest('POST', '/v2/offer', bytes);
      expect(
        () => guest.acceptRequest('POST', '/v2/offer', proof),
        throwsA(isA<NearbyException>()),
      );
      expect(
        () => host.acceptRequest('PUT', '/v2/offer', proof),
        throwsA(isA<NearbyException>()),
      );
      expect(
        () => host.acceptRequest('POST', '/v2/transfer', proof),
        throwsA(isA<NearbyException>()),
      );
      host.acceptRequest('POST', '/v2/offer', proof);
      host.verifyBody(proof, bytes);
      expect(
        () => host.verifyBody(proof, [...bytes, 1]),
        throwsA(isA<NearbyException>()),
      );
      expect(
        () => host.acceptRequest('POST', '/v2/offer', proof),
        throwsA(isA<NearbyException>()),
      );
    },
  );

  test('response authenticates status body and request correlation', () async {
    final (guest, host) = await sessions();
    final proof = guest.signRequest('POST', '/v2/offer', [1]);
    final other = guest.signRequest('POST', '/v2/offer', [1]);
    final mac = host.signResponse(proof, 'POST', '/v2/offer', 200, [2]);
    guest.verifyResponse(proof, 'POST', '/v2/offer', 200, [2], mac);
    for (final status in [201, 403]) {
      expect(
        () =>
            guest.verifyResponse(proof, 'POST', '/v2/offer', status, [2], mac),
        throwsA(isA<NearbyException>()),
      );
    }
    expect(
      () => guest.verifyResponse(proof, 'POST', '/v2/offer', 200, [3], mac),
      throwsA(isA<NearbyException>()),
    );
    expect(
      () => guest.verifyResponse(other, 'POST', '/v2/offer', 200, [2], mac),
      throwsA(isA<NearbyException>()),
    );
  });
}
