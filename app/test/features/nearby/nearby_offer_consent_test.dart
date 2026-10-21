import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/nearby/nearby_codec.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_page.dart';
import 'package:wired_parts/features/nearby/nearby_pairing.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../backup/backup_test_support.dart';

void main() {
  testWidgets('expired offer clears actions and fresh pairing permits retry', (
    tester,
  ) async {
    final h = await _Harness.open(tester);
    final a = await h.offer(tester, 'A');
    await tester.runAsync(() => h.clock.elapse(const Duration(minutes: 2)));
    expect(
      (await tester.runAsync(() => a.reply))!.status,
      HttpStatus.forbidden,
    );
    await tester.pumpAndSettle();
    expect(h.receiver.state.incoming, isNull);
    expect(h.receiver.state.phase, isNot(NearbyPhase.offering));
    expect(find.widgetWithText(FilledButton, 'Accept shop'), findsNothing);
    h.expectUnchanged();
    await tester.runAsync(h.peer.pair);
    final b = await h.offer(tester, 'B');
    await h.acceptCurrent(tester);
    await h.expectTransferred(tester, b);
  });

  for (final replacement in [
    'expiry',
    'session',
    'page owner',
    'controller stop',
  ]) {
    for (final confirm in [false, true]) {
      testWidgets(
        'late A ${confirm ? 'confirmation' : 'cancel'} cannot decide B after $replacement',
        (tester) async {
          final h = await _Harness.open(tester);
          final a = await h.offer(tester, 'A');
          await tester.tap(find.widgetWithText(FilledButton, 'Accept shop'));
          await tester.pumpAndSettle();
          expect(find.text('Accept this shop?'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('inventory and its history'),
            ),
            findsOneWidget,
          );
          expect(find.textContaining('from Sender A'), findsWidgets);
          if (replacement == 'expiry') {
            await tester.runAsync(
              () => h.clock.elapse(const Duration(minutes: 2)),
            );
          } else if (replacement == 'controller stop') {
            await tester.runAsync(h.receiver.stop);
            await tester.runAsync(() => h.clock.run(h.receiver.start));
            await tester.runAsync(h.peer.pair);
          } else {
            await tester.runAsync(h.peer.cancel);
            await tester.runAsync(h.peer.pair);
          }
          await tester.runAsync(() async {
            try {
              expect((await a.reply).status, HttpStatus.forbidden);
            } on HttpException {
              expect(replacement, 'controller stop');
            }
          });
          final b = await h.offer(tester, 'B');
          if (replacement == 'page owner') {
            h.revision.value++;
            await tester.pumpAndSettle();
          }
          await tester.tap(
            find.widgetWithText(TextButton, confirm ? 'Accept shop' : 'Cancel'),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(_pump);
          expect(h.receiver.state.phase, NearbyPhase.offering);
          expect(h.receiver.state.incoming?.sourceName, 'Sender B');
          expect(b.completed, isFalse);
          expect(
            (await tester.runAsync(b.transfer))!.status,
            HttpStatus.forbidden,
          );
          h.expectUnchanged();
          await h.acceptCurrent(tester);
          await h.expectTransferred(tester, b);
        },
      );
    }
  }

  testWidgets('company Join still refuses whole-shop offers and transfers', (
    tester,
  ) async {
    final h = await _Harness.open(tester, companyJoin: true);
    final request = (await tester.runAsync(() => h.peer.offer('A')))!;
    expect(
      (await tester.runAsync(() => request.reply))!.status,
      isNot(HttpStatus.ok),
    );
    expect(
      (await tester.runAsync(request.transfer))!.status,
      isNot(HttpStatus.ok),
    );
    expect(h.receiver.state.incoming, isNull);
    expect(h.receiver.state.phase, NearbyPhase.paired);
    h.expectUnchanged();
  });

  for (final confirm in [false, true]) {
    testWidgets(
      'disposed controller ignores late ${confirm ? 'confirmation' : 'cancel'}',
      (tester) async {
        final h = await _Harness.open(tester);
        await h.offer(tester, 'A');
        await tester.tap(find.widgetWithText(FilledButton, 'Accept shop'));
        await tester.pumpAndSettle();
        expect(find.text('Accept this shop?'), findsOneWidget);
        await tester.runAsync(h.receiver.dispose);
        await tester.tap(
          find.widgetWithText(TextButton, confirm ? 'Accept shop' : 'Cancel'),
        );
        await tester.pumpAndSettle();
        expect(h.receiver.state.phase, NearbyPhase.idle);
        expect(h.receiver.state.incoming, isNull);
        h.expectUnchanged();
      },
    );
  }

  testWidgets('late PIN for A cannot open confirmation for B', (tester) async {
    final h = await _Harness.open(tester, withPin: true);
    final a = await h.offer(tester, 'A');
    await tester.tap(find.widgetWithText(FilledButton, 'Accept shop'));
    await tester.pumpAndSettle();
    expect(find.text('Editor PIN'), findsOneWidget);
    await tester.runAsync(() => h.clock.elapse(const Duration(minutes: 2)));
    expect(
      (await tester.runAsync(() => a.reply))!.status,
      HttpStatus.forbidden,
    );
    final b = await h.offer(tester, 'B');
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Accept this shop?'), findsNothing);
    expect(b.completed, isFalse);
    expect((await tester.runAsync(b.transfer))!.status, HttpStatus.forbidden);
    h.expectUnchanged();
    h.pin.lock();
    await h.acceptCurrent(tester, requirePin: true);
    await h.expectTransferred(tester, b);
  });

  for (final atDeadline in [false, true]) {
    testWidgets(
      'offer decision ${atDeadline ? 'at' : 'just before'} deadline with delayed timer',
      (tester) async {
        final h = await _Harness.open(tester);
        final a = await h.offer(tester, 'A');
        h.clock.elapsed += atDeadline
            ? const Duration(minutes: 2)
            : const Duration(minutes: 1, seconds: 59, milliseconds: 999);
        await tester.tap(find.widgetWithText(FilledButton, 'Accept shop'));
        await tester.pumpAndSettle();
        if (atDeadline) {
          expect(find.text('Accept this shop?'), findsNothing);
          expect(
            (await tester.runAsync(a.transfer))!.status,
            HttpStatus.forbidden,
          );
          h.expectUnchanged();
        } else {
          await tester.tap(find.widgetWithText(TextButton, 'Accept shop'));
          await tester.pumpAndSettle();
          await h.expectTransferred(tester, a);
        }
      },
    );
  }
}

typedef _Reply = ({int status, Map<String, dynamic> body});

class _Harness {
  _Harness(this.directory, this.original, this.senderBytes);
  final Directory directory;
  final Uint8List original;
  final Uint8List senderBytes;
  final clock = _Clock();
  final discovery = _Discovery();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  late final pin = PinService(db.settingsDao);
  final revision = ValueNotifier(0);
  final applied = <BackupPayload>[];
  late final NearbyController receiver;
  late final _ControlledPeer peer;
  File get shop => File(p.join(directory.path, 'shop.sqlite'));
  File get photo => File(p.join(directory.path, 'photo.jpg'));

  static Future<_Harness> open(
    WidgetTester tester, {
    bool withPin = false,
    bool companyJoin = false,
  }) async {
    late _Harness h;
    await tester.runAsync(() async {
      final directory = Directory.systemTemp.createTempSync(
        'nearby-offer-consent-',
      );
      h = _Harness(
        directory,
        await sqliteBytesWithSetting(key: 'marker', value: 'original receiver'),
        await sqliteBytesWithSetting(key: 'marker', value: 'synthetic sender'),
      );
      h.shop.writeAsBytesSync(h.original);
      h.photo.writeAsBytesSync([7, 8, 9]);
      h.receiver = NearbyController(
        deviceId: 'receiver',
        deviceName: 'Receiver',
        companyJoin: companyJoin,
        discovery: h.discovery,
        bindAddress: InternetAddress.loopbackIPv4,
        localIps: () async => ['127.0.0.1'],
        now: () => h.clock.now,
        collectPayload: () async => throw StateError('Receiver must not send'),
        applyPayload: (payload) async {
          h.applied.add(payload);
          await h.shop.writeAsBytes(payload.sqliteBytes, flush: true);
          await h.photo.writeAsBytes(payload.photos['photo.jpg']!, flush: true);
        },
      );
      h.peer = _ControlledPeer(h);
      if (withPin) await h.pin.setPin('1234');
      await h.clock.run(h.receiver.start);
      await h.peer.pair();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        h.peer.client.close(force: true);
        await h.receiver.dispose();
        await h.discovery.updates.close();
        await h.db.close();
        h.directory.deleteSync(recursive: true);
      });
      h.revision.dispose();
    });
    await tester.pumpWidget(
      AppScope(
        db: h.db,
        pin: h.pin,
        deviceId: 'receiver',
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: h.revision,
            builder: (_, revision, _) =>
                NearbyPage(key: ValueKey(revision), controller: h.receiver),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return h;
  }

  Future<_OfferRequest> offer(WidgetTester tester, String name) async {
    late _OfferRequest request;
    await tester.runAsync(() async {
      request = await peer.offer(name);
      await _until(() => receiver.state.incoming?.sourceName == 'Sender $name');
    });
    await tester.pumpAndSettle();
    return request;
  }

  void expectUnchanged() {
    expect(applied, isEmpty);
    expect(shop.readAsBytesSync(), original);
    expect(photo.readAsBytesSync(), [7, 8, 9]);
  }

  Future<void> acceptCurrent(
    WidgetTester tester, {
    bool requirePin = false,
  }) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Accept shop'));
    await tester.pumpAndSettle();
    if (requirePin) {
      expect(find.text('Editor PIN'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Wrong PIN'), findsOneWidget);
      expectUnchanged();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Accept this shop?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Accept shop'));
    await tester.pumpAndSettle();
  }

  Future<void> expectTransferred(
    WidgetTester tester,
    _OfferRequest request,
  ) async {
    expect((await tester.runAsync(() => request.reply))!.status, HttpStatus.ok);
    expect((await tester.runAsync(request.transfer))!.status, HttpStatus.ok);
    expect(applied, hasLength(1));
    expect(applied.single.sqliteBytes, senderBytes);
    expect(applied.single.photos, {
      'photo.jpg': [4, 5, 6],
    });
    expect(shop.readAsBytesSync(), senderBytes);
    expect(photo.readAsBytesSync(), [4, 5, 6]);
    expect(
      (await tester.runAsync(request.transfer))!.status,
      HttpStatus.forbidden,
    );
    expect(applied, hasLength(1));
    await tester.pumpAndSettle();
  }
}

class _ControlledPeer {
  _ControlledPeer(this.h);
  final _Harness h;
  final client = HttpOverrides.runWithHttpOverrides(
    () => HttpClient()..findProxy = (_) => 'DIRECT',
    _LoopbackHttpOverrides(),
  );
  NearbySessionKeys? keys;

  Future<_Reply> request(
    String path, {
    Map<String, Object?>? json,
    Uint8List? bytes,
    bool authed = true,
  }) async {
    final method = bytes == null ? 'POST' : 'PUT';
    final data = bytes ?? utf8.encode(jsonEncode(json));
    final req = await client.open(method, '127.0.0.1', h.discovery.port, path);
    if (authed) {
      final session = keys!;
      final proof = session.signRequest(method, path, data);
      req.headers.set('x-nearby-session', session.id);
      req.headers.set('x-nearby-sequence', proof.sequence);
      req.headers.set('x-nearby-digest', proof.digest);
      req.headers.set('x-nearby-mac', proof.mac);
    }
    req.contentLength = data.length;
    req.add(data);
    final response = await req.close().timeout(const Duration(seconds: 5));
    return (
      status: response.statusCode,
      body: jsonDecode(
        await utf8.decoder.bind(response).join(),
      ) as Map<String, dynamic>,
    );
  }

  Future<void> pair() async {
    final agreement = await NearbyPendingPair.create(
      NearbyPairContext(
        id: nearbyRandomId(),
        guestId: 'sender',
        guestName: 'Sender',
        guestPort: 12345,
        hostId: 'receiver',
        hostName: 'Receiver',
        hostPort: h.discovery.port,
        purpose: h.receiver.companyJoin ? 'company-join@1' : null,
      ),
      guest: true,
    );
    final start = await request(
      '/v2/pair/start',
      json: {...agreement.context.toJson(), 'commitment': agreement.commitment},
      authed: false,
    );
    expect(start.status, HttpStatus.ok);
    agreement.receiveCommitment(start.body['commitment']);
    final reveal = await request(
      '/v2/pair/reveal',
      json: agreement.reveal(),
      authed: false,
    );
    final match = await agreement.receiveReveal(reveal.body);
    await h.receiver.confirmCode();
    final confirmation = await request(
      '/v2/pair/confirm',
      json: {'id': agreement.context.id, 'proof': match.confirmLocal()},
      authed: false,
    );
    expect(confirmation.status, HttpStatus.ok);
    match.confirmRemote(confirmation.body['proof']);
    keys = match.finish();
    expect(h.receiver.state.phase, NearbyPhase.paired);
  }

  Future<void> cancel() async {
    expect((await request('/v2/pair/cancel', json: {})).status, HttpStatus.ok);
  }

  Future<_OfferRequest> offer(String name) async {
    final session = keys!;
    final transferId = nearbyRandomId();
    final offer = NearbyOffer(
      sourceDeviceId: 'sender',
      sourceName: 'Sender $name',
      jobs: 1,
      parts: 2,
      photos: 1,
      bytes: h.senderBytes.length,
    );
    final bytes = await NearbyCodec().encrypt(
      payload: BackupPayload(
        createdAt: DateTime.utc(2026, 10, 20),
        sourceDeviceId: 'sender',
        sqliteBytes: h.senderBytes,
        photos: {
          'photo.jpg': Uint8List.fromList([4, 5, 6]),
        },
      ),
      key: session.sendKey,
      sessionId: session.id,
      direction: session.sendDirection,
      transferId: transferId,
      offer: offer,
    );
    final result = _OfferRequest(this, bytes);
    result.reply =
        request(
          '/v2/offer',
          json: {
            'sourceDeviceId': offer.sourceDeviceId,
            'sourceName': offer.sourceName,
            'jobs': offer.jobs,
            'parts': offer.parts,
            'photos': offer.photos,
            'bytes': bytes.length,
            'transferId': transferId,
            'digest': nearbyDigest(bytes),
          },
        ).then((reply) {
          result.completed = true;
          return reply;
        });
    unawaited(
      result.reply.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return result;
  }
}

class _LoopbackHttpOverrides extends HttpOverrides {}

class _OfferRequest {
  _OfferRequest(this.peer, this.bytes);
  final _ControlledPeer peer;
  final Uint8List bytes;
  late final Future<_Reply> reply;
  bool completed = false;
  Future<_Reply> transfer() => peer.request('/v2/transfer', bytes: bytes);
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
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {}
  @override
  Future<void> stop() async {}
}

class _Clock {
  final origin = DateTime.utc(2026, 10, 20);
  Duration elapsed = Duration.zero;
  DateTime get now => origin.add(elapsed);
  final timers = <_ScheduledTimer>[];
  Future<void> run(Future<void> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = _ScheduledTimer(zone, elapsed + duration, callback);
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

class _ScheduledTimer implements Timer {
  _ScheduledTimer(this.zone, this.due, this.callback);
  final Zone zone;
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
  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    zone.runGuarded(callback);
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
