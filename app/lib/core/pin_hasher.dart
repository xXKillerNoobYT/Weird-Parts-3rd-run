import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

class PinHasher {
  /// Returns `saltHex:hashHex` (SHA-256 of salt+pin).
  static String hashPin(String pin, {String? saltHex}) {
    final salt = saltHex ?? _randomSalt();
    final digest = sha256.convert(utf8.encode('$salt:$pin'));
    return '$salt:${digest.toString()}';
  }

  static bool verify(String pin, String stored) {
    final parts = stored.split(':');
    if (parts.length != 2) return false;
    final again = hashPin(pin, saltHex: parts[0]);
    return again == stored;
  }

  static String _randomSalt() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
