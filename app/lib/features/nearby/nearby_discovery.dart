import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

import 'nearby_protocol.dart';
import 'nearby_wifi.dart';

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
    this.readNetwork = readNearbyWifiNetwork,
    this.bindSocket,
    this.createMdnsClient,
  });

  final int udpPort;
  final DateTime Function()? now;
  final Future<NearbyWifiNetwork> Function() readNetwork;
  final Future<RawDatagramSocket> Function(int port)? bindSocket;
  final MDnsClient Function(RawDatagramSocketFactory factory)? createMdnsClient;

  final _peerCtrl = StreamController<List<NearbyPeer>>.broadcast();
  final _peers = <String, _SeenPeer>{};
  _UdpResource? _requiredUdp;
  _UdpResource? _multicastTx;
  Timer? _announce;
  Timer? _expire;
  _MdnsRun? _mdns;
  String _deviceId = '';
  String _name = '';
  int _httpPort = 0;
  List<String> _ips = const [];
  var _running = false;
  int _generation = 0;
  NearbyWifiNetwork? _network;

  @override
  Stream<List<NearbyPeer>> get peers => _peerCtrl.stream;

  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    final stopping = stop();
    final generation = _generation;
    await stopping;
    if (generation != _generation) return;
    final network = await readNetwork();
    if (generation != _generation) return;
    if (ips.length != 1 || ips.single != network.address) {
      throw const NearbyException('Wi-Fi changed. Open Nearby again.');
    }
    final iface = await network.interface();
    if (generation != _generation) return;
    RawDatagramSocket? socket;
    try {
      socket =
          await (bindSocket?.call(udpPort) ??
              RawDatagramSocket.bind(
                InternetAddress.anyIPv4,
                udpPort,
                reuseAddress: true,
                reusePort:
                    Platform.isMacOS || Platform.isIOS || Platform.isLinux,
              ));
      if (generation != _generation) {
        socket.close();
        return;
      }
      socket.broadcastEnabled = true;
      network.bindDatagram(socket);
      try {
        socket.joinMulticast(InternetAddress(kNearbyMulticastGroup), iface);
      } on SocketException catch (error, stack) {
        _logOptionalFailure('multicast membership', error, stack);
      } on OSError catch (error, stack) {
        _logOptionalFailure('multicast membership', error, stack);
      }
      _deviceId = deviceId;
      _name = name;
      _httpPort = port;
      _network = network;
      _ips = [network.address];
      _running = true;
      final owner = _UdpResource(generation, socket);
      _requiredUdp = owner;
      owner.events = socket.listen(
        (event) {
          if (!_isCurrentRequired(owner)) return;
          if (event == RawSocketEvent.closed ||
              event == RawSocketEvent.readClosed) {
            _requiredFailed(
              owner,
              const NearbyException('Discovery socket closed'),
            );
            return;
          }
          if (event != RawSocketEvent.read) return;
          final dg = owner.socket.receive();
          if (dg != null) _onDatagram(dg);
        },
        onError: (Object error, StackTrace stack) {
          _requiredFailed(owner, error, stack);
        },
        onDone: () {
          _requiredFailed(
            owner,
            const NearbyException('Discovery socket closed'),
          );
        },
      );
    } catch (e) {
      socket?.close();
      if (generation != _generation) return;
      throw NearbyException(
        'Could not listen on this Wi-Fi. Allow Wired Parts through the '
        'firewall and keep Nearby open. ($e)',
      );
    }
    _announce = Timer.periodic(const Duration(seconds: 2), (_) {
      if (generation != _generation) return;
      _sendBeacon();
      _sendWho();
    });
    _expire = Timer.periodic(const Duration(seconds: 2), (_) {
      if (generation == _generation) _dropStale();
    });
    _sendBeacon();
    if (generation != _generation || !_running) return;
    unawaited(_startMulticastTx(generation, network));
    unawaited(_startMdnsBrowse(generation, network, iface));
  }

  bool _isCurrentRequired(_UdpResource owner) =>
      owner.generation == _generation &&
      _running &&
      identical(_requiredUdp, owner);

  bool _isCurrentMulticast(_UdpResource owner) =>
      owner.generation == _generation &&
      _running &&
      identical(_multicastTx, owner);

  bool _isCurrentMdns(_MdnsRun owner) =>
      owner.generation == _generation &&
      _running &&
      identical(_mdns, owner) &&
      owner.phase != _MdnsPhase.closed;

  void _requiredFailed(_UdpResource owner, Object error, [StackTrace? stack]) {
    if (!_isCurrentRequired(owner)) return;
    final stopping = stop();
    _peerCtrl.addError(error, stack);
    unawaited(stopping);
  }

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    final generation = _generation;
    if (!_running) return;
    final network = await readNetwork();
    if (generation != _generation) return;
    if (network.index != _network?.index ||
        network.address != _network?.address ||
        network.prefixLength != _network?.prefixLength) {
      throw const NearbyException('Wi-Fi changed. Open Nearby again.');
    }
    _name = name;
    _httpPort = port;
    _ips = [network.address];
    _sendBeacon();
  }

  @override
  Future<void> stop() async {
    ++_generation;
    _running = false;
    _announce?.cancel();
    _announce = null;
    _expire?.cancel();
    _expire = null;
    final required = _requiredUdp;
    final multicast = _multicastTx;
    final mdns = _mdns;
    _requiredUdp = null;
    _multicastTx = null;
    _mdns = null;
    _network = null;
    final cancellations = <Future<void>>[];
    for (final owner in [required, multicast]) {
      if (owner == null) continue;
      owner.socket.close();
      cancellations.add(owner.events.cancel());
    }
    if (mdns != null) cancellations.add(_closeMdns(mdns));
    _peers.clear();
    if (!_peerCtrl.isClosed) _peerCtrl.add(const []);
    await Future.wait(cancellations);
  }

  void _onDatagram(Datagram dg) {
    if (!(_network?.allowsPeer(dg.address.address) ?? false)) return;
    try {
      final map = decodeBeacon(dg.data);
      if (isWhoQuery(map)) {
        _sendBeacon();
        return;
      }
      final peer = peerFromBeacon(map, fromHost: dg.address.address);
      if (peer == null || peer.deviceId == _deviceId) return;
      _remember(peer.copyWith(host: dg.address.address));
    } catch (_) {
      return;
    }
  }

  void _remember(NearbyPeer peer) {
    if (!(_network?.allowsPeer(peer.host) ?? false)) return;
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
    final owner = _requiredUdp;
    if (owner == null || !_isCurrentRequired(owner) || _httpPort == 0) return;
    final bytes = encodeBeacon(
      deviceId: _deviceId,
      name: _name,
      port: _httpPort,
      ips: _ips,
    );
    try {
      owner.socket.send(bytes, _network!.broadcastAddress, udpPort);
    } catch (error, stack) {
      _requiredFailed(owner, error, stack);
      return;
    }
    if (!_isCurrentRequired(owner)) return;
    final multicast = _multicastTx;
    if (multicast != null) _sendMulticast(multicast, bytes);
    final mdns = _mdns;
    if (mdns != null) _sendMdnsAnnounce(mdns);
  }

  void _sendWho() {
    final owner = _multicastTx;
    if (owner != null) _sendMulticast(owner, encodeWhoQuery());
  }

  void _sendMulticast(_UdpResource owner, List<int> bytes) {
    if (!_isCurrentMulticast(owner)) return;
    try {
      owner.socket.send(bytes, InternetAddress(kNearbyMulticastGroup), udpPort);
    } catch (error, stack) {
      _multicastFailed(owner, error, stack);
    }
  }

  Future<void> _startMulticastTx(
    int generation,
    NearbyWifiNetwork network,
  ) async {
    RawDatagramSocket? socket;
    try {
      socket =
          await (bindSocket?.call(0) ??
              RawDatagramSocket.bind(network.bindAddress, 0));
      if (generation != _generation || !_running) {
        socket.close();
        return;
      }
      network.bindDatagram(socket);
      socket.multicastLoopback = true;
      socket.multicastHops = 1;
      socket.readEventsEnabled = false;
      final owner = _UdpResource(generation, socket);
      _multicastTx = owner;
      owner.events = socket.listen(
        (event) {
          if (event == RawSocketEvent.closed ||
              event == RawSocketEvent.readClosed) {
            _multicastFailed(
              owner,
              const NearbyException('Multicast transmitter closed'),
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          _multicastFailed(owner, error, stack);
        },
        onDone: () {
          _multicastFailed(
            owner,
            const NearbyException('Multicast transmitter closed'),
          );
        },
      );
      _sendMulticast(
        owner,
        encodeBeacon(
          deviceId: _deviceId,
          name: _name,
          port: _httpPort,
          ips: _ips,
        ),
      );
      _sendWho();
    } catch (error, stack) {
      socket?.close();
      if (generation == _generation && _running) {
        _logOptionalFailure('multicast transmitter', error, stack);
      }
    }
  }

  void _multicastFailed(_UdpResource owner, Object error, [StackTrace? stack]) {
    if (!_isCurrentMulticast(owner)) return;
    _multicastTx = null;
    owner.socket.close();
    unawaited(owner.events.cancel());
    _logOptionalFailure('multicast transmitter', error, stack);
  }

  Future<void> _startMdnsBrowse(
    int generation,
    NearbyWifiNetwork network,
    NetworkInterface iface,
  ) async {
    final owner = _MdnsRun(generation);
    Future<RawDatagramSocket> socketFactory(
      dynamic host,
      int port, {
      bool reuseAddress = true,
      bool reusePort = true,
      int ttl = 255,
    }) async {
      final socket =
          await (bindSocket?.call(port) ??
              RawDatagramSocket.bind(
                host,
                port,
                reuseAddress: reuseAddress,
                reusePort: reusePort,
                ttl: ttl,
              ));
      try {
        if (generation != _generation ||
            !_running ||
            owner.phase == _MdnsPhase.closed) {
          throw const NearbyException('Nearby stopped');
        }
        network.bindDatagram(socket);
        owner.sockets.add(socket);
        return socket;
      } catch (_) {
        socket.close();
        rethrow;
      }
    }

    try {
      owner.client =
          createMdnsClient?.call(socketFactory) ??
          MDnsClient(rawDatagramSocketFactory: socketFactory);
    } catch (error, stack) {
      _logOptionalFailure('mDNS client', error, stack);
      return;
    }
    _mdns = owner;
    try {
      await owner.client.start(
        interfacesFactory: (_) async => [iface],
        onError: (Object error, [StackTrace? stack]) {
          _mdnsFailed(owner, error, stack);
        },
      );
      if (!_isCurrentMdns(owner) || owner.phase != _MdnsPhase.starting) {
        await _closeMdns(owner);
        return;
      }
      owner.phase = _MdnsPhase.active;
      _sendMdnsAnnounce(owner);
      if (!_isCurrentMdns(owner)) return;
      owner.browse = owner.client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('$kNearbyServiceType.local'),
          )
          .listen(
            (ptr) => _resolveMdns(owner, ptr.domainName),
            onError: (Object error, StackTrace stack) {
              _mdnsFailed(owner, error, stack);
            },
          );
    } catch (error, stack) {
      _mdnsFailed(owner, error, stack);
      await _closeMdns(owner);
    }
  }

  void _mdnsFailed(_MdnsRun owner, Object error, [StackTrace? stack]) {
    if (!_isCurrentMdns(owner)) return;
    unawaited(_closeMdns(owner));
    _logOptionalFailure('mDNS', error, stack);
  }

  Future<void> _closeMdns(_MdnsRun owner) async {
    owner.phase = _MdnsPhase.closed;
    if (identical(_mdns, owner)) _mdns = null;
    final browse = owner.browse;
    owner.browse = null;
    owner.client.stop();
    for (final socket in owner.sockets) {
      socket.close();
    }
    owner.sockets.clear();
    await browse?.cancel();
  }

  void _logOptionalFailure(
    String operation,
    Object error, [
    StackTrace? stack,
  ]) {
    developer.log(
      'Nearby $operation unavailable',
      name: 'wired_parts.nearby',
      error: error,
      stackTrace: stack,
    );
  }

  Future<void> _resolveMdns(_MdnsRun owner, String domain) async {
    if (!_isCurrentMdns(owner) || owner.phase != _MdnsPhase.active) return;
    final client = owner.client;
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
      if (!_isCurrentMdns(owner)) return;
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
      if (!_isCurrentMdns(owner)) return;
      if (host != null && host.endsWith('.local')) {
        await for (final a in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(host),
        )) {
          host = a.address.address;
          break;
        }
      }
      if (!_isCurrentMdns(owner)) return;
      if (id == null || id == _deviceId || host == null || port == 0) return;
      _remember(NearbyPeer(deviceId: id, name: name, host: host, port: port));
    } catch (error, stack) {
      _mdnsFailed(owner, error, stack);
    }
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

  void _sendMdnsAnnounce(_MdnsRun owner) {
    if (!_isCurrentMdns(owner) || owner.phase != _MdnsPhase.active) return;
    for (final socket in owner.sockets) {
      if (socket.address.type != InternetAddressType.IPv4 ||
          socket.port != 5353) {
        continue;
      }
      try {
        final packet = buildMdnsAnnouncement(
          instanceName: _safeInstance(_name, _deviceId),
          port: _httpPort,
          ipv4: _ips.single,
          deviceId: _deviceId,
          name: _name,
        );
        socket.send(packet, InternetAddress('224.0.0.251'), 5353);
      } catch (error, stack) {
        _mdnsFailed(owner, error, stack);
      }
      return;
    }
  }
}

class _UdpResource {
  _UdpResource(this.generation, this.socket);
  final int generation;
  final RawDatagramSocket socket;
  late final StreamSubscription<RawSocketEvent> events;
}

enum _MdnsPhase { starting, active, closed }

class _MdnsRun {
  _MdnsRun(this.generation);
  final int generation;
  late final MDnsClient client;
  final sockets = <RawDatagramSocket>{};
  _MdnsPhase phase = _MdnsPhase.starting;
  StreamSubscription<ResourceRecord>? browse;
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

void _putU32(BytesBuilder out, int n) =>
    out.add([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
