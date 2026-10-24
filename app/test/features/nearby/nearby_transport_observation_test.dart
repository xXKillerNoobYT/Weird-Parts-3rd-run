import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';

import '../company/company_join_test.dart' show JoinTestDiscovery;
import '../../../tool/company_users_native_validation.dart';

CompanyUserTransportReceipts receipts(
  Directory directory, {
  String suffix = 'a',
}) => CompanyUserTransportReceipts(
  directory: directory,
  run: 'g2-users-20261024-diagnostic-$suffix',
  role: 'receiver',
  sourceRevision: 'a' * 40,
  sourceTree: 'b' * 40,
  processId: 123,
);

const observation = NearbyTransportObservation(
  request: 1,
  operation: NearbyTransportOperation.join,
  stage: NearbyTransportStage.tcpStart,
  elapsedMicros: 31,
  peerAddress: '192.168.10.40',
  peerPort: 6809,
  sourceInterfaceIndex: 7,
  sourceAddress: '192.168.10.20',
  sourcePrefixLength: 24,
  factoryAddress: '192.168.10.40',
  factoryPort: 6809,
  failure: NearbyTransportFailure.socket,
  osError: 65,
);

void main() {
  test('separate room controllers keep distinct attribution when generation restarts', () async {
    final events = <NearbyTransportObservation>[];
    final discoveries = [JoinTestDiscovery(), JoinTestDiscovery()];
    final controllers = [
      for (var index = 0; index < 2; index++)
        NearbyController(
          deviceId: 'room-$index',
          deviceName: 'Room',
          discovery: discoveries[index],
          companyJoin: true,
          bindAddress: InternetAddress.loopbackIPv4,
          localIps: () async => ['127.0.0.1'],
          onTransportObservation: events.add,
        ),
    ];
    try {
      for (final controller in controllers) {
        await controller.start();
      }
      final bound = events
          .where((event) => event.stage == NearbyTransportStage.listenerBound)
          .toList();
      expect(bound, hasLength(2));
      expect(bound.every((event) => event.generation == 1), isTrue);
      expect(bound.map((event) => event.controller).toSet(), hasLength(2));
      await controllers.first.stop();
      expect(controllers.last.state.phase, NearbyPhase.looking);
      final stopped = events.lastWhere(
        (event) => event.stage == NearbyTransportStage.stopped,
      );
      expect(stopped.controller, bound.first.controller);
      expect(stopped.listenerPort, bound.first.listenerPort);
    } finally {
      for (final controller in controllers) {
        await controller.dispose();
      }
      for (final discovery in discoveries) {
        await discovery.controller.close();
      }
    }
  });
  test('largest room projection fits unchanged receipt cap', () async {
    final directory = Directory.systemTemp.createTempSync(
      'room-transport-bounds-',
    );
    final writer = CompanyUserTransportReceipts(
      directory: directory,
      run: 'g2-users-20261024-${'a' * 30}',
      role: 'receiver',
      sourceRevision: 'a' * 40,
      sourceTree: 'b' * 40,
      processId: 2147483647,
    );
    try {
      writer.record(
        const NearbyTransportObservation(
          request: 9223372036854775807,
          generation: 9223372036854775807,
          controller: 9223372036854775807,
          operation: NearbyTransportOperation.room,
          stage: NearbyTransportStage.responseAuthentication,
          elapsedMicros: 9223372036854775807,
          peerAddress: '255.255.255.255',
          peerPort: 65535,
          sourceInterfaceIndex: 2147483647,
          sourceAddress: '255.255.255.255',
          sourcePrefixLength: 30,
          httpStatus: 599,
          failure: NearbyTransportFailure.operatingSystem,
          osError: -2147483648,
          factoryAddress: '255.255.255.255',
          factoryPort: 65535,
          listenerAddress: '255.255.255.255',
          listenerPort: 65535,
          stopReason: NearbyTransportStopReason.startupFailure,
        ),
      );
      await writer.drain();
      expect(writer.capturedCount, 1);
      final file = File(writer.filePath);
      expect(await file.length(), lessThanOrEqualTo(1024));
      final row = jsonDecode((await file.readAsLines()).single) as Map;
      expect(row['listenerPort'], 65535);
      expect(row['generation'], 9223372036854775807);
      expect(row['stopReason'], 'startupFailure');
    } finally {
      await writer.close();
      directory.deleteSync(recursive: true);
    }
  });
  test('actual HTTP connection factory destination is measured before connector refusal', () async {
    final network = _RefusingNetwork();
    final discovery = JoinTestDiscovery();
    final events = <NearbyTransportObservation>[];
    final controller = NearbyController(
      deviceId: 'guest',
      deviceName: 'Guest',
      discovery: discovery,
      companyJoin: true,
      readNetwork: () async => network,
      onTransportObservation: events.add,
    );
    addTearDown(controller.dispose);
    addTearDown(discovery.controller.close);
    await controller.start();
    await controller.pair(
      const NearbyPeer(
        deviceId: 'host',
        name: 'Host',
        host: '192.168.10.40',
        port: 6809,
      ),
    );
    expect(network.target?.host, '192.168.10.40');
    expect(network.target?.port, 6809);
    final target = events.singleWhere(
      (event) =>
          event.stage == NearbyTransportStage.factoryTarget &&
          event.failure == null,
    );
    expect(target.factoryAddress, network.target!.host);
    expect(target.factoryPort, network.target!.port);
    expect(target.sourceInterfaceIndex, 7);
    expect(target.sourceAddress, '192.168.10.20');
    expect(events.last.stage, NearbyTransportStage.factoryTarget);
    expect(events.last.failure, NearbyTransportFailure.socket);
    expect(events.last.osError, 65);
    expect(
      jsonEncode(events.map((event) => event.toJson()).toList()),
      isNot(contains('private-')),
    );
  });
  for (final mode in ['record', 'throw', 'asyncThrow', 'off']) {
    test(
      'ordinary Pair and authenticated Join preserve behavior with observer $mode',
      () async {
        final events = <NearbyTransportObservation>[];
        final hostDiscovery = JoinTestDiscovery();
        final guestDiscovery = JoinTestDiscovery();
        final host = NearbyController(
          deviceId: 'host',
          deviceName: 'Host',
          discovery: hostDiscovery,
          companyJoin: true,
          bindAddress: InternetAddress.loopbackIPv4,
          localIps: () async => ['127.0.0.1'],
        );
        final guest = NearbyController(
          deviceId: 'guest',
          deviceName: 'Guest',
          discovery: guestDiscovery,
          companyJoin: true,
          bindAddress: InternetAddress.loopbackIPv4,
          localIps: () async => ['127.0.0.1'],
          onTransportObservation: mode == 'off'
              ? null
              : mode == 'asyncThrow'
              ? (event) async {
                  events.add(event);
                  await Future<void>.delayed(Duration.zero);
                  throw StateError('private-async-observer-marker');
                }
              : (event) {
                  events.add(event);
                  if (mode == 'throw') {
                    throw StateError('private-observer-marker');
                  }
                },
        );
        addTearDown(host.dispose);
        addTearDown(guest.dispose);
        addTearDown(hostDiscovery.controller.close);
        addTearDown(guestDiscovery.controller.close);
        var admitted = 0;
        host.onJoinMessage = (_, wire) async {
          admitted++;
          return {'ok': true};
        };
        await host.start();
        await guest.start();
        events.clear();
        await expectLater(
          guest.sendJoinMessage({'kind': 'request'}),
          throwsA(isA<NearbyException>()),
        );
        expect(events, isEmpty);
        await guest.pair(
          NearbyPeer(
            deviceId: 'host',
            name: 'Host',
            host: '127.0.0.1',
            port: hostDiscovery.port,
          ),
        );
        expect(guest.state.verifyCode, host.state.verifyCode);
        expect(guest.state.verifyCode, isNotNull);
        await host.confirmCode();
        await guest.confirmCode();
        await guest.sendJoinMessage({
          'kind': 'request',
          'body': 'private-body-marker',
          'credential': 'private-credential-marker',
        });
        expect(admitted, 1);
        final count = events.length;
        await expectLater(
          guest.exchangeCompanyMessage({'kind': 'created-jobs'}),
          throwsA(isA<NearbyException>()),
        );
        expect(admitted, 1);
        expect(events, hasLength(count));
        if (mode == 'off') {
          expect(guest.onTransportObservation, isNull);
          expect(events, isEmpty);
        } else {
          expect(
            events.map((event) => event.operation),
            containsAll([
              NearbyTransportOperation.pairStart,
              NearbyTransportOperation.pairReveal,
              NearbyTransportOperation.pairConfirm,
              NearbyTransportOperation.join,
            ]),
          );
          final join = events
              .where(
                (event) => event.operation == NearbyTransportOperation.join,
              )
              .toList();
          expect(
            join.map((event) => event.stage),
            containsAllInOrder([
              NearbyTransportStage.selected,
              NearbyTransportStage.httpOpened,
              NearbyTransportStage.httpResponse,
              NearbyTransportStage.responseAuthentication,
              NearbyTransportStage.responseVerified,
            ]),
          );
          expect(
            join.every(
              (event) =>
                  event.peerAddress == '127.0.0.1' &&
                  event.peerPort == hostDiscovery.port,
            ),
            isTrue,
          );
          expect(join.every((event) => event.failure == null), isTrue);
          final encoded = jsonEncode(
            events.map((event) => event.toJson()).toList(),
          );
          expect(encoded, isNot(contains('private-')));
          expect(encoded, isNot(contains('ciphertext')));
          expect(encoded, isNot(contains('x-nearby')));
        }
      },
    );
  }

  test(
    'socket refusal retains categorical failure and fixed controller event cap',
    () async {
      final discovery = JoinTestDiscovery();
      final events = <NearbyTransportObservation>[];
      var allow = true;
      final controller = NearbyController(
        deviceId: 'guest',
        deviceName: 'Guest',
        discovery: discovery,
        companyJoin: true,
        peerAllowed: (_) => allow,
        bindAddress: InternetAddress.loopbackIPv4,
        localIps: () async => ['127.0.0.1'],
        onTransportObservation: (event) {
          events.add(event);
          throw StateError('private-observer-marker');
        },
      );
      addTearDown(controller.dispose);
      addTearDown(discovery.controller.close);
      await controller.start();
      final unavailable = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = unavailable.port;
      await unavailable.close();
      final peer = NearbyPeer(
        deviceId: 'absent',
        name: 'Absent',
        host: '127.0.0.1',
        port: port,
      );
      await controller.pair(peer);
      expect(controller.state.verifyCode, isNull);
      expect(events.last.failure, NearbyTransportFailure.socket);
      expect(events.last.osError, isNotNull);
      expect(events.last.peerPort, port);
      expect(jsonEncode(events.last.toJson()), isNot(contains('private-')));
      allow = false;
      for (var index = 0; index < 80; index++) {
        await controller.pair(peer);
      }
      expect(events, hasLength(kNearbyTransportObservationLimit));
    },
  );

  test('native controller factory preserves ordinary defaults without creating a receipt', () async {
    final directory = Directory.systemTemp.createTempSync(
      'passive-transport-defaults-',
    );
    final writer = receipts(directory);
    final controller = writer.createController(
      '12345678-1234-4234-8234-123456789012',
    );
    try {
      expect(controller.deviceId, '12345678-1234-4234-8234-123456789012');
      expect(controller.deviceName, 'Nearby 123456');
      expect(controller.discovery, isA<LanNearbyDiscovery>());
      expect(controller.companyJoin, isTrue);
      expect(controller.bindAddress, isNull);
      expect(controller.localIps, isNull);
      expect(controller.codec, isNull);
      expect(controller.peerAllowed, isNull);
      expect(controller.now, isNull);
      expect(controller.readNetwork, same(readNearbyWifiNetwork));
      expect(controller.onJoinMessage, isNull);
      expect(controller.companySyncDisclosure, isNull);
      expect(directory.listSync(), isEmpty);
    } finally {
      await controller.dispose();
      await writer.close();
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'local receipt capture is lazy async bounded and isolated by launch',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'passive-transport-',
      );
      final writer = receipts(directory);
      final other = receipts(directory, suffix: 'b');
      try {
        expect(directory.listSync(), isEmpty);
        for (var index = 0; index < 500; index++) {
          writer.record(observation);
        }
        expect(
          directory.listSync(),
          isEmpty,
          reason: 'capture does not synchronously write',
        );
        other.record(observation);
        await writer.drain();
        await other.drain();
        expect(writer.capturedCount, 128);
        final file = File(writer.filePath);
        final lines = await file.readAsLines();
        expect(lines, hasLength(128));
        expect(
          await file.length(),
          lessThanOrEqualTo(CompanyUserTransportReceipts.maxTotalBytes),
        );
        for (final line in lines) {
          expect(utf8.encode('$line\n').length, lessThanOrEqualTo(1024));
          final row = jsonDecode(line) as Map;
          expect(row['passed'], isFalse);
          expect(row['localOnly'], isTrue);
          expect(row['run'], 'g2-users-20261024-diagnostic-a');
          expect(row['factoryAddress'], '192.168.10.40');
          expect(row['osError'], 65);
          for (final forbidden in [
            'body',
            'headers',
            'error',
            'stack',
            'uri',
            'credential',
            'session',
          ]) {
            expect(row.containsKey(forbidden), isFalse);
          }
        }
        expect(
          jsonDecode((await File(other.filePath).readAsLines()).single)['run'],
          'g2-users-20261024-diagnostic-b',
        );
        expect(directory.listSync(), hasLength(2));
      } finally {
        await writer.close();
        await other.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('pre-existing receipt is not followed or overwritten and nonnumeric hosts are omitted', () async {
    final directory = Directory.systemTemp.createTempSync(
      'passive-transport-refusal-',
    );
    final writer = receipts(directory);
    try {
      File(writer.filePath).writeAsStringSync('old-evidence-marker');
      writer.record(observation);
      await writer.drain();
      expect(File(writer.filePath).readAsStringSync(), 'old-evidence-marker');
      final encoded = jsonEncode(
        const NearbyTransportObservation(
          request: 1,
          operation: NearbyTransportOperation.join,
          stage: NearbyTransportStage.selected,
          elapsedMicros: 0,
          peerAddress: 'private-host-marker',
          peerPort: 6809,
          sourceAddress: 'private-source-marker',
          factoryAddress: 'private-factory-marker',
          listenerAddress: 'private-listener-marker',
        ).toJson(),
      );
      expect(encoded, isNot(contains('private-')));
    } finally {
      await writer.close();
      directory.deleteSync(recursive: true);
    }
  });
}

final class _RefusingNetwork extends NearbyWifiNetwork {
  _RefusingNetwork()
    : super(name: 'test', index: 7, address: '192.168.10.20', prefixLength: 24);
  Uri? target;
  @override
  Future<HttpServer> listen({
    FutureOr<void> Function(String, int)? onListenerBound,
  }) => HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  @override
  Future<ConnectionTask<Socket>> connect(
    Uri uri, {
    FutureOr<void> Function(NearbyTransportStage stage)? onStage,
  }) async {
    target = uri;
    throw const SocketException(
      'private-socket-marker',
      osError: OSError('private-os-marker', 65),
    );
  }
}
