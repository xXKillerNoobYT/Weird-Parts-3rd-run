import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';

import '../../tool/company_user_network_diagnostic.dart';
import '../features/company/company_join_test.dart' show JoinTestDiscovery;
import '../features/company/company_join_widget_test.dart'
    show JoinLoopbackHttpOverrides;

const _channel = MethodChannel('wired_parts/nearby_wifi');

NearbyTransportObservation event({
  NearbyTransportOperation operation = NearbyTransportOperation.join,
  NearbyTransportStage stage = NearbyTransportStage.tcpStart,
  NearbyTransportFailure? failure,
  int generation = 1,
  String peer = '192.168.10.40',
  String source = '192.168.10.20',
  int port = 6809,
  int index = 7,
  int prefix = 24,
}) => NearbyTransportObservation(
  request: operation == NearbyTransportOperation.room ? 0 : 3,
  controller: 2,
  generation: generation,
  operation: operation,
  stage: stage,
  failure: failure,
  osError: failure == null ? null : 65,
  elapsedMicros: 20,
  peerAddress: peer,
  peerPort: port,
  factoryAddress: peer,
  factoryPort: port,
  sourceAddress: source,
  sourceInterfaceIndex: index,
  sourcePrefixLength: prefix,
);

void room(CompanyUserNetworkDiagnostic diagnostic, {int generation = 1}) =>
    diagnostic.observe(
      event(
        operation: NearbyTransportOperation.room,
        stage: NearbyTransportStage.listenerBound,
        generation: generation,
      ),
    );

Future<void> settle() => Future<void>.delayed(Duration.zero);

Map<String, Object?> reply(Map args, {String outcome = 'timedOut'}) => {
  'attempt': args['attempt'],
  'controller': args['controller'],
  'generation': args['generation'],
  'request': args['request'],
  'outcome': outcome,
  'events': [
    {
      'state': 'waiting',
      'path': 'unsatisfied',
      'reason': 'localNetworkDenied',
      'domain': 'posix',
      'code': 65,
      'elapsedMs': 2,
      'observedUtc': '2026-10-25T06:00:00.000Z',
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late List<Map<String, Object?>> records;

  setUp(() {
    calls = [];
    records = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'diagnoseLocalTcp'
          ? reply(call.arguments as Map)
          : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  CompanyUserNetworkDiagnostic make({bool enabled = true}) =>
      CompanyUserNetworkDiagnostic(
        enabled: enabled,
        run: 'g2-users-20261024-pin-a',
        record: records.add,
      );

  test(
    'native diagnosis preserves the actual connector failure and room state',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final errors = <String?>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'diagnoseLocalTcp') {
          throw PlatformException(code: 'private-native-marker');
        }
        return null;
      });
      for (final enabled in [false, true]) {
        final output = <Map<String, Object?>>[];
        final diagnostic = CompanyUserNetworkDiagnostic(
          enabled: enabled,
          run: 'g2-users-20261024-pin-a',
          record: output.add,
        );
        final discovery = JoinTestDiscovery();
        final events = <NearbyTransportObservation>[];
        final controller = NearbyController(
          deviceId: 'guest',
          deviceName: 'Guest',
          discovery: discovery,
          companyJoin: true,
          readNetwork: () async => _RefusingNetwork(),
          onTransportObservation: (event) {
            events.add(event);
            diagnostic.observe(event);
          },
        );
        try {
          await controller.start();
          await controller.pair(
            const NearbyPeer(
              deviceId: 'host',
              name: 'Host',
              host: '192.168.10.40',
              port: 6809,
            ),
          );
          await settle();
          errors.add(controller.state.error);
          expect(controller.state.phase, NearbyPhase.failed);
          expect(controller.pairedJoinSession, isNull);
          final failure = events.lastWhere((event) => event.failure != null);
          expect(failure.stage, NearbyTransportStage.tcpStart);
          expect(failure.failure, NearbyTransportFailure.socket);
          expect(failure.osError, 65);
          expect(jsonEncode(output), isNot(contains('private-')));
          expect(output.isNotEmpty, enabled);
        } finally {
          await diagnostic.close();
          await controller.dispose();
          await discovery.controller.close();
        }
      }
      expect(errors.first, contains('private-socket-marker'));
      expect(errors.last, errors.first);
      expect(
        calls.where((call) => call.method == 'diagnoseLocalTcp'),
        hasLength(1),
      );
    }, JoinLoopbackHttpOverrides()),
  );

  test('observed TCP failure starts one bounded diagnostic with redacted typed output', () async {
    final diagnostic = make();
    room(diagnostic);
    diagnostic.observe(event());
    diagnostic.observe(event(failure: NearbyTransportFailure.socket));
    await settle();
    expect(calls.map((call) => call.method), ['diagnoseLocalTcp']);
    final args = calls.single.arguments as Map;
    expect(args['address'], '192.168.10.40');
    expect(args['sourceAddress'], '192.168.10.20');
    expect(args['interfaceIndex'], 7);
    expect(args['generation'], 1);
    expect(records.last['outcome'], 'timedOut');
    expect(records.first['reason'], 'localNetworkDenied');
    expect(
      records.every(
        (row) => DateTime.tryParse(row['observedUtc'] as String)?.isUtc == true,
      ),
      isTrue,
    );
    final text = jsonEncode(records);
    expect(text, isNot(contains('192.168.')));
    expect(text, isNot(contains('address')));
    diagnostic.observe(event(failure: NearbyTransportFailure.socket));
    room(diagnostic, generation: 2);
    diagnostic.observe(event(generation: 2));
    diagnostic.observe(
      event(generation: 2, failure: NearbyTransportFailure.socket),
    );
    await settle();
    expect(calls, hasLength(1));
    await diagnostic.close();
  });

  test(
    'disabled, unobserved, stale, and unsafe target failures never call native',
    () async {
      final disabled = make(enabled: false);
      room(disabled);
      disabled.observe(event());
      disabled.observe(event(failure: NearbyTransportFailure.socket));
      final diagnostic = make();
      diagnostic.observe(event());
      diagnostic.observe(event(failure: NearbyTransportFailure.socket));
      room(diagnostic, generation: 2);
      diagnostic.observe(event());
      diagnostic.observe(event(failure: NearbyTransportFailure.socket));
      for (final bad in [
        event(generation: 2, peer: 'example.invalid'),
        event(generation: 2, peer: '192.168.11.40'),
        event(generation: 2, peer: '192.168.10.20'),
        event(generation: 2, peer: '192.168.10.0'),
        event(generation: 2, peer: '192.168.10.255'),
        event(generation: 2, source: '8.8.8.8'),
        event(generation: 2, port: 0),
        event(generation: 2, index: 0),
        event(generation: 2, prefix: 31),
      ]) {
        diagnostic.observe(bad);
        diagnostic.observe(
          NearbyTransportObservation(
            request: bad.request,
            controller: bad.controller,
            generation: bad.generation,
            operation: bad.operation,
            stage: bad.stage,
            elapsedMicros: 30,
            peerAddress: bad.peerAddress,
            peerPort: bad.peerPort,
            factoryAddress: bad.factoryAddress,
            factoryPort: bad.factoryPort,
            sourceAddress: bad.sourceAddress,
            sourceInterfaceIndex: bad.sourceInterfaceIndex,
            sourcePrefixLength: bad.sourcePrefixLength,
            failure: NearbyTransportFailure.socket,
          ),
        );
      }
      await settle();
      expect(calls, isEmpty);
      await diagnostic.close();
      await disabled.close();
    },
  );

  for (final stop in ['room', 'close', 'controller']) {
    test(
      '$stop cancellation reaches native and ignores late completion',
      () async {
        final pending = Completer<Object?>();
        messenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return call.method == 'diagnoseLocalTcp' ? pending.future : null;
        });
        final diagnostic = make();
        room(diagnostic);
        diagnostic.observe(event());
        diagnostic.observe(event(failure: NearbyTransportFailure.socket));
        await settle();
        final args = calls.single.arguments as Map;
        switch (stop) {
          case 'room':
            diagnostic.observe(
              event(
                operation: NearbyTransportOperation.room,
                stage: NearbyTransportStage.stopping,
              ),
            );
          case 'controller':
            await diagnostic.cancelController(2);
          case 'close':
            await diagnostic.close();
        }
        await settle();
        expect(calls.map((call) => call.method), [
          'diagnoseLocalTcp',
          'cancelLocalTcpDiagnostic',
        ]);
        expect((calls.last.arguments as Map)['attempt'], args['attempt']);
        pending.complete(reply(args, outcome: 'ready'));
        await settle();
        expect(records, isEmpty);
        await diagnostic.close();
      },
    );
  }

  test('new generation cancels old attempt and hostile native output is not exported', () async {
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'diagnoseLocalTcp' ? pending.future : null;
    });
    final diagnostic = make();
    room(diagnostic);
    diagnostic.observe(event());
    diagnostic.observe(event(failure: NearbyTransportFailure.socket));
    await settle();
    room(diagnostic, generation: 2);
    pending.complete({'secret': 'private-canary'});
    await settle();
    expect(calls.last.method, 'cancelLocalTcpDiagnostic');
    expect(records, isEmpty);
    await diagnostic.close();
  });

  test('native failure and invalid response remain diagnostic-only and redact strings', () async {
    for (final badReply in [
      null,
      {'secret': 'private-canary'},
    ]) {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (badReply == null) {
          throw PlatformException(
            code: 'private-canary',
            message: 'private-canary',
          );
        }
        return badReply;
      });
      final diagnostic = make();
      room(diagnostic);
      diagnostic.observe(event());
      diagnostic.observe(event(failure: NearbyTransportFailure.socket));
      await settle();
      await diagnostic.close();
    }
    expect(records.map((row) => row['outcome']), [
      'unavailable',
      'invalidResponse',
    ]);
    expect(jsonEncode(records), isNot(contains('private-canary')));
  });
  test(
    'native response bounds and context reject malformed records before export',
    () async {
      final corruptions = <Map<String, Object?> Function(Map<String, Object?>)>[
        (value) => {...value, 'generation': 99},
        (value) => {
          ...value,
          'events': List.filled(9, (value['events'] as List).single),
        },
        (value) {
          final item = Map<String, Object?>.from(
            (value['events'] as List).single as Map,
          )..remove('code');
          return {
            ...value,
            'events': [
              {...item, 'secret': 'private-canary'},
            ],
          };
        },
        (value) => {...value, 'secret': 'private-canary'},
      ];
      for (final corrupt in corruptions) {
        messenger.setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'diagnoseLocalTcp') {
            return corrupt(reply(call.arguments as Map));
          }
          return null;
        });
        final diagnostic = make();
        room(diagnostic);
        diagnostic.observe(event());
        diagnostic.observe(event(failure: NearbyTransportFailure.socket));
        await settle();
        await diagnostic.close();
      }
      expect(
        records.map((row) => row['outcome']),
        List.filled(4, 'invalidResponse'),
      );
      expect(jsonEncode(records), isNot(contains('private-canary')));
    },
  );
}

final class _RefusingNetwork extends NearbyWifiNetwork {
  _RefusingNetwork()
    : super(name: 'test', index: 7, address: '192.168.10.20', prefixLength: 24);
  @override
  Future<HttpServer> listen({
    FutureOr<void> Function(String, int)? onListenerBound,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    await onListenerBound?.call(address, server.port);
    return server;
  }

  @override
  Future<ConnectionTask<Socket>> connect(
    Uri uri, {
    FutureOr<void> Function(NearbyTransportStage)? onStage,
  }) async {
    await onStage?.call(NearbyTransportStage.tcpStart);
    throw const SocketException(
      'private-socket-marker',
      osError: OSError('private-os-marker', 65),
    );
  }
}
