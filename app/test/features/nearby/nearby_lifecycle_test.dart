import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';

class _Discovery implements NearbyDiscovery {
  final starts = <({int port, Completer<void> ready})>[];
  final started = StreamController<void>.broadcast();
  int stops = 0;
  @override
  Stream<List<NearbyPeer>> get peers => const Stream.empty();
  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) {
    final ready = Completer<void>();
    starts.add((port: port, ready: ready));
    started.add(null);
    return ready.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {}
}

NearbyController _controller(
  _Discovery discovery, {
  bool native = false,
  Future<List<String>> Function()? localIps,
  Future<NearbyWifiNetwork> Function()? readNetwork,
}) => NearbyController(
  deviceId: 'test',
  deviceName: 'Test',
  discovery: discovery,
  bindAddress: native ? null : InternetAddress.loopbackIPv4,
  localIps: localIps ?? () async => ['127.0.0.1'],
  readNetwork: readNetwork ?? readNearbyWifiNetwork,
  collectPayload: () async => throw StateError('No payload'),
  applyPayload: (_) async => throw StateError('Must not apply'),
);

class _Interface implements NetworkInterface {
  @override
  String get name => 'test';
  @override
  int get index => 1;
  @override
  List<InterfaceAddress> get addresses => const [];
}

class _Network extends NearbyWifiNetwork {
  _Network({this.interfaceReady})
    : super(name: 'test', index: 1, address: '192.168.1.2', prefixLength: 24);
  final Future<NetworkInterface>? interfaceReady;
  int listens = 0;
  @override
  Future<HttpServer> listen() {
    listens++;
    return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  }

  @override
  Future<NetworkInterface> interface() async => interfaceReady ?? _Interface();
  @override
  void bindDatagram(RawDatagramSocket socket) {}
}

class _Socket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  bool closed = false;
  int sends = 0;
  @override
  bool broadcastEnabled = false;
  @override
  bool multicastLoopback = false;
  @override
  int multicastHops = 1;
  @override
  void close() {
    closed = true;
  }

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (closed) throw StateError('Closed');
    sends++;
    return buffer.length;
  }

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) {}
  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<RawSocketEvent>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Mdns extends MDnsClient {
  final ready = Completer<void>();
  final started = Completer<void>();
  int stops = 0;
  int lookups = 0;
  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) {
    started.complete();
    return ready.future;
  }

  @override
  void stop() {
    stops++;
  }

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    lookups++;
    return const Stream.empty();
  }
}

Future<void> discover(LanNearbyDiscovery discovery) => discovery.start(
  deviceId: 'test',
  name: 'Test',
  port: 1234,
  ips: ['192.168.1.2'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('wired_parts/nearby_wifi');
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final dispose in [false, true]) {
    test(
      'native lookup cannot restart controller after ${dispose ? 'dispose' : 'stop'}',
      () async {
        final nativeReply = Completer<List<Map<String, Object>>>();
        final queried = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (_) {
          queried.complete();
          return nativeReply.future;
        });
        final discovery = _Discovery();
        final network = _Network();
        final nearby = _controller(
          discovery,
          native: true,
          readNetwork: () async {
            await readNearbyWifiNetwork();
            return network;
          },
        );
        addTearDown(nearby.dispose);
        final starting = nearby.start();
        await queried.future;
        await (dispose ? nearby.dispose() : nearby.stop());
        nativeReply.complete([
          {
            'name': 'test',
            'index': 1,
            'address': '192.168.1.2',
            'prefixLength': 24,
          },
        ]);
        await starting;
        expect(network.listens, 0);
        expect(discovery.starts, isEmpty);
        expect(nearby.state.phase, NearbyPhase.idle);
        if (dispose) {
          await nearby.start();
          expect(discovery.starts, isEmpty);
        }
      },
    );
  }

  test('stop during address enumeration never starts discovery', () async {
    final addresses = Completer<List<String>>();
    final queried = Completer<void>();
    final discovery = _Discovery();
    final nearby = _controller(
      discovery,
      localIps: () {
        queried.complete();
        return addresses.future;
      },
    );
    addTearDown(nearby.dispose);
    final starting = nearby.start();
    await queried.future;
    await nearby.stop();
    addresses.complete(['127.0.0.1']);
    await starting;
    expect(discovery.starts, isEmpty);
    expect(nearby.state.phase, NearbyPhase.idle);
  });

  test(
    'old discovery completion cannot close a newer controller listener',
    () async {
      final discovery = _Discovery();
      final nearby = _controller(discovery);
      addTearDown(nearby.dispose);
      var entered = discovery.started.stream.first;
      final first = nearby.start();
      await entered;
      final firstPort = discovery.starts[0].port;
      await nearby.stop();
      await expectLater(
        Socket.connect('127.0.0.1', firstPort),
        throwsA(isA<SocketException>()),
      );
      entered = discovery.started.stream.first;
      final second = nearby.start();
      await entered;
      discovery.starts[1].ready.complete();
      await second;
      final stops = discovery.stops;
      discovery.starts[0].ready.complete();
      await first;
      expect(discovery.stops, stops);
      expect(nearby.state.phase, NearbyPhase.looking);
      final connection = await Socket.connect(
        '127.0.0.1',
        discovery.starts[1].port,
      );
      expect(connection.remotePort, discovery.starts[1].port);
      connection.destroy();
    },
  );

  test('stop during discovery native lookup prevents UDP binding', () async {
    final network = Completer<NearbyWifiNetwork>();
    final queried = Completer<void>();
    var binds = 0;
    final discovery = LanNearbyDiscovery(
      readNetwork: () {
        queried.complete();
        return network.future;
      },
      bindSocket: (_) async {
        binds++;
        return _Socket();
      },
    );
    addTearDown(discovery.stop);
    final starting = discover(discovery);
    await queried.future;
    await discovery.stop();
    network.complete(_Network());
    await starting;
    expect(binds, 0);
  });

  test('stop during interface lookup prevents UDP binding', () async {
    final iface = Completer<NetworkInterface>();
    final network = _Network(interfaceReady: iface.future);
    final queried = Completer<void>();
    var binds = 0;
    final discovery = LanNearbyDiscovery(
      readNetwork: () async {
        queried.complete();
        return network;
      },
      bindSocket: (_) async {
        binds++;
        return _Socket();
      },
    );
    addTearDown(discovery.stop);
    final starting = discover(discovery);
    await queried.future;
    await Future<void>.delayed(Duration.zero);
    await discovery.stop();
    iface.complete(_Interface());
    await starting;
    expect(binds, 0);
  });

  test('a UDP socket bound after stop is closed without announcing', () async {
    final socket = _Socket();
    final bound = Completer<RawDatagramSocket>();
    final binding = Completer<void>();
    final discovery = LanNearbyDiscovery(
      readNetwork: () async => _Network(),
      bindSocket: (_) {
        binding.complete();
        return bound.future;
      },
    );
    addTearDown(discovery.stop);
    final starting = discover(discovery);
    await binding.future;
    await discovery.stop();
    bound.complete(socket);
    await starting;
    expect(socket.closed, isTrue);
    expect(socket.sends, 0);
  });

  test(
    'late mDNS start closes itself without replacing a newer client',
    () async {
      final first = _Mdns();
      final second = _Mdns();
      var created = 0;
      final sockets = <_Socket>[];
      final discovery = LanNearbyDiscovery(
        readNetwork: () async => _Network(),
        bindSocket: (_) async {
          final socket = _Socket();
          sockets.add(socket);
          return socket;
        },
        createMdnsClient: () => created++ == 0 ? first : second,
      );
      addTearDown(discovery.stop);
      await discover(discovery);
      await first.started.future;
      await discovery.stop();
      expect(sockets[0].closed, isTrue);
      await discover(discovery);
      await second.started.future;
      second.ready.complete();
      await Future<void>.delayed(Duration.zero);
      first.ready.complete();
      await Future<void>.delayed(Duration.zero);
      expect(first.stops, 1);
      expect(first.lookups, 0);
      expect(second.stops, 0);
      expect(second.lookups, 1);
      expect(sockets[1].closed, isFalse);
      await discovery.stop();
      expect(second.stops, 1);
      expect(sockets[1].closed, isTrue);
    },
  );
}
