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

  for (final revokePath in ['/v1/pair/cancel', '/v1/pair/start']) {
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
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<({int status, Map<String, dynamic> body})> request(
        String path, {
        Map<String, Object?>? json,
        List<int>? bytes,
        String? token,
      }) async {
        final req = await client.open(
          bytes == null ? 'POST' : 'PUT',
          '127.0.0.1',
          discovery.advertisedPort,
          path,
        );
        if (token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final data = bytes ?? utf8.encode(jsonEncode(json));
        req.contentLength = data.length;
        req.add(data);
        final res = await req.close();
        final body = jsonDecode(await utf8.decoder.bind(res).join());
        return (status: res.statusCode, body: body as Map<String, dynamic>);
      }

      final pair = await request(
        '/v1/pair/start',
        json: {
          'guestDeviceId': 'sender',
          'guestName': 'Sender',
          'guestNonce': base64Encode(List.filled(16, 1)),
        },
      );
      await receiver.confirmCode();
      final confirmed = await request(
        '/v1/pair/confirm',
        json: {
          'guestDeviceId': 'sender',
          'verifyCode': pair.body['verifyCode'],
        },
      );
      final token = confirmed.body['token'] as String;
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
        token: token,
        offer: offer,
      );
      Future<({int status, Map<String, dynamic> body})> transfer() =>
          request('/v1/transfer', bytes: bytes, token: token);
      Future<({int status, Map<String, dynamic> body})> sendOffer() => request(
        '/v1/offer',
        token: token,
        json: {
          'sourceDeviceId': 'sender',
          'sourceName': 'Sender',
          'jobs': 1,
          'parts': 2,
          'photos': 0,
          'bytes': bytes.length,
        },
      );

      expect((await transfer()).status, HttpStatus.forbidden);
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

      final delayedBody = utf8.encode(
        jsonEncode({
          'sourceDeviceId': 'sender',
          'sourceName': 'Sender',
          'jobs': 1,
          'parts': 2,
          'photos': 0,
          'bytes': bytes.length,
        }),
      );
      final delayedOffer = await client.post(
        '127.0.0.1',
        discovery.advertisedPort,
        '/v1/offer',
      );
      delayedOffer.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $token',
      );
      delayedOffer.bufferOutput = false;
      delayedOffer.contentLength = delayedBody.length;
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
      final delayedTransfer = await client.put(
        '127.0.0.1',
        discovery.advertisedPort,
        '/v1/transfer',
      );
      delayedTransfer.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $token',
      );
      delayedTransfer.bufferOutput = false;
      delayedTransfer.contentLength = bytes.length;
      final receiving = receiver.states.firstWhere(
        (s) => s.progress != null && s.progress! > 0 && s.progress! < 1,
      );
      delayedTransfer.add(bytes.sublist(0, 1));
      await delayedTransfer.flush();
      await receiving.timeout(const Duration(seconds: 5));
      expect(
        (await request(
          revokePath,
          json: {
            'guestDeviceId': 'replacement-sender',
            'guestName': 'Replacement sender',
            'guestNonce': base64Encode(List.filled(16, 2)),
          },
        )).status,
        HttpStatus.ok,
      );
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
    expect(guest.state.phase, NearbyPhase.failed);
    expect(guest.state.error, isNotNull);
  });
}

Future<void> pumpEventQueue() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 20));
}
