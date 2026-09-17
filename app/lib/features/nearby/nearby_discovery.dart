import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

import 'nearby_protocol.dart';

abstract class NearbyDiscovery {
  Stream<List<NearbyPeer>> get peers;
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  });
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  });
  Future<void> stop();
}

/// LAN discovery: UDP multicast beacon (Windows-friendly) plus mDNS
/// `_wiredpart._tcp` browse/announce. Not Bluetooth.
class LanNearbyDiscovery implements NearbyDiscovery {
  LanNearbyDiscovery({
    this.udpPort = kNearbyUdpPort,
    this.now,
  });

  final int udpPort;
  final DateTime Function()? now;

  final _peerCtrl = StreamController<List<NearbyPeer>>.broadcast();
  final _peers = <String, _SeenPeer>{};
  RawDatagramSocket? _socket;
  Timer? _announce;
  Timer? _expire;
  MDnsClient? _mdns;
  StreamSubscription<ResourceRecord>? _mdnsSub;
  String _deviceId = '';
  String _name = '';
  int _httpPort = 0;
  List<String> _ips = const [];
  var _running = false;

  @override
  Stream<List<NearbyPeer>> get peers => _peerCtrl.stream;

  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    await stop();
    _deviceId = deviceId;
    _name = name;
    _httpPort = port;
    _ips = ips;
    _running = true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: true,
        reusePort: Platform.isMacOS || Platform.isIOS || Platform.isLinux,
      );
      socket.broadcastEnabled = true;
      socket.multicastLoopback = true;
      try {
        socket.joinMulticast(InternetAddress(kNearbyMulticastGroup));
      } catch (_) {
        // Some NICs need an interface; still broadcast / send multicast.
      }
      for (final iface in await _ipv4Ifaces()) {
        try {
          socket.joinMulticast(InternetAddress(kNearbyMulticastGroup), iface);
        } catch (_) {}
      }
      _socket = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        _onDatagram(dg);
      });
    } catch (e) {
      throw NearbyException(
        'Could not listen on this Wi‑Fi. Allow Wired Parts through the '
        'firewall and keep Nearby open. ($e)',
      );
    }
    _announce = Timer.periodic(const Duration(seconds: 2), (_) {
      _sendBeacon();
      _sendWho();
    });
    _expire = Timer.periodic(const Duration(seconds: 2), (_) => _dropStale());
    _sendBeacon();
    _sendWho();
    _startMdnsBrowse();
  }

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    _name = name;
    _httpPort = port;
    _ips = ips;
    _sendBeacon();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _announce?.cancel();
    _announce = null;
    _expire?.cancel();
    _expire = null;
    await _mdnsSub?.cancel();
    _mdnsSub = null;
    _mdns?.stop();
    _mdns = null;
    _socket?.close();
    _socket = null;
    _peers.clear();
    if (!_peerCtrl.isClosed) _peerCtrl.add(const []);
  }

  void _onDatagram(Datagram dg) {
    Map<String, Object?> map;
    try {
      map = decodeBeacon(dg.data);
    } catch (_) {
      return;
    }
    if (isWhoQuery(map)) {
      _sendBeacon();
      return;
    }
    final peer = peerFromBeacon(map, fromHost: dg.address.address);
    if (peer == null || peer.deviceId == _deviceId) return;
    _remember(peer);
  }

  void _remember(NearbyPeer peer) {
    _peers[peer.deviceId] = _SeenPeer(
      peer: peer,
      seenAt: now?.call() ?? DateTime.now(),
    );
    _emit();
  }

  void _dropStale() {
    final cutoff = (now?.call() ?? DateTime.now()).subtract(
      const Duration(seconds: 8),
    );
    final before = _peers.length;
    _peers.removeWhere((_, v) => v.seenAt.isBefore(cutoff));
    if (_peers.length != before) _emit();
  }

  void _emit() {
    final list = _peers.values.map((e) => e.peer).toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    if (!_peerCtrl.isClosed) _peerCtrl.add(list);
  }

  void _sendBeacon() {
    final socket = _socket;
    if (socket == null || !_running || _httpPort == 0) return;
    final bytes = encodeBeacon(
      deviceId: _deviceId,
      name: _name,
      port: _httpPort,
      ips: _ips,
    );
    try {
      socket.send(
        bytes,
        InternetAddress(kNearbyMulticastGroup),
        udpPort,
      );
    } catch (_) {}
    try {
      socket.send(bytes, InternetAddress('255.255.255.255'), udpPort);
    } catch (_) {}
    _sendMdnsAnnounce();
  }

  void _sendWho() {
    final socket = _socket;
    if (socket == null) return;
    final bytes = encodeWhoQuery();
    try {
      socket.send(
        bytes,
        InternetAddress(kNearbyMulticastGroup),
        udpPort,
      );
    } catch (_) {}
  }

  Future<void> _startMdnsBrowse() async {
    try {
      final client = MDnsClient();
      await client.start();
      if (!_running) {
        client.stop();
        return;
      }
      _mdns = client;
      _mdnsSub = client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('$kNearbyServiceType.local'),
          )
          .listen((ptr) => _resolveMdns(client, ptr.domainName), onError: (_) {});
    } catch (_) {
      // UDP beacon still runs. mDNS is best-effort on Windows without Bonjour.
    }
  }

  Future<void> _resolveMdns(MDnsClient client, String domain) async {
    try {
      String? host;
      var port = 0;
      String? id;
      var name = '';
      await for (final srv in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(domain),
      )) {
        host = srv.target;
        port = srv.port;
        break;
      }
      await for (final txt in client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(domain),
      )) {
        for (final entry in _txtEntries(txt.text)) {
          final i = entry.indexOf('=');
          if (i <= 0) continue;
          final k = entry.substring(0, i);
          final v = entry.substring(i + 1);
          if (k == 'id') id = v;
          if (k == 'name') name = v;
        }
        break;
      }
      if (host != null && host.endsWith('.local')) {
        await for (final a in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(host),
        )) {
          host = a.address.address;
          break;
        }
      }
      if (id == null || id == _deviceId || host == null || port == 0) return;
      _remember(NearbyPeer(deviceId: id, name: name, host: host, port: port));
    } catch (_) {}
  }

  static Iterable<String> _txtEntries(String text) {
    final out = <String>[];
    for (final line in text.split(RegExp(r'[\u0000-\u001f]+'))) {
      final trimmed = line.trim();
      if (trimmed.contains('=')) out.add(trimmed);
    }
    if (out.isEmpty && text.contains('=')) {
      final matches = RegExp(r'(id|name|proto)=([^\u0000]+)').allMatches(text);
      for (final m in matches) {
        out.add(m.group(0)!);
      }
    }
    return out;
  }

  void _sendMdnsAnnounce() {
    final socket = _socket;
    if (socket == null || _ips.isEmpty || _httpPort == 0) return;
    try {
      final packet = buildMdnsAnnouncement(
        instanceName: _safeInstance(_name, _deviceId),
        port: _httpPort,
        ipv4: _ips.first,
        deviceId: _deviceId,
        name: _name,
      );
      socket.send(packet, InternetAddress('224.0.0.251'), 5353);
    } catch (_) {}
  }
}

class _SeenPeer {
  _SeenPeer({required this.peer, required this.seenAt});
  final NearbyPeer peer;
  final DateTime seenAt;
}

Future<List<NetworkInterface>> _ipv4Ifaces() async {
  try {
    return await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
  } catch (_) {
    return const [];
  }
}

Future<List<String>> localIpv4Addresses() async {
  final out = <String>[];
  for (final iface in await _ipv4Ifaces()) {
    for (final addr in iface.addresses) {
      if (addr.isLoopback) continue;
      out.add(addr.address);
    }
  }
  if (out.isEmpty) {
    try {
      for (final iface in await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
      )) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          out.add(addr.address);
        }
      }
    } catch (_) {}
  }
  return out;
}

String _safeInstance(String name, String deviceId) {
  final raw = name.trim().isEmpty ? defaultNearbyName(deviceId) : name.trim();
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9 -]'), ' ').trim();
  final base = cleaned.isEmpty ? defaultNearbyName(deviceId) : cleaned;
  return base.length > 40 ? base.substring(0, 40) : base;
}

/// Unsolicited mDNS PTR/SRV/TXT/A for `_wiredpart._tcp.local`.
Uint8List buildMdnsAnnouncement({
  required String instanceName,
  required int port,
  required String ipv4,
  required String deviceId,
  required String name,
}) {
  final ptrName = '$kNearbyServiceType.local';
  final serviceName = '$instanceName.$kNearbyServiceType.local';
  final hostName = 'wp-${shortId(deviceId)}.local';
  final parts = ipv4.split('.');
  if (parts.length != 4) {
    throw const NearbyException('Invalid IPv4 for mDNS');
  }
  final ipBytes = parts.map(int.parse).toList();

  final answers = BytesBuilder(copy: false);
  _writeRr(answers, ptrName, 12, _encodeName(serviceName)); // PTR
  final srv = BytesBuilder(copy: false);
  _putU16(srv, 0);
  _putU16(srv, 0);
  _putU16(srv, port);
  srv.add(_encodeName(hostName));
  _writeRr(answers, serviceName, 33, srv.toBytes()); // SRV
  final txt = BytesBuilder(copy: false);
  void txtItem(String s) {
    final b = s.codeUnits;
    txt.addByte(b.length);
    txt.add(b);
  }
  txtItem('id=$deviceId');
  txtItem('name=$name');
  txtItem('proto=$kNearbyProto');
  _writeRr(answers, serviceName, 16, txt.toBytes()); // TXT
  _writeRr(answers, hostName, 1, ipBytes); // A

  final out = BytesBuilder(copy: false);
  _putU16(out, 0); // id
  _putU16(out, 0x8400); // response, authoritative
  _putU16(out, 0); // questions
  _putU16(out, 4); // answers
  _putU16(out, 0);
  _putU16(out, 0);
  out.add(answers.toBytes());
  return Uint8List.fromList(out.toBytes());
}

void _writeRr(BytesBuilder out, String name, int type, List<int> rdata) {
  out.add(_encodeName(name));
  _putU16(out, type);
  _putU16(out, 1); // IN
  _putU32(out, 120); // TTL
  _putU16(out, rdata.length);
  out.add(rdata);
}

List<int> _encodeName(String name) {
  final out = BytesBuilder(copy: false);
  for (final label in name.split('.')) {
    if (label.isEmpty) continue;
    final b = label.codeUnits;
    out.addByte(b.length);
    out.add(b);
  }
  out.addByte(0);
  return out.toBytes();
}

void _putU16(BytesBuilder out, int n) => out.add([(n >> 8) & 0xff, n & 0xff]);

void _putU32(BytesBuilder out, int n) => out.add([
  (n >> 24) & 0xff,
  (n >> 16) & 0xff,
  (n >> 8) & 0xff,
  n & 0xff,
]);
