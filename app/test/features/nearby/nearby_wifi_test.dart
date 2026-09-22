import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('wired_parts/nearby_wifi');
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'outgoing socket uses peer address while binding selected Wi-Fi',
    () async {
      final network = _Network();
      final socket = _Socket('192.168.10.40', '192.168.10.40');
      await _outgoing(socket, () async {
        final task = await network.connect(
          Uri.parse('http://192.168.10.40:6809'),
        );
        expect(await task.socket, same(socket));
        expect(socket.destroyed, isFalse);
        expect(socket.options.single.option, Platform.isWindows ? 31 : 25);
        expect(network.interfaceChecks, 1);
      });
    },
  );

  for (final endpoint in [
    ('192.168.10.41', '192.168.10.40'),
    ('192.168.10.40', '192.168.10.41'),
    ('192.168.10.40', '192.168.11.40'),
  ]) {
    test('outgoing rejects unexpected endpoint $endpoint', () async {
      final network = _Network();
      final socket = _Socket(endpoint.$1, endpoint.$2);
      await _outgoing(socket, () async {
        final task = await network.connect(
          Uri.parse('http://192.168.10.40:6809'),
        );
        await expectLater(task.socket, throwsA(isA<NearbyException>()));
        expect(socket.destroyed, isTrue);
        expect(socket.options, isEmpty);
      });
    });
  }

  test('outgoing option failure destroys socket before release', () async {
    final network = _Network();
    final socket = _Socket('192.168.10.40', '192.168.10.40')..failOption = true;
    await _outgoing(socket, () async {
      final task = await network.connect(
        Uri.parse('http://192.168.10.40:6809'),
      );
      await expectLater(task.socket, throwsA(isA<SocketException>()));
      expect(socket.destroyed, isTrue);
    });
  });

  for (final endpoint in [
    ('192.168.10.20', '192.168.10.40', false),
    ('192.168.10.21', '192.168.10.40', true),
    ('192.168.10.20', '192.168.11.40', true),
  ]) {
    test('accepted socket validates listener and peer $endpoint', () async {
      final network = _Network();
      final listener = _Listener();
      final socket = _Socket(endpoint.$1, endpoint.$2);
      await IOOverrides.runZoned(
        () async {
          final server = await network.listen();
          final errors = <Object>[];
          final subscription = server.listen((_) {}, onError: errors.add);
          listener.events.add(socket);
          await Future<void>.delayed(Duration.zero);
          expect(socket.destroyed, endpoint.$3);
          expect(errors.length, endpoint.$3 ? 1 : 0);
          expect(socket.options.length, endpoint.$3 ? 0 : 1);
          await server.close(force: true);
          await subscription.cancel();
          await network.close();
        },
        serverSocketBind:
            (
              address,
              port, {
              backlog = 0,
              v6Only = false,
              shared = false,
            }) async {
              expect((address as InternetAddress).address, '192.168.10.20');
              return listener;
            },
      );
    });
  }

  test(
    'only other private IPv4 peers on the selected Wi-Fi subnet are allowed',
    () {
      final network = NearbyWifiNetwork(
        name: 'Wi-Fi',
        index: 7,
        address: '192.168.10.20',
        prefixLength: 24,
      );
      expect(network.bindAddress.address, '192.168.10.20');
      expect(network.broadcastAddress.address, '192.168.10.255');
      expect(network.allowsPeer('192.168.10.40'), isTrue);
      for (final host in [
        '192.168.11.40',
        '10.0.0.1',
        '8.8.8.8',
        '127.0.0.1',
        '192.168.10.20',
        '192.168.10.0',
        '192.168.10.255',
        'example.com',
        'localhost',
        '::1',
        '192.168.010.40',
        '192.168.10.999',
        '192.168.10.40.example.com',
      ]) {
        expect(network.allowsPeer(host), isFalse, reason: host);
      }
    },
  );

  test(
    'private range and prefix boundaries reject public and ambiguous networks',
    () {
      for (final address in [
        '172.15.0.1',
        '172.32.0.1',
        '100.64.0.1',
        '0.0.0.0',
        '169.254.1.2',
      ]) {
        expect(
          () => NearbyWifiNetwork(
            name: 'Wi-Fi',
            index: 7,
            address: address,
            prefixLength: 24,
          ),
          throwsA(isA<NearbyException>()),
        );
      }
      for (final prefix in [-1, 0, 31, 32, 33]) {
        expect(
          () => NearbyWifiNetwork(
            name: 'Wi-Fi',
            index: 7,
            address: '10.1.2.3',
            prefixLength: prefix,
          ),
          throwsA(isA<NearbyException>()),
        );
      }
      final network = NearbyWifiNetwork(
        name: 'Wi-Fi',
        index: 7,
        address: '172.16.2.3',
        prefixLength: 20,
      );
      expect(network.allowsPeer('172.16.15.254'), isTrue);
      expect(network.allowsPeer('172.16.16.1'), isFalse);
    },
  );

  test(
    'native Wi-Fi selection uses only native-provided adapter records',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'ipv4Interfaces');
        return [
          {
            'name': 'invalid',
            'index': 4,
            'address': '203.0.113.1',
            'prefixLength': 24,
          },
          {
            'name': 'en1',
            'index': 7,
            'address': '192.168.1.10',
            'prefixLength': 24,
          },
        ];
      });
      final network = await readNearbyWifiNetwork();
      expect(network.name, 'en1');
      expect(network.address, '192.168.1.10');
      expect(network.prefixLength, 24);
    },
  );

  test(
    'no Wi-Fi adapter does not fall back to Ethernet or all interfaces',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => []);
      await expectLater(
        readNearbyWifiNetwork(),
        throwsA(isA<NearbyException>()),
      );
    },
  );

  test(
    'native enumeration failure does not fall back to all interfaces',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'enumeration'),
      );
      await expectLater(
        readNearbyWifiNetwork(),
        throwsA(isA<NearbyException>()),
      );
    },
  );
}

class _Network extends NearbyWifiNetwork {
  _Network()
    : super(
        name: 'Wi-Fi',
        index: 7,
        address: '192.168.10.20',
        prefixLength: 24,
      );
  int interfaceChecks = 0;
  @override
  Future<NetworkInterface> interface() async {
    interfaceChecks++;
    return _Interface();
  }
}

class _Interface implements NetworkInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _outgoing(_Socket socket, Future<void> Function() body) =>
    IOOverrides.runZoned(
      body,
      socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) async {
        expect((host as InternetAddress).address, '192.168.10.40');
        expect(port, 6809);
        expect((sourceAddress as InternetAddress).address, '192.168.10.20');
        return ConnectionTask.fromSocket(Future.value(socket), socket.destroy);
      },
    );

class _Socket extends Stream<Uint8List> implements Socket {
  _Socket(String address, String remote)
    : address = InternetAddress(address),
      remoteAddress = InternetAddress(remote);
  @override
  final InternetAddress address;
  @override
  final InternetAddress remoteAddress;
  final events = StreamController<Uint8List>();
  final options = <RawSocketOption>[];
  bool destroyed = false;
  bool failOption = false;
  @override
  int get port => 6809;
  @override
  int get remotePort => 6810;
  @override
  Future<void> get done => Future<void>.value();
  @override
  void destroy() {
    destroyed = true;
    unawaited(events.close());
  }

  @override
  void setRawOption(RawSocketOption option) {
    if (failOption) throw const SocketException('Synthetic option failure');
    options.add(option);
  }

  @override
  bool setOption(SocketOption option, bool enabled) => true;
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Listener extends Stream<Socket> implements ServerSocket {
  final events = StreamController<Socket>();
  @override
  InternetAddress get address => InternetAddress('192.168.10.20');
  @override
  int get port => 6809;
  @override
  Future<ServerSocket> close() async {
    unawaited(events.close());
    return this;
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
