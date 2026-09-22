import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'nearby_protocol.dart';

class NearbyWifiNetwork {
  NearbyWifiNetwork({
    required this.name,
    required this.index,
    required this.address,
    required this.prefixLength,
  }) {
    if (_ipv4(address) == null ||
        !_isPrivate(_ipv4(address)!) ||
        index <= 0 ||
        prefixLength < 1 ||
        prefixLength > 30) {
      throw const NearbyException('Wi-Fi needs a private local IPv4 address.');
    }
  }

  final String name;
  final int index;
  final String address;
  final int prefixLength;
  ServerSocket? _listener;

  int get _mask => (0xffffffff << (32 - prefixLength)) & 0xffffffff;
  int get _network => _ipv4(address)! & _mask;
  int get _broadcast => _network | (0xffffffff ^ _mask);

  InternetAddress get bindAddress => InternetAddress(address);
  InternetAddress get broadcastAddress => InternetAddress(
    '${(_broadcast >> 24) & 255}.${(_broadcast >> 16) & 255}.'
    '${(_broadcast >> 8) & 255}.${_broadcast & 255}',
  );

  bool allowsPeer(String host) {
    final candidate = _ipv4(host);
    return candidate != null &&
        _isPrivate(candidate) &&
        (candidate & _mask) == _network &&
        candidate != _network &&
        candidate != _broadcast &&
        candidate != _ipv4(address);
  }

  void bindDatagram(RawDatagramSocket socket) {
    if (Platform.isMacOS || Platform.isIOS) {
      const ipBoundIf = 25;
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelIPv4, ipBoundIf, index),
      );
    } else if (Platform.isWindows) {
      const ipIfList = 28;
      const ipAddIfList = 29;
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelIPv4, ipIfList, 1),
      );
      socket.setRawOption(
        RawSocketOption.fromInt(RawSocketOption.levelIPv4, ipAddIfList, index),
      );
      socket.setRawOption(_windowsUnicastInterface);
    } else {
      throw const NearbyException(
        'This build cannot restrict Nearby to Wi-Fi.',
      );
    }
    socket.setRawOption(
      RawSocketOption(
        RawSocketOption.levelIPv4,
        RawSocketOption.IPv4MulticastInterface,
        bindAddress.rawAddress,
      ),
    );
  }

  RawSocketOption get _windowsUnicastInterface {
    const ipUnicastIf = 31;
    final bytes = ByteData(4)..setUint32(0, index, Endian.big);
    return RawSocketOption(
      RawSocketOption.levelIPv4,
      ipUnicastIf,
      bytes.buffer.asUint8List(),
    );
  }

  Future<ConnectionTask<Socket>> connect(Uri uri) async {
    if (!allowsPeer(uri.host)) {
      throw const NearbyException('Use the same Wi-Fi network.');
    }
    await interface();
    final task = await Socket.startConnect(
      InternetAddress(uri.host),
      uri.port,
      sourceAddress: bindAddress,
    );
    final ready = task.socket.then(_bindStream);
    return ConnectionTask.fromSocket(ready, task.cancel);
  }

  Socket _bindStream(Socket socket) {
    try {
      if (socket.address.address != address ||
          !allowsPeer(socket.remoteAddress.address)) {
        throw const NearbyException('Wi-Fi changed. Open Nearby again.');
      }
      if (Platform.isMacOS || Platform.isIOS) {
        socket.setRawOption(
          RawSocketOption.fromInt(RawSocketOption.levelIPv4, 25, index),
        );
      } else if (Platform.isWindows) {
        socket.setRawOption(_windowsUnicastInterface);
      } else {
        throw const NearbyException(
          'This build cannot restrict Nearby to Wi-Fi.',
        );
      }
      return socket;
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  Future<HttpServer> listen() async {
    await interface();
    final listener = await ServerSocket.bind(bindAddress, 0);
    _listener = listener;
    try {
      return HttpServer.listenOn(_WifiServerSocket(listener, _bindStream));
    } catch (_) {
      await listener.close();
      _listener = null;
      rethrow;
    }
  }

  Future<void> close() async {
    final listener = _listener;
    _listener = null;
    await listener?.close();
  }

  Future<NetworkInterface> interface() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final candidate in interfaces) {
      if (candidate.index == index &&
          candidate.addresses.any((ip) => ip.address == address)) {
        return candidate;
      }
    }
    throw const NearbyException('Wi-Fi changed. Open Nearby again.');
  }
}

class _WifiServerSocket extends StreamView<Socket> implements ServerSocket {
  _WifiServerSocket(this.listener, Socket Function(Socket) bind)
    : super(listener.map(bind));

  final ServerSocket listener;

  @override
  InternetAddress get address => listener.address;

  @override
  int get port => listener.port;

  @override
  Future<ServerSocket> close() => listener.close();
}

Future<NearbyWifiNetwork> readNearbyWifiNetwork() async {
  const channel = MethodChannel('wired_parts/nearby_wifi');
  final List<dynamic>? records;
  try {
    records = await channel.invokeMethod<List<dynamic>>('ipv4Interfaces');
  } on MissingPluginException {
    throw const NearbyException('This build cannot identify a Wi-Fi network.');
  } on PlatformException {
    throw const NearbyException('Could not read Wi-Fi. Open Nearby again.');
  }
  for (final record in records ?? const []) {
    if (record is! Map) continue;
    final name = record['name'];
    final address = record['address'];
    final index = record['index'];
    final prefix = record['prefixLength'];
    if (name is! String ||
        name.isEmpty ||
        address is! String ||
        prefix is! int ||
        index is! int) {
      continue;
    }
    try {
      return NearbyWifiNetwork(
        name: name,
        index: index,
        address: address,
        prefixLength: prefix,
      );
    } on NearbyException {
      continue;
    }
  }
  throw const NearbyException('Connect to the same Wi-Fi as the other device.');
}

int? _ipv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  var result = 0;
  for (final part in parts) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return null;
    final octet = int.parse(part);
    if (octet > 255) return null;
    result = (result << 8) | octet;
  }
  return result;
}

bool _isPrivate(int address) =>
    (address & 0xff000000) == 0x0a000000 ||
    (address & 0xfff00000) == 0xac100000 ||
    (address & 0xffff0000) == 0xc0a80000;
