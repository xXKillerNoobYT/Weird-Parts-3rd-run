import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

class _ScheduledTimer implements Timer {
  _ScheduledTimer(this.clock, this.zone, this.delay, this.callback)
    : due = clock.elapsed + delay;

  final _Clock clock;
  final Zone zone;
  final Duration delay;
  final Duration due;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;

  void fire({bool retained = false}) {
    if (!_active && !retained) return;
    _active = false;
    _tick++;
    zone.runGuarded(callback);
  }
}

class _Clock {
  final origin = DateTime.utc(2026, 10, 10);
  Duration elapsed = Duration.zero;
  final timers = <_ScheduledTimer>[];

  DateTime now() => origin.add(elapsed);

  Future<void> run(Future<void> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = _ScheduledTimer(this, zone, duration, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );

  Future<void> elapse(Duration duration) async {
    final target = elapsed + duration;
    while (true) {
      final ready =
          timers
              .where((timer) => timer.isActive && timer.due <= target)
              .toList()
            ..sort((a, b) => a.due.compareTo(b.due));
      if (ready.isEmpty) break;
      final timer = ready.first;
      elapsed = timer.due;
      timer.fire();
      await _pump();
    }
    elapsed = target;
    await _pump();
  }
}

Future<void> _pump() async {
  for (var i = 0; i < 8; i++) {
    await Zone.root.run(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await _pump();
  }
  expect(ready(), isTrue, reason: 'The loopback operation did not settle.');
}

class _Discovery implements NearbyDiscovery {
  final updates = StreamController<List<NearbyPeer>>.broadcast();
  int port = 0;

  @override
  Stream<List<NearbyPeer>> get peers => updates.stream;

  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) async => this.port = port;

  @override
  Future<void> stop() async {}

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {}
}

class _Harness {
  _Harness(this.clock) {
    host = _controller('host', hostDiscovery);
    guest = _controller('guest', guestDiscovery);
  }

  final _Clock clock;
  final hostDiscovery = _Discovery();
  final guestDiscovery = _Discovery();
  late final NearbyController host;
  late final NearbyController guest;
  int collected = 0;
  int applied = 0;

  NearbyController _controller(String id, _Discovery discovery) =>
      NearbyController(
        deviceId: id,
        deviceName: id,
        discovery: discovery,
        bindAddress: InternetAddress.loopbackIPv4,
        localIps: () async => ['127.0.0.1'],
        now: clock.now,
        collectPayload: () async {
          collected++;
          throw StateError('Pairing must not collect a shop.');
        },
        applyPayload: (_) async => applied++,
      );

  NearbyPeer get hostPeer => NearbyPeer(
    deviceId: 'host',
    name: 'host',
    host: '127.0.0.1',
    port: hostDiscovery.port,
  );

  Future<void> pair() async {
    await guest.pair(hostPeer);
    expect(host.state.phase, NearbyPhase.pairing);
    expect(guest.state.phase, NearbyPhase.pairing);
    expect(host.state.verifyCode, matches(RegExp(r'^\d{6}$')));
    expect(guest.state.verifyCode, host.state.verifyCode);
  }

  void expectPaired() {
    expect(host.state.phase, NearbyPhase.paired);
    expect(guest.state.phase, NearbyPhase.paired);
    expect(host.state.pairedPeer?.deviceId, 'guest');
    expect(guest.state.pairedPeer?.deviceId, 'host');
    expect(collected, 0);
    expect(applied, 0);
  }

  Future<void> close() async {
    await Future.wait([host.dispose(), guest.dispose()]);
    await Future.wait([
      hostDiscovery.updates.close(),
      guestDiscovery.updates.close(),
    ]);
  }
}

Future<void> _run(Future<void> Function(_Harness h) body) {
  final clock = _Clock();
  return clock.run(() async {
    final h = _Harness(clock);
    try {
      await h.host.start();
      await h.guest.start();
      await body(h);
    } finally {
      await h.close();
    }
  });
}

void main() {
  test(
    'both roles keep the original five-minute deadline through state updates',
    () => _run((h) async {
      await h.pair();
      final deadline = DateTime.utc(2026, 10, 10, 0, 5);
      expect(h.host.state.verificationExpiresAt, deadline);
      expect(h.guest.state.verificationExpiresAt, deadline);
      await h.clock.elapse(const Duration(seconds: 30));
      await h.host.confirmCode();
      await h.host.confirmCode();
      h.hostDiscovery.updates.add([h.hostPeer]);
      h.guestDiscovery.updates.add([h.hostPeer]);
      await _pump();
      expect(h.host.state.verificationExpiresAt, deadline);
      expect(h.guest.state.verificationExpiresAt, deadline);
      await h.clock.elapse(const Duration(minutes: 4, seconds: 29));
      await h.guest.confirmCode();
      h.expectPaired();
    }),
  );

  test(
    'host may Match first and guest may Match after two minutes',
    () => _run((h) async {
      await h.pair();
      await h.host.confirmCode();
      await h.clock.elapse(const Duration(minutes: 3));
      expect(h.host.state.phase, NearbyPhase.pairing);
      expect(h.guest.state.phase, NearbyPhase.pairing);
      await h.guest.confirmCode();
      h.expectPaired();
    }),
  );

  test(
    'guest confirmation HTTP wait survives two minutes and ends before five',
    () => _run((h) async {
      await h.pair();
      var settled = false;
      final confirming = h.guest.confirmCode().whenComplete(
        () => settled = true,
      );
      await _pump();
      expect(settled, isFalse);
      await h.clock.elapse(const Duration(minutes: 3));
      expect(settled, isFalse);
      expect(h.guest.state.phase, NearbyPhase.pairing);
      await h.host.confirmCode();
      await _until(() => settled);
      await confirming;
      h.expectPaired();
    }),
  );

  for (final hostMatched in [false, true]) {
    test(
      'Match at the deadline fails with a delayed timer and hostMatched=$hostMatched',
      () => _run((h) async {
        await h.pair();
        if (hostMatched) await h.host.confirmCode();
        h.clock.elapsed = const Duration(minutes: 5);
        await h.host.confirmCode();
        await h.guest.confirmCode();
        expect(h.host.state.phase, NearbyPhase.failed);
        expect(h.guest.state.phase, NearbyPhase.failed);
        expect(h.host.state.error, 'Pair expired. Try again.');
        expect(h.guest.state.error, 'Pair expired. Try again.');
        expect(h.applied, 0);
        expect(h.collected, 0);
      }),
    );
  }

  test(
    'expiry is finite at five minutes even when the wall clock moves back',
    () => _run((h) async {
      await h.pair();
      final pairTimers = h.clock.timers
          .where(
            (timer) =>
                timer.isActive && timer.delay == const Duration(minutes: 5),
          )
          .toList();
      expect(pairTimers.length, 2);
      h.clock.elapsed = const Duration(minutes: -1);
      for (final timer in pairTimers) {
        timer.fire();
      }
      expect(h.host.state.phase, NearbyPhase.failed);
      expect(h.guest.state.phase, NearbyPhase.failed);
      expect(h.host.state.error, 'Pair expired. Try again.');
      expect(h.guest.state.error, 'Pair expired. Try again.');
    }),
  );

  test(
    'cancelling a waiting confirmation settles it and preserves a replacement',
    () => _run((h) async {
      await h.pair();
      final oldId = h.guest.state.verificationAttemptId;
      final oldTimers = h.clock.timers
          .where(
            (timer) =>
                timer.isActive && timer.delay == const Duration(minutes: 5),
          )
          .toList();
      var settled = false;
      final confirming = h.guest.confirmCode().whenComplete(
        () => settled = true,
      );
      await _pump();
      await h.guest.rejectCode();
      await _until(() => settled);
      await confirming;
      await h.pair();
      expect(h.guest.state.verificationAttemptId, isNot(oldId));
      final newId = h.guest.state.verificationAttemptId;
      for (final timer in oldTimers) {
        timer.fire(retained: true);
      }
      await _pump();
      expect(h.guest.state.verificationAttemptId, newId);
      expect(h.host.state.verificationAttemptId, newId);
      await h.host.confirmCode();
      await h.guest.confirmCode();
      h.expectPaired();
      for (final timer in oldTimers) {
        timer.fire(retained: true);
      }
      await _pump();
      h.expectPaired();
    }),
  );
}
