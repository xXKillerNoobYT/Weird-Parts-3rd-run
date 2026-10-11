import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_pairing.dart';
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
  void Function()? beforeRead;

  DateTime now() {
    beforeRead?.call();
    return origin.add(elapsed);
  }

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
  final cleanup = <Future<void> Function()>[];

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
    for (final close in cleanup.reversed) {
      await close();
    }
    await Future.wait([host.dispose(), guest.dispose()]);
    await Future.wait([
      hostDiscovery.updates.close(),
      guestDiscovery.updates.close(),
    ]);
  }
}

typedef _Reply = ({int status, Map<String, Object?> body});

Future<_Reply> _post(
  HttpClient client,
  NearbyPeer peer,
  String path,
  Map<String, Object?> body,
) async {
  final request = await client.post(peer.host, peer.port, path);
  request.headers.contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();
  return (
    status: response.statusCode,
    body: Map<String, Object?>.from(
      jsonDecode(await utf8.decoder.bind(response).join()) as Map,
    ),
  );
}

class _ProtocolGuest {
  _ProtocolGuest(this.h) {
    h.cleanup.add(() async => client.close(force: true));
  }

  final _Harness h;
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  late NearbyPendingPair agreement;
  late NearbyAwaitingMatch match;

  Future<void> start() async {
    agreement = await NearbyPendingPair.create(
      NearbyPairContext(
        id: nearbyRandomId(),
        guestId: 'guest',
        guestName: 'guest',
        guestPort: h.guestDiscovery.port,
        hostId: 'host',
        hostName: 'host',
        hostPort: h.hostDiscovery.port,
      ),
      guest: true,
    );
    final reply = await _post(client, h.hostPeer, '/v2/pair/start', {
      ...agreement.context.toJson(),
      'commitment': agreement.commitment,
    });
    expect(reply.status, HttpStatus.ok);
    agreement.receiveCommitment(reply.body['commitment']);
  }

  Future<_Reply> reveal() async {
    final reply = await _post(
      client,
      h.hostPeer,
      '/v2/pair/reveal',
      agreement.reveal(),
    );
    if (reply.status == HttpStatus.ok) {
      match = await agreement.receiveReveal(reply.body);
    }
    return reply;
  }

  Future<_Reply> confirm() => _post(client, h.hostPeer, '/v2/pair/confirm', {
    'id': match.transactionId,
    'proof': match.confirmLocal(),
  });
}

class _RemoteAttempt {
  _RemoteAttempt(this.agreement);
  final NearbyPendingPair agreement;
  late NearbyAwaitingMatch match;
  final confirmed = Completer<void>();
  final headersSent = Completer<void>();
  final release = Completer<void>();
}

class _CancelledOpenClient implements HttpClient {
  Completer<HttpClientRequest>? _connecting;
  int opened = 0;
  bool closed = false;

  @override
  set findProxy(String Function(Uri)? findProxy) {}

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) {
    opened++;
    _connecting = Completer<HttpClientRequest>();
    return _connecting!.future;
  }

  @override
  void close({bool force = false}) {
    closed = true;
    _connecting?.completeError(
      const HttpException('Connection closed before request opened'),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected ${invocation.memberName}');
}

class _RemoteHost {
  _RemoteHost({this.startGate, this.stallBody = false});
  final Completer<void>? startGate;
  final bool stallBody;
  final started = Completer<void>();
  final attempts = <_RemoteAttempt>[];
  late HttpServer server;

  NearbyPeer get peer => NearbyPeer(
    deviceId: 'remote',
    name: 'remote',
    host: '127.0.0.1',
    port: server.port,
  );

  Future<void> start(_Harness h) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
    h.cleanup.add(close);
  }

  Future<void> _write(HttpRequest request, Map<String, Object?> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.add(utf8.encode(jsonEncode(body)));
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final body = Map<String, Object?>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      switch (request.uri.path) {
        case '/v2/pair/start':
          final agreement = await NearbyPendingPair.create(
            NearbyPairContext.parse(body),
            guest: false,
          );
          agreement.receiveCommitment(body['commitment']);
          attempts.add(_RemoteAttempt(agreement));
          if (!started.isCompleted) started.complete();
          await startGate?.future;
          await _write(request, {'commitment': agreement.commitment});
          return;
        case '/v2/pair/reveal':
          final attempt = attempts.last;
          final reveal = attempt.agreement.reveal();
          attempt.match = await attempt.agreement.receiveReveal(body);
          await _write(request, reveal);
          return;
        case '/v2/pair/confirm':
          final attempt = attempts.singleWhere(
            (a) => a.agreement.context.id == body['id'],
          );
          attempt.match.confirmRemote(body['proof']);
          final bytes = utf8.encode(
            jsonEncode({'proof': attempt.match.confirmLocal()}),
          );
          attempt.confirmed.complete();
          if (stallBody) {
            request.response.headers.contentType = ContentType.json;
            request.response.contentLength = bytes.length;
            request.response.bufferOutput = false;
            request.response.add(bytes.sublist(0, 1));
            await request.response.flush();
            attempt.headersSent.complete();
            await attempt.release.future;
            request.response.add(bytes.sublist(1));
          } else {
            await attempt.release.future;
            request.response.add(bytes);
          }
          await request.response.close();
          return;
        case '/v2/pair/cancel':
          await _write(request, {'ok': true});
          return;
        default:
          throw StateError('Unexpected pairing request.');
      }
    } on SocketException {
      return;
    } on HttpException {
      return;
    }
  }

  Future<void> close() async {
    if (startGate != null && !startGate!.isCompleted) startGate!.complete();
    for (final attempt in attempts) {
      if (!attempt.release.isCompleted) attempt.release.complete();
    }
    await server.close(force: true);
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
      await h.clock.elapse(
        const Duration(minutes: 4, seconds: 29, milliseconds: 999),
      );
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
    for (final millisecondsLate in [0, 1]) {
      test(
        'Match ${millisecondsLate}ms after the deadline fails with a delayed timer and hostMatched=$hostMatched',
        () => _run((h) async {
          await h.pair();
          if (hostMatched) await h.host.confirmCode();
          h.clock.elapsed = Duration(
            minutes: 5,
            milliseconds: millisecondsLate,
          );
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

  test(
    'guest deadline starts before the start reply, not at code display',
    () => _run((h) async {
      final gate = Completer<void>();
      final remote = _RemoteHost(startGate: gate);
      await remote.start(h);
      final pairing = h.guest.pair(remote.peer);
      await remote.started.future;
      await h.clock.elapse(const Duration(seconds: 15));
      gate.complete();
      await pairing;
      expect(h.guest.state.phase, NearbyPhase.pairing);
      expect(h.guest.state.verifyCode, matches(RegExp(r'^\d{6}$')));
      expect(
        h.guest.state.verificationExpiresAt,
        DateTime.utc(2026, 10, 10, 0, 5),
      );
    }),
  );

  test(
    'host reveal preserves the deadline established by start',
    () => _run((h) async {
      final guest = _ProtocolGuest(h);
      await guest.start();
      await h.clock.elapse(const Duration(seconds: 15));
      final reply = await guest.reveal();
      expect(reply.status, HttpStatus.ok);
      expect(h.host.state.verifyCode, guest.match.code);
      expect(
        h.host.state.verificationExpiresAt,
        DateTime.utc(2026, 10, 10, 0, 5),
      );
      await h.clock.elapse(const Duration(minutes: 4, seconds: 45));
      expect(h.host.state.phase, NearbyPhase.failed);
      expect(h.host.state.error, 'Pair expired. Try again.');
    }),
  );

  test(
    'host rejects reveal at the deadline while expiry callback is delayed',
    () => _run((h) async {
      final guest = _ProtocolGuest(h);
      await guest.start();
      h.clock.elapsed = const Duration(minutes: 5);
      final reply = await guest.reveal();
      expect(reply.status, HttpStatus.internalServerError);
      expect(reply.body['error'], 'Pair expired or was cancelled');
      expect(h.host.state.phase, NearbyPhase.failed);
      expect(h.host.state.error, 'Pair expired. Try again.');
      expect(h.host.state.verifyCode, isNull);
    }),
  );

  test(
    'host confirmation wait is bounded even without its expiry callback',
    () => _run((h) async {
      final guest = _ProtocolGuest(h);
      await guest.start();
      expect((await guest.reveal()).status, HttpStatus.ok);
      for (final timer in h.clock.timers.where(
        (t) => t.isActive && t.delay == const Duration(minutes: 5),
      )) {
        timer.cancel();
      }
      var settled = false;
      final confirming = guest.confirm().whenComplete(() => settled = true);
      await _until(
        () => h.clock.timers.any(
          (t) => t.isActive && t.delay == const Duration(minutes: 5),
        ),
      );
      expect(settled, isFalse);
      await h.clock.elapse(const Duration(minutes: 5));
      await _until(() => settled);
      final reply = await confirming;
      expect(reply.status, HttpStatus.internalServerError);
      expect(h.host.state.phase, NearbyPhase.failed);
      expect(h.host.state.error, 'Pair expired. Try again.');
      expect(h.applied, 0);
    }),
  );

  test(
    'host rejects a late remote Match even after its own early Match',
    () => _run((h) async {
      final guest = _ProtocolGuest(h);
      await guest.start();
      expect((await guest.reveal()).status, HttpStatus.ok);
      await h.host.confirmCode();
      h.clock.elapsed = const Duration(minutes: 5);
      final reply = await guest.confirm();
      expect(reply.status, HttpStatus.internalServerError);
      expect(reply.body['error'], 'Pair expired or was cancelled');
      expect(h.host.state.phase, NearbyPhase.failed);
      expect(h.host.state.error, 'Pair expired. Try again.');
      expect(h.host.state.pairedPeer, isNull);
    }),
  );

  test(
    'cancel closes a held confirmation and late reply cannot damage a replacement',
    () => _run((h) async {
      final remote = _RemoteHost();
      await remote.start(h);
      await h.guest.pair(remote.peer);
      final oldId = h.guest.state.verificationAttemptId;
      var settled = false;
      final confirming = h.guest.confirmCode().whenComplete(
        () => settled = true,
      );
      await remote.attempts.first.confirmed.future;
      await h.guest.rejectCode();
      await _until(() => settled);
      await confirming;
      expect(h.guest.state.phase, NearbyPhase.looking);
      await h.guest.pair(remote.peer);
      final replacementId = h.guest.state.verificationAttemptId;
      expect(replacementId, isNot(oldId));
      remote.attempts.first.release.complete();
      await _pump();
      expect(h.guest.state.phase, NearbyPhase.pairing);
      expect(h.guest.state.verificationAttemptId, replacementId);
      final replacement = h.guest.confirmCode();
      await remote.attempts.last.confirmed.future;
      remote.attempts.last.release.complete();
      await replacement;
      expect(h.guest.state.phase, NearbyPhase.paired);
      expect(h.guest.state.pairedPeer?.deviceId, 'remote');
      expect(h.applied, 0);
      expect(h.collected, 0);
    }),
  );

  test(
    'late valid confirmation response cannot pair after the absolute deadline',
    () => _run((h) async {
      final remote = _RemoteHost();
      await remote.start(h);
      await h.guest.pair(remote.peer);
      final confirming = h.guest.confirmCode();
      await remote.attempts.first.confirmed.future;
      h.clock.elapsed = const Duration(minutes: 5);
      remote.attempts.first.release.complete();
      await confirming;
      expect(h.guest.state.phase, NearbyPhase.failed);
      expect(h.guest.state.error, 'Pair expired. Try again.');
      expect(h.guest.state.pairedPeer, isNull);
      expect(h.applied, 0);
    }),
  );

  test(
    'deadline crossing after Match admission does not abandon a connection Future',
    () => _run((h) async {
      await h.pair();
      var clockReads = 0;
      h.clock.beforeRead = () {
        if (++clockReads == 2) {
          h.clock.elapsed = const Duration(minutes: 5);
        }
      };
      late _CancelledOpenClient client;
      final unhandled = <Object>[];
      final settled = Completer<void>();
      runZonedGuarded(() async {
        try {
          await HttpOverrides.runZoned(
            h.guest.confirmCode,
            createHttpClient: (_) => client = _CancelledOpenClient(),
          );
          settled.complete();
        } catch (error, stack) {
          settled.completeError(error, stack);
        }
      }, (error, _) => unhandled.add(error));
      await settled.future;
      h.clock.beforeRead = null;
      await _pump();
      expect(h.guest.state.phase, NearbyPhase.failed);
      expect(h.guest.state.error, 'Pair expired. Try again.');
      expect(h.guest.state.pairedPeer, isNull);
      expect(client.closed, isTrue);
      expect(unhandled, isEmpty);
      expect(client.opened, 0);
      expect(h.applied, 0);
      expect(h.collected, 0);
    }),
  );

  for (final startAt in [
    const Duration(minutes: 1),
    const Duration(minutes: 4, seconds: 50),
  ]) {
    test(
      'confirmation body retains the twenty-second cap or remaining deadline at $startAt',
      () => _run((h) async {
        final remote = _RemoteHost(stallBody: true);
        await remote.start(h);
        await h.guest.pair(remote.peer);
        await h.clock.elapse(startAt);
        for (final timer in h.clock.timers.where(
          (t) => t.isActive && t.delay == const Duration(minutes: 5),
        )) {
          timer.cancel();
        }
        var settled = false;
        final confirming = h.guest.confirmCode().whenComplete(
          () => settled = true,
        );
        await remote.attempts.first.headersSent.future;
        await _pump();
        final budget = startAt.inMinutes == 1
            ? const Duration(seconds: 20)
            : const Duration(seconds: 10);
        await h.clock.elapse(budget - const Duration(milliseconds: 1));
        expect(settled, isFalse);
        expect(h.guest.state.phase, NearbyPhase.pairing);
        await h.clock.elapse(const Duration(milliseconds: 1));
        await _until(() => settled);
        await confirming;
        expect(h.guest.state.phase, NearbyPhase.failed);
        expect(h.guest.state.pairedPeer, isNull);
        expect(h.applied, 0);
      }),
    );
  }

  test(
    'guest wait uses remaining window even with its expiry callback withheld',
    () => _run((h) async {
      final remote = _RemoteHost();
      await remote.start(h);
      await h.guest.pair(remote.peer);
      await h.clock.elapse(const Duration(minutes: 4));
      for (final timer in h.clock.timers.where(
        (t) => t.isActive && t.delay == const Duration(minutes: 5),
      )) {
        timer.cancel();
      }
      var settled = false;
      final confirming = h.guest.confirmCode().whenComplete(
        () => settled = true,
      );
      await remote.attempts.first.confirmed.future;
      await h.guest.confirmCode();
      expect(
        h.guest.state.verificationExpiresAt,
        DateTime.utc(2026, 10, 10, 0, 5),
      );
      await h.clock.elapse(const Duration(seconds: 59));
      expect(settled, isFalse);
      await h.clock.elapse(const Duration(seconds: 1));
      await _until(() => settled);
      await confirming;
      expect(h.guest.state.phase, NearbyPhase.failed);
      expect(h.guest.state.error, 'Pair expired. Try again.');
    }),
  );
}
