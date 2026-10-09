import 'dart:async';
import 'dart:convert';

import 'native_nearby_test_commands.dart';
import 'native_nearby_test_crypto.dart';

final class NativeTestResidentViewInfo {
  const NativeTestResidentViewInfo({
    required this.phase,
    required this.sameNearbyState,
    required this.discovered,
    required this.codePresent,
  });
  final NativeTestPhase phase;
  final bool sameNearbyState, discovered, codePresent;
}

final class NativeTestResidentRpc {
  NativeTestResidentRpc({
    required this.appPid,
    required this.run,
    required this.role,
    required this.deviceId,
    required this.peerId,
    required this.clockMillis,
    required this.readInfoInLoop,
  });

  final int appPid;
  final String run, deviceId, peerId;
  final TestRole role;
  final int Function() clockMillis;
  final NativeTestResidentViewInfo Function() readInfoInLoop;
  NativeTestResidentViewInfo? _published;
  _PendingConfiguration? _pending;
  bool _configureAttempted = false;
  bool _configured = false;
  bool _closed = false;

  // Only the resident loop may read widget state. Extension callbacks consume
  // an immutable summary, including while an awaited pump owns a guard scope.
  void refreshInfoInLoop() {
    if (!_closed) _published = readInfoInLoop();
  }

  Map<String, Object> info() {
    final current = _published;
    if (_closed || current == null) {
      return {'version': 1, 'outcome': 'not-ready'};
    }
    return {
      'version': 1,
      'outcome': 'ready',
      'appPid': appPid,
      'run': run,
      'role': role.name,
      'deviceId': deviceId,
      'peerId': peerId,
      'configured': _configured,
      'elapsedMillis': clockMillis(),
      'phase': current.phase.name,
      'sameNearbyState': current.sameNearbyState,
      'discovered': current.discovered,
      'codePresent': current.codePresent,
    };
  }

  Future<Map<String, Object>> configure(String data) {
    try {
      if (_closed ||
          _configureAttempted ||
          data.length > nativeTestMaxEnvelopeBytes ||
          utf8.encode(data).length > nativeTestMaxEnvelopeBytes) {
        return Future.value(_configurationReply(false));
      }
      final next = TestSession.fromJson(jsonDecode(data));
      if (next.run != run ||
          next.role != role ||
          next.deviceId != deviceId ||
          next.peerId != peerId) {
        return Future.value(_configurationReply(false));
      }
      // Once accepted, a lost reply or an expired request cannot authorize a
      // second configuration, even when the original was never installed.
      _configureAttempted = true;
      final pending = _PendingConfiguration(next, clockMillis() + 3000);
      _pending = pending;
      pending.timer = Timer(const Duration(seconds: 3), () {
        if (identical(_pending, pending)) {
          _pending = null;
          pending.complete(false);
        }
      });
      return pending.reply.future;
    } catch (_) {
      return Future.value(_configurationReply(false));
    }
  }

  // The installer performs fresh widget/device checks and commits all resident
  // fields without awaiting. No extension callback invokes this method.
  void processConfigurationInLoop(void Function(TestSession) install) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    pending.timer?.cancel();
    if (_closed || clockMillis() >= pending.expiresAtMillis) {
      pending.complete(false);
      return;
    }
    try {
      install(pending.session);
      _configured = true;
      pending.complete(true);
    } catch (_) {
      pending.complete(false);
    }
  }

  void close() {
    _closed = true;
    _published = null;
    final pending = _pending;
    _pending = null;
    pending?.complete(false);
  }
}

Map<String, Object> _configurationReply(bool installed) => {
  'version': 1,
  'outcome': installed ? 'configured' : 'rejected',
};

final class _PendingConfiguration {
  _PendingConfiguration(this.session, this.expiresAtMillis);
  final TestSession session;
  final int expiresAtMillis;
  final reply = Completer<Map<String, Object>>();
  Timer? timer;

  void complete(bool installed) {
    timer?.cancel();
    if (!reply.isCompleted) reply.complete(_configurationReply(installed));
  }
}
