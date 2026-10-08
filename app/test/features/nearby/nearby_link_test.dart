import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_codec.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_pairing.dart';

class _FakeDiscovery implements NearbyDiscovery {
  final _ctrl = StreamController<List<NearbyPeer>>.broadcast();
  var started = false;
  int advertisedPort = 0;

  @override
  Stream<List<NearbyPeer>> get peers => _ctrl.stream;

  void setPeers(List<NearbyPeer> next) => _ctrl.add(next);

  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    started = true;
    advertisedPort = port;
  }

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    advertisedPort = port;
  }

  @override
  Future<void> stop() async {
    started = false;
  }
}

void main() {
  test('loopback pair, accept, and one-way shop copy', () async {
    final hostDisco = _FakeDiscovery();
    final guestDisco = _FakeDiscovery();
    BackupPayload? received;

    final payload = BackupPayload(
      createdAt: DateTime.utc(2026, 9, 16, 19),
      sourceDeviceId: 'guest-device',
      sqliteBytes: Uint8List.fromList([10, 20, 30, 40]),
      photos: const {},
    );
    final offer = NearbyOffer(
      sourceDeviceId: 'guest-device',
      sourceName: 'Shop Windows',
      jobs: 1,
      parts: 3,
      photos: 0,
      bytes: 4,
    );

    final host = NearbyController(
      deviceId: 'host-device',
      deviceName: 'Shop Mac',
      discovery: hostDisco,
      bindAddress: InternetAddress.loopbackIPv4,
      localIps: () async => ['127.0.0.1'],
      collectPayload: () async => (payload: payload, offer: offer),
      applyPayload: (p) async => received = p,
    );
    final guest = NearbyController(
      deviceId: 'guest-device',
      deviceName: 'Shop Windows',
      discovery: guestDisco,
      bindAddress: InternetAddress.loopbackIPv4,
      localIps: () async => ['127.0.0.1'],
      collectPayload: () async => (payload: payload, offer: offer),
      applyPayload: (_) async {},
    );
    addTearDown(host.dispose);
    addTearDown(guest.dispose);

    await host.start();
    await guest.start();
    expect(hostDisco.advertisedPort, greaterThan(0));

    final hostPeer = NearbyPeer(
      deviceId: 'host-device',
      name: 'Shop Mac',
      host: '127.0.0.1',
      port: hostDisco.advertisedPort,
    );
    guestDisco.setPeers([hostPeer]);

    final hostOffering = Completer<void>();
    host.states.listen((s) {
      if (s.phase == NearbyPhase.offering && !hostOffering.isCompleted) {
        hostOffering.complete();
      }
    });

    await guest.pair(hostPeer);
    await pumpEventQueue();
    expect(guest.state.verifyCode, isNotNull);
    expect(host.state.verifyCode, guest.state.verifyCode);

    await host.confirmCode();
    expect(host.state.phase, NearbyPhase.pairing);
    expect(guest.state.phase, NearbyPhase.pairing);
    expect(received, isNull);
    await guest.confirmCode();
    expect(guest.state.phase, NearbyPhase.paired);
    expect(host.state.phase, NearbyPhase.paired);

    guestDisco.setPeers([hostPeer]);
    await pumpEventQueue();
    expect(guest.state.phase, NearbyPhase.paired);

    final sending = guest.sendTo(hostPeer);
    await hostOffering.future.timeout(const Duration(seconds: 5));
    await host.acceptOffer();
    await sending.timeout(const Duration(seconds: 10));

    expect(guest.state.phase, NearbyPhase.success);
    expect(host.state.phase, NearbyPhase.success);
    expect(received, isNotNull);
    expect(received!.sourceDeviceId, 'guest-device');
    expect(received!.sqliteBytes, [10, 20, 30, 40]);
    expect(host.state.successMessage, contains('Shop Windows'));
    expect(guest.state.successMessage, contains('Shop Mac'));
  });

  for (final revokePath in [
    '/v2/pair/cancel',
    '/v2/pair/start',
    'tampered-transfer',
  ]) {
    test('each transfer requires consent and revokes on $revokePath', () async {
      final discovery = _FakeDiscovery();
      var applied = 0;
      final receiver = NearbyController(
        deviceId: 'receiver',
        deviceName: 'Receiver',
        discovery: discovery,
        bindAddress: InternetAddress.loopbackIPv4,
        localIps: () async => ['127.0.0.1'],
        collectPayload: () async => throw StateError('no send'),
        applyPayload: (_) async => applied++,
      );
      addTearDown(receiver.dispose);
      await receiver.start();
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() => client.close(force: true));
      NearbySessionKeys? keys;
      Future<HttpClientRequest> open(
        String path,
        List<int> data, {
        String method = 'POST',
        bool authenticated = true,
      }) async {
        final req = await client.open(
          method,
          '127.0.0.1',
          discovery.advertisedPort,
          path,
        );
        final session = keys;
        if (authenticated && session != null) {
          final proof = session.signRequest(method, path, data);
          req.headers.set('x-nearby-session', session.id);
          req.headers.set('x-nearby-sequence', proof.sequence);
          req.headers.set('x-nearby-digest', proof.digest);
          req.headers.set('x-nearby-mac', proof.mac);
        }
        req.bufferOutput = false;
        req.contentLength = data.length;
        return req;
      }

      Future<({int status, Map<String, dynamic> body})> request(
        String path, {
        Map<String, Object?>? json,
        List<int>? bytes,
        bool authenticated = true,
      }) async {
        final data = bytes ?? utf8.encode(jsonEncode(json));
        final req = await open(
          path,
          data,
          method: bytes == null ? 'POST' : 'PUT',
          authenticated: authenticated,
        );
        req.add(data);
        final response = await req.close();
        return (
          status: response.statusCode,
          body: jsonDecode(
            await utf8.decoder.bind(response).join(),
          ) as Map<String, dynamic>,
        );
      }

      Future<NearbyPendingPair> startPair() async {
        final context = NearbyPairContext(
          id: nearbyRandomId(),
          guestId: 'sender',
          hostId: 'receiver',
          guestName: 'Sender',
          hostName: 'Receiver',
          guestPort: 12345,
          hostPort: discovery.advertisedPort,
        );
        final agreement = await NearbyPendingPair.create(context, guest: true);
        final response = await request(
          '/v2/pair/start',
          authenticated: false,
          json: {...context.toJson(), 'commitment': agreement.commitment},
        );
        expect(response.status, HttpStatus.ok);
        expect(response.body.keys, ['commitment']);
        agreement.receiveCommitment(response.body['commitment']);
        return agreement;
      }

      final agreement = await startPair();
      final reveal = await request(
        '/v2/pair/reveal',
        authenticated: false,
        json: agreement.reveal(),
      );
      final match = await agreement.receiveReveal(reveal.body);
      expect(receiver.state.verifyCode, match.code);
      await receiver.confirmCode();
      final confirmation = await request(
        '/v2/pair/confirm',
        authenticated: false,
        json: {'id': agreement.context.id, 'proof': match.confirmLocal()},
      );
      expect(confirmation.body.keys, ['proof']);
      match.confirmRemote(confirmation.body['proof']);
      keys = match.finish();
      final session = keys;
      final transferId = nearbyRandomId();
      final offer = NearbyOffer(
        sourceDeviceId: 'sender',
        sourceName: 'Sender',
        jobs: 1,
        parts: 2,
        photos: 0,
        bytes: 3,
      );
      final bytes = await NearbyCodec().encrypt(
        payload: BackupPayload(
          createdAt: DateTime.utc(2026, 9, 21),
          sourceDeviceId: 'sender',
          sqliteBytes: Uint8List.fromList([1, 2, 3]),
          photos: const {},
        ),
        key: session.sendKey,
        sessionId: session.id,
        direction: session.sendDirection,
        transferId: transferId,
        offer: offer,
      );
      final offerJson = <String, Object?>{
        'sourceDeviceId': 'sender',
        'sourceName': 'Sender',
        'jobs': 1,
        'parts': 2,
        'photos': 0,
        'bytes': bytes.length,
        'transferId': transferId,
        'digest': nearbyDigest(bytes),
      };
      Future<({int status, Map<String, dynamic> body})> transfer() =>
          request('/v2/transfer', bytes: bytes);
      Future<({int status, Map<String, dynamic> body})> sendOffer() =>
          request('/v2/offer', json: offerJson);
      expect(
        (await request('/v1/pair/start', json: {})).status,
        HttpStatus.notFound,
      );
      final replayProof = session.signRequest('PUT', '/v2/transfer', bytes);
      Future<int> replay() async {
        final req = await client.put(
          '127.0.0.1',
          discovery.advertisedPort,
          '/v2/transfer',
        );
        req.headers.set('x-nearby-session', session.id);
        req.headers.set('x-nearby-sequence', replayProof.sequence);
        req.headers.set('x-nearby-digest', replayProof.digest);
        req.headers.set('x-nearby-mac', replayProof.mac);
        req.add(bytes);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      expect(await replay(), HttpStatus.forbidden);
      expect(await replay(), HttpStatus.unauthorized);
      expect(applied, 0);
      var offered = receiver.states.firstWhere(
        (s) => s.phase == NearbyPhase.offering,
      );
      var decision = sendOffer();
      await offered;
      expect((await transfer()).status, HttpStatus.forbidden);
      await receiver.declineOffer();
      expect((await decision).status, HttpStatus.forbidden);
      expect((await transfer()).status, HttpStatus.forbidden);
      expect(applied, 0);

      final delayedBody = utf8.encode(jsonEncode(offerJson));
      final delayedOffer = await open('/v2/offer', delayedBody);
      delayedOffer.add(delayedBody.sublist(0, 1));
      await delayedOffer.flush();
      await pumpEventQueue();
      offered = receiver.states.firstWhere(
        (s) => s.phase == NearbyPhase.offering,
      );
      decision = sendOffer();
      await offered;
      await receiver.acceptOffer();
      expect((await decision).status, HttpStatus.ok);
      delayedOffer.add(delayedBody.sublist(1));
      final delayedResponse = await delayedOffer.close().timeout(
        const Duration(seconds: 5),
      );
      expect(delayedResponse.statusCode, HttpStatus.conflict);
      await delayedResponse.drain<void>();
      expect(receiver.state.phase, NearbyPhase.transferring);
      expect((await transfer()).status, HttpStatus.ok);
      expect(applied, 1);
      expect((await transfer()).status, HttpStatus.forbidden);
      expect(applied, 1);

      offered = receiver.states.firstWhere(
        (s) => s.phase == NearbyPhase.offering,
      );
      decision = sendOffer();
      await offered;
      await receiver.acceptOffer();
      expect((await decision).status, HttpStatus.ok);
      if (revokePath == 'tampered-transfer') {
        final changed = Uint8List.fromList(bytes);
        changed[changed.length - 1] ^= 1;
        expect(
          (await request('/v2/transfer', bytes: changed)).status,
          HttpStatus.badRequest,
        );
        expect(applied, 1);
        return;
      }
      final delayedTransfer = await open('/v2/transfer', bytes, method: 'PUT');
      final receiving = receiver.states.firstWhere(
        (s) => s.progress != null && s.progress! > 0 && s.progress! < 1,
      );
      delayedTransfer.add(bytes.sublist(0, 1));
      await delayedTransfer.flush();
      await receiving.timeout(const Duration(seconds: 5));
      if (revokePath.endsWith('start')) {
        await startPair();
      } else {
        expect((await request(revokePath, json: {})).status, HttpStatus.ok);
      }
      delayedTransfer.add(bytes.sublist(1));
      final revokedResponse = await delayedTransfer.close().timeout(
        const Duration(seconds: 5),
      );
      await revokedResponse.drain<void>();
      expect(applied, 1);
      expect(revokedResponse.statusCode, HttpStatus.forbidden);
    });
  }

  test('codes-dont-match cancels without copying', () async {
    final hostDisco = _FakeDiscovery();
    final guestDisco = _FakeDiscovery();
    var applied = false;
    final host = NearbyController(
      deviceId: 'host-device',
      deviceName: 'Shop Mac',
      discovery: hostDisco,
      bindAddress: InternetAddress.loopbackIPv4,
      localIps: () async => ['127.0.0.1'],
      collectPayload: () async => throw StateError('no send'),
      applyPayload: (_) async => applied = true,
    );
    final guest = NearbyController(
      deviceId: 'guest-device',
      deviceName: 'Shop Windows',
      discovery: guestDisco,
      bindAddress: InternetAddress.loopbackIPv4,
      localIps: () async => ['127.0.0.1'],
      collectPayload: () async => throw StateError('no send'),
      applyPayload: (_) async {},
    );
    addTearDown(host.dispose);
    addTearDown(guest.dispose);

    await host.start();
    await guest.start();
    final hostPeer = NearbyPeer(
      deviceId: 'host-device',
      name: 'Shop Mac',
      host: '127.0.0.1',
      port: hostDisco.advertisedPort,
    );
    await guest.pair(hostPeer);
    await pumpEventQueue();
    await host.rejectCode();
    await guest.confirmCode();
    expect(applied, isFalse);
    expect(guest.state.phase, NearbyPhase.looking);
    expect(guest.state.error, isNotNull);
  });
}

Future<void> pumpEventQueue() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 20));
}
