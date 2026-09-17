import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
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
