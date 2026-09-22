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
