import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const kNearbyServiceType = '_wiredpart._tcp';
/// Shared Mac/Windows UDP beacon port. Not 45454: Windows (Hyper-V/WinNAT-style)
/// reserves ~44700–48799 on Impure even when `netsh excludedportrange` is empty.
const kNearbyUdpPort = 41000;
const kNearbyMulticastGroup = '239.55.12.42';
const kNearbyProto = 'wiredpart-link';
const kNearbyProtoVersion = 1;
const kNearbyTransferMagic = [0x57, 0x50, 0x4c, 0x31]; // WPL1
const kMaxNearbyTransferBytes = 512 * 1024 * 1024;
const kLastNearbyAtKey = 'last_nearby_at';
const kLastNearbyPeerKey = 'last_nearby_peer';

class NearbyException implements Exception {
  const NearbyException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NearbyPeer {
  const NearbyPeer({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
  });

  final String deviceId;
  final String name;
  final String host;
  final int port;

  String get label => name.trim().isEmpty ? 'WiredPart ${shortId(deviceId)}' : name;

  NearbyPeer copyWith({String? host, int? port, String? name}) => NearbyPeer(
    deviceId: deviceId,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
  );

  @override
  bool operator ==(Object other) =>
      other is NearbyPeer &&
      other.deviceId == deviceId &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(deviceId, host, port);
}

class NearbyOffer {
  const NearbyOffer({
    required this.sourceDeviceId,
    required this.sourceName,
    required this.jobs,
    required this.parts,
    required this.photos,
    required this.bytes,
  });

  final String sourceDeviceId;
  final String sourceName;
  final int jobs;
  final int parts;
  final int photos;
  final int bytes;

  String get summary {
    final size = bytes < 1024 * 1024
        ? '${(bytes / 1024).ceil()} KB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '$jobs jobs, $parts parts, $photos photos ($size)';
  }
}

String shortId(String deviceId) {
  final compact = deviceId.replaceAll('-', '');
  if (compact.length < 4) return compact;
  return compact.substring(compact.length - 4);
}

String defaultNearbyName(String deviceId) => 'WiredPart ${shortId(deviceId)}';

int pairingVerifyCode({
  required List<int> hostSecret,
  required String guestDeviceId,
  required List<int> guestNonce,
  required List<int> hostNonce,
}) {
  final digest = Hmac(sha256, hostSecret)
      .convert([...utf8.encode(guestDeviceId), ...guestNonce, ...hostNonce])
      .bytes;
  final n =
      ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) &
      0x7fffffff;
  return 100000 + n % 900000;
}

String pairingSessionToken({
  required List<int> hostSecret,
  required String guestDeviceId,
  required List<int> guestNonce,
  required List<int> hostNonce,
}) {
  return Hmac(sha256, hostSecret)
      .convert(
        utf8.encode(
          'token|$guestDeviceId|${base64Encode(guestNonce)}|${base64Encode(hostNonce)}',
        ),
      )
      .toString();
}

Uint8List sessionAesKey(String token) {
  return Uint8List.fromList(sha256.convert(utf8.encode('wpl1|$token')).bytes);
}

Map<String, Object?> decodeBeacon(List<int> bytes) {
  final Object? decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw const NearbyException('Damaged nearby beacon');
  }
  return Map<String, Object?>.from(decoded);
}

List<int> encodeBeacon({
  required String deviceId,
  required String name,
  required int port,
  required List<String> ips,
}) {
  return utf8.encode(
    jsonEncode({
      'v': kNearbyProtoVersion,
      'kind': 'wiredpart',
      'proto': kNearbyProto,
      'id': deviceId,
      'name': name,
      'port': port,
      'ips': ips,
    }),
  );
}

List<int> encodeWhoQuery() {
  return utf8.encode(
    jsonEncode({
      'v': kNearbyProtoVersion,
      'kind': 'wiredpart-who',
    }),
  );
}

NearbyPeer? peerFromBeacon(
  Map<String, Object?> map, {
  String? fromHost,
}) {
  if (map['kind'] != 'wiredpart') return null;
  if (map['proto'] != kNearbyProto) return null;
  if (map['v'] != kNearbyProtoVersion) return null;
  final id = map['id'] as String?;
  final name = map['name'] as String? ?? '';
  final port = map['port'];
  if (id == null || id.isEmpty || port is! int || port <= 0 || port > 65535) {
    return null;
  }
  final ips = <String>[];
  final rawIps = map['ips'];
  if (rawIps is List) {
    for (final ip in rawIps) {
      if (ip is String && ip.isNotEmpty) ips.add(ip);
    }
  }
  final host = ips.isNotEmpty ? ips.first : fromHost;
  if (host == null || host.isEmpty) return null;
  return NearbyPeer(deviceId: id, name: name, host: host, port: port);
}

bool isWhoQuery(Map<String, Object?> map) => map['kind'] == 'wiredpart-who';
