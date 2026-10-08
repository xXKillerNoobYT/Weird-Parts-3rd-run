import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';

void main() {
  for (final destination in ['239.55.12.42', '224.0.0.251']) {
    testWidgets(
      'broadcast discovery survives asynchronous send failure to $destination',
      (tester) async {
        final fixture = _Fixture(failingDestination: destination);
        addTearDown(fixture.dispose);
        await fixture.start();
        await tester.pump();
        expect(fixture.broadcastBeacons, isNotEmpty);
        fixture.sent.clear();

        await tester.pump(const Duration(seconds: 4));
        expect(fixture.broadcastBeacons, isNotEmpty);
        expect(fixture.broadcastBeacons.last, _advertisement());
        await fixture.discovery.updateAdvertisement(
          name: 'Renamed shop',
          port: 6810,
          ips: ['192.168.10.20'],
        );
        await tester.pump();
        expect(
          fixture.broadcastBeacons.last,
          _advertisement(name: 'Renamed shop', port: 6810),
        );

        fixture.receivePeer('192.168.11.40', 'off-subnet');
        fixture.receivePeer('192.168.10.20', 'self-address');
        fixture.receivePeer('192.168.10.0', 'network-address');
        fixture.receivePeer('192.168.10.255', 'broadcast-address');
        fixture.receivePeer('192.168.10.40', 'peer-shop');
        await tester.pump();
        expect(fixture.peerValues.last, [
          ('peer-shop', 'Peer shop', '192.168.10.40', 6900),
        ]);
        expect(fixture.errors, isEmpty);
        expect(fixture.failedSends, isNotEmpty);
        expect(fixture.failedSends.every((socket) => socket.closed), isTrue);

        await fixture.discovery.stop();
        await tester.pump();
        expect(fixture.sockets.every((socket) => socket.closed), isTrue);
        final sendsAfterStop = fixture.sent.length;
        await tester.pump(const Duration(seconds: 4));
        expect(fixture.sent.length, sendsAfterStop);
      },
    );
  }

  testWidgets('optional mDNS browse error preserves broadcast peers', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.start();
    await tester.pump();
    fixture.mdnsClients.single.fail();
    await tester.pump(const Duration(seconds: 2));
    expect(fixture.broadcastBeacons.last, _advertisement());
    fixture.receivePeer('192.168.10.40', 'peer-shop');
    await tester.pump();
    expect(fixture.peerValues.last, [
      ('peer-shop', 'Peer shop', '192.168.10.40', 6900),
    ]);
    expect(fixture.errors, isEmpty);
    expect(fixture.mdnsClients.single.stopped, isTrue);
    await fixture.discovery.stop();
    await tester.pump();
  });

  for (final failure in [
    'broadcast',
    'listener',
    'synchronous broadcast SocketException',
    'synchronous broadcast OSError',
  ]) {
    testWidgets('mandatory $failure failure is visible and closes discovery', (
      tester,
    ) async {
      final fixture = _Fixture(
        failingDestination: failure == 'listener' ? null : '192.168.10.255',
        failure: switch (failure) {
          'synchronous broadcast SocketException' =>
            _SendFailure.socketException,
          'synchronous broadcast OSError' => _SendFailure.osError,
          _ => _SendFailure.asynchronous,
        },
      );
      addTearDown(fixture.dispose);
      await fixture.start();
      if (failure == 'listener') {
        fixture.receivePeer('192.168.10.40', 'peer-shop');
        await tester.pump();
        expect(fixture.peerValues.last, [
          ('peer-shop', 'Peer shop', '192.168.10.40', 6900),
        ]);
        fixture.sockets
            .where((socket) => socket.port == 41000 && !socket.closed)
            .first
            .fail();
      }
      await tester.pump();
      expect(fixture.errors, hasLength(1));
      expect(
        fixture.errors.single,
        failure == 'synchronous broadcast OSError'
            ? isA<OSError>()
            : isA<SocketException>(),
      );
      expect(fixture.sockets.every((socket) => socket.closed), isTrue);
      expect(fixture.peerValues.last, isEmpty);
      final sendsAfterFailure = fixture.sent.length;
      await tester.pump(const Duration(seconds: 4));
      expect(fixture.sent.length, sendsAfterFailure);
    });
  }

  testWidgets(
    'temporary broadcast backpressure permits the next announcement',
    (tester) async {
      final fixture = _Fixture(
        failingDestination: '192.168.10.255',
        failure: _SendFailure.backpressure,
      );
      addTearDown(fixture.dispose);
      await fixture.start();
      await tester.pump();
      expect(fixture.failedSends, isNotEmpty);
      expect(fixture.errors, isEmpty);
      fixture.failingDestination = null;
      await tester.pump(const Duration(seconds: 2));
      expect(fixture.broadcastBeacons.last, _advertisement());
      fixture.receivePeer('192.168.10.40', 'peer-shop');
      await tester.pump();
      expect(fixture.peerValues.last, [
        ('peer-shop', 'Peer shop', '192.168.10.40', 6900),
      ]);
      await fixture.discovery.stop();
      await tester.pump();
      expect(fixture.sockets.every((socket) => socket.closed), isTrue);
    },
  );

  testWidgets('delayed optional send error cannot stop a new discovery run', (
    tester,
  ) async {
    final fixture = _Fixture(
      failingDestination: '239.55.12.42',
      failure: _SendFailure.delayed,
    );
    addTearDown(fixture.dispose);
    await fixture.start();
    await tester.pump();
    final oldFailures = fixture.delayedFailures.toList();
    expect(oldFailures, isNotEmpty);
    await fixture.discovery.stop();
    await tester.pump();
    expect(fixture.sockets.every((socket) => socket.closed), isTrue);

    fixture.failingDestination = null;
    await fixture.start(name: 'Retry shop', port: 6811);
    for (final fail in oldFailures) {
      fail();
    }
    await tester.pump(const Duration(seconds: 4));
    expect(
      fixture.broadcastBeacons.last,
      _advertisement(name: 'Retry shop', port: 6811),
    );
    fixture.receivePeer('192.168.10.40', 'peer-shop');
    await tester.pump();
    expect(fixture.peerValues.last, [
      ('peer-shop', 'Peer shop', '192.168.10.40', 6900),
    ]);
    expect(fixture.errors, isEmpty);
    await fixture.discovery.stop();
    await tester.pump();
    expect(fixture.sockets.every((socket) => socket.closed), isTrue);
  });
}

Map<String, Object?> _advertisement({
  String name = 'Local shop',
  int port = 6809,
}) => {
  'v': 2,
  'kind': 'wiredpart',
  'proto': 'wiredpart-link',
  'id': 'local-shop',
  'name': name,
  'port': port,
  'ips': ['192.168.10.20'],
};

class _Fixture {
  _Fixture({
    this.failingDestination,
    this.failure = _SendFailure.asynchronous,
  }) {
    discovery = LanNearbyDiscovery(
      readNetwork: () async => _Network(),
      bindSocket: (port) async {
        final socket = _Socket(this, port);
        sockets.add(socket);
        return socket;
      },
      createMdnsClient: () {
        final client = _Mdns();
        mdnsClients.add(client);
        return client;
      },
    );
    subscription = discovery.peers.listen(
      (peers) => peerValues.add([
        for (final peer in peers)
          (peer.deviceId, peer.name, peer.host, peer.port),
      ]),
      onError: errors.add,
    );
  }

  String? failingDestination;
  final _SendFailure failure;
  final sockets = <_Socket>[];
  final failedSends = <_Socket>{};
  final delayedFailures = <void Function()>[];
  final sent = <({String destination, List<int> bytes})>[];
  final errors = <Object>[];
  final peerValues = <List<(String, String, String, int)>>[];
  final mdnsClients = <_Mdns>[];
  late final LanNearbyDiscovery discovery;
  late final StreamSubscription<List<NearbyPeer>> subscription;

  List<Map<String, Object?>> get broadcastBeacons => [
    for (final packet in sent)
      if (packet.destination == '192.168.10.255')
        Map<String, Object?>.from(jsonDecode(utf8.decode(packet.bytes)) as Map),
  ];

  Future<void> start({String name = 'Local shop', int port = 6809}) =>
      discovery.start(
        deviceId: 'local-shop',
        name: name,
        port: port,
        ips: ['192.168.10.20'],
      );

  void receivePeer(String host, String id) {
    final data = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 2,
          'kind': 'wiredpart',
          'proto': 'wiredpart-link',
          'id': id,
          'name': 'Peer shop',
          'port': 6900,
          'ips': ['192.168.11.99'],
        }),
      ),
    );
    for (final socket in sockets) {
      if (socket.port == 41000 && !socket.closed) {
        socket.incoming.add(Datagram(data, InternetAddress(host), 41000));
        socket.events.add(RawSocketEvent.read);
      }
    }
  }

  Future<void> dispose() async {
    await discovery.stop();
    await subscription.cancel();
  }
}

class _Socket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  _Socket(this.fixture, this.port);

  final _Fixture fixture;
  @override
  final int port;
  final events = StreamController<RawSocketEvent>();
  final incoming = Queue<Datagram>();
  bool closed = false;
  bool _failureScheduled = false;
  @override
  bool broadcastEnabled = false;
  @override
  bool multicastLoopback = false;
  @override
  int multicastHops = 1;

  @override
  int send(List<int> bytes, InternetAddress address, int port) {
    if (closed) throw const SocketException('Socket is closed');
    if (address.address == fixture.failingDestination) {
      fixture.failedSends.add(this);
      if (fixture.failure == _SendFailure.backpressure) return 0;
      if (fixture.failure == _SendFailure.socketException) {
        throw const SocketException('Synthetic broadcast send failure');
      }
      if (fixture.failure == _SendFailure.osError) {
        throw const OSError('Synthetic broadcast send failure');
      }
      if (!_failureScheduled) {
        _failureScheduled = true;
        if (fixture.failure == _SendFailure.delayed) {
          final listener = _onError;
          fixture.delayedFailures.add(() {
            listener?.call(
              const SocketException('Synthetic delayed send failure'),
              StackTrace.current,
            );
          });
        } else {
          scheduleMicrotask(fail);
        }
      }
      return 0;
    }
    fixture.sent.add((destination: address.address, bytes: List.of(bytes)));
    return bytes.length;
  }

  void fail() {
    if (closed) return;
    events.addError(const SocketException('Synthetic send failure'));
    close();
  }

  @override
  Datagram? receive() => incoming.isEmpty ? null : incoming.removeFirst();

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) {}

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(events.close());
  }

  Function? _onError;
  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onError = onError;
    return events.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

enum _SendFailure {
  asynchronous,
  delayed,
  backpressure,
  socketException,
  osError,
}

class _Network extends NearbyWifiNetwork {
  _Network()
    : super(
        name: 'Test Wi-Fi',
        index: 7,
        address: '192.168.10.20',
        prefixLength: 24,
      );

  @override
  Future<NetworkInterface> interface() async => _Interface();
  @override
  void bindDatagram(RawDatagramSocket socket) {}
}

class _Interface implements NetworkInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Mdns extends MDnsClient {
  Function? _onError;
  bool stopped = false;

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    _onError = onError;
  }

  void fail() =>
      _onError?.call(const SocketException('Synthetic mDNS browse failure'));

  @override
  void stop() {
    stopped = true;
  }

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) => StreamController<T>(onCancel: () async {}).stream;
}
