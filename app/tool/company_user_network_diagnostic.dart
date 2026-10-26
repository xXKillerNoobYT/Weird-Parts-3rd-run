import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';

final class CompanyUserNetworkDiagnostic {
  CompanyUserNetworkDiagnostic({
    required this.enabled,
    required this.run,
    required this._record,
  });

  final bool enabled;
  final String run;
  final void Function(Map<String, Object?>) _record;
  static const _channel = MethodChannel('wired_parts/nearby_wifi');
  (int, int)? _room;
  _DiagnosticTarget? _candidate;
  ({String id, _DiagnosticTarget target})? _active;
  bool _spent = false;
  bool _closed = false;

  void observe(NearbyTransportObservation event) {
    if (!enabled || _closed) return;
    final controller = event.controller;
    final generation = event.generation;
    if (controller == null || generation == null) return;
    final room = (controller, generation);
    if (event.operation == NearbyTransportOperation.room) {
      if (event.stage == NearbyTransportStage.listenerBound) {
        if (_room != room) {
          unawaited(_cancel());
          _candidate = null;
          _room = room;
        }
      } else if (_room == room &&
          {
            NearbyTransportStage.stopping,
            NearbyTransportStage.stopped,
            NearbyTransportStage.listenerDone,
            NearbyTransportStage.listenerError,
            NearbyTransportStage.discoveryError,
          }.contains(event.stage)) {
        _room = null;
        _candidate = null;
        unawaited(_cancel());
      }
      return;
    }
    if (_spent ||
        _room != room ||
        event.stage != NearbyTransportStage.tcpStart) {
      return;
    }
    final target = _DiagnosticTarget.from(event);
    if (event.failure == null) {
      _candidate = target;
      return;
    }
    if (target == null ||
        _candidate?.arguments != target.arguments ||
        !{
          NearbyTransportFailure.socket,
          NearbyTransportFailure.operatingSystem,
        }.contains(event.failure)) {
      return;
    }
    _spent = true;
    final attempt = (id: const Uuid().v4(), target: target);
    _active = attempt;
    unawaited(_run(attempt));
  }

  Future<void> _run(({String id, _DiagnosticTarget target}) attempt) async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>('diagnoseLocalTcp', {
            'attempt': attempt.id,
            'run': run,
            ...attempt.target.toJson(),
          })
          .timeout(const Duration(seconds: 11));
      if (_active != attempt || _closed) return;
      final result = _parse(raw, attempt);
      if (result == null) {
        _write(attempt.target, {'outcome': 'invalidResponse', 'elapsedMs': 0});
      } else {
        for (final event in result.events) {
          _write(attempt.target, event);
        }
        _write(attempt.target, {
          'outcome': result.outcome,
          'elapsedMs': result.events.lastOrNull?['elapsedMs'] ?? 0,
        });
        _active = null;
      }
    } catch (error) {
      if (_active == attempt && !_closed) {
        _write(attempt.target, {
          'outcome': switch (error) {
            TimeoutException() => 'timedOut',
            PlatformException(
              code: 'diagnostic_refused' || 'diagnostic_arguments',
            ) =>
              'rejected',
            _ => 'unavailable',
          },
          'elapsedMs': error is TimeoutException ? 10000 : 0,
        });
      }
    } finally {
      if (_active == attempt) await _cancel();
    }
  }

  void _write(_DiagnosticTarget target, Map<String, Object?> event) {
    try {
      _record({
        'kind': 'company-user-local-network@1',
        'observedUtc': DateTime.now().toUtc().toIso8601String(),
        'controller': target.controller,
        'generation': target.generation,
        'request': target.request,
        ...event,
      });
    } catch (_) {}
  }

  static ({String outcome, List<Map<String, Object?>> events})? _parse(
    Object? raw,
    ({String id, _DiagnosticTarget target}) attempt,
  ) {
    if (raw is! Map ||
        raw.length != 6 ||
        raw['controller'] is! int ||
        raw['generation'] is! int ||
        raw['request'] is! int ||
        raw['attempt'] != attempt.id ||
        raw['controller'] != attempt.target.controller ||
        raw['generation'] != attempt.target.generation ||
        raw['request'] != attempt.target.request ||
        !{
          'ready',
          'failed',
          'timedOut',
          'cancelled',
        }.contains(raw['outcome']) ||
        raw['events'] is! List ||
        (raw['events'] as List).length > 8) {
      return null;
    }
    final events = <Map<String, Object?>>[];
    var previous = 0;
    for (final event in raw['events'] as List) {
      if (event is! Map ||
          event.length != 7 ||
          !event.containsKey('code') ||
          !{
            'setup',
            'preparing',
            'waiting',
            'ready',
            'failed',
            'cancelled',
            'unknown',
          }.contains(event['state']) ||
          !{
            'satisfied',
            'unsatisfied',
            'requiresConnection',
            'unavailable',
            'other',
          }.contains(event['path']) ||
          !{
            'none',
            'notAvailable',
            'cellularDenied',
            'wifiDenied',
            'localNetworkDenied',
            'unavailable',
            'other',
          }.contains(event['reason']) ||
          !{'none', 'posix', 'dns', 'tls', 'other'}.contains(event['domain']) ||
          (event['code'] != null &&
              (event['code'] is! int ||
                  (event['code'] as int).abs() > 2147483647)) ||
          event['elapsedMs'] is! int ||
          (event['elapsedMs'] as int) < previous ||
          (event['elapsedMs'] as int) > 10000 ||
          event['observedUtc'] is! String ||
          (event['observedUtc'] as String).length > 30 ||
          DateTime.tryParse(event['observedUtc'] as String)?.isUtc != true) {
        return null;
      }
      previous = event['elapsedMs'] as int;
      events.add(Map<String, Object?>.from(event));
    }
    return (outcome: raw['outcome'] as String, events: events);
  }

  Future<void> _cancel() async {
    final active = _active;
    _active = null;
    if (active == null) return;
    try {
      await _channel.invokeMethod<void>('cancelLocalTcpDiagnostic', {
        'attempt': active.id,
      });
    } catch (_) {}
  }

  Future<void> cancelController(int? controller) async {
    if (controller != null && _active?.target.controller == controller) {
      await _cancel();
    }
  }

  Future<void> close() async {
    _closed = true;
    _room = null;
    _candidate = null;
    await _cancel();
  }
}

final class _DiagnosticTarget {
  _DiagnosticTarget(this.arguments);
  final ({
    int controller,
    int generation,
    int request,
    String address,
    int port,
    String sourceAddress,
    int interfaceIndex,
    int prefixLength,
  })
  arguments;
  int get controller => arguments.controller;
  int get generation => arguments.generation;
  int get request => arguments.request;

  static _DiagnosticTarget? from(NearbyTransportObservation event) {
    final controller = event.controller;
    final generation = event.generation;
    final source = event.sourceAddress;
    final index = event.sourceInterfaceIndex;
    final prefix = event.sourcePrefixLength;
    if (controller == null ||
        generation == null ||
        source == null ||
        index == null ||
        prefix == null ||
        [
          controller,
          generation,
          event.request,
          index,
        ].any((n) => n < 1 || n > 2147483647) ||
        event.peerPort < 1 ||
        event.peerPort > 65535 ||
        event.factoryAddress != event.peerAddress ||
        event.factoryPort != event.peerPort) {
      return null;
    }
    try {
      final wifi = NearbyWifiNetwork(
        name: 'validation',
        index: index,
        address: source,
        prefixLength: prefix,
      );
      if (!wifi.allowsPeer(event.peerAddress)) return null;
      return _DiagnosticTarget((
        controller: controller,
        generation: generation,
        request: event.request,
        address: event.peerAddress,
        port: event.peerPort,
        sourceAddress: source,
        interfaceIndex: index,
        prefixLength: prefix,
      ));
    } on NearbyException {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'controller': controller,
    'generation': generation,
    'request': request,
    'address': arguments.address,
    'port': arguments.port,
    'sourceAddress': arguments.sourceAddress,
    'interfaceIndex': arguments.interfaceIndex,
    'prefixLength': arguments.prefixLength,
  };
}
