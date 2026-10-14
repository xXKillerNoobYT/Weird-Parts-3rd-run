import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_commands.dart';
import '../../tool/native_nearby_test_crypto.dart';
import '../../tool/native_nearby_test_rpc.dart';

class _Page extends StatefulWidget {
  const _Page();
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

TestSession _session() => TestSession(
  epoch: 'epoch-a',
  run: 'run-a',
  role: TestRole.receiver,
  deviceId: 'receiver-a',
  peerId: 'sender-a',
  encryptionPublicKey: base64Url.encode(List.filled(32, 1)),
  signingPublicKey: base64Url.encode(List.filled(32, 2)),
);

const _looking = NativeTestResidentViewInfo(
  phase: NativeTestPhase.looking,
  sameNearbyState: true,
  discovered: false,
  codePresent: false,
);

NativeTestResidentRpc _rpc({
  int Function()? clock,
  NativeTestResidentViewInfo Function()? readInfo,
  void Function(NativeTestConfigureDiagnostic)? onDiagnostic,
}) => NativeTestResidentRpc(
  appPid: 100,
  run: 'run-a',
  role: TestRole.receiver,
  deviceId: 'receiver-a',
  peerId: 'sender-a',
  clockMillis: clock ?? () => 10,
  readInfoInLoop: readInfo ?? () => _looking,
  onDiagnostic: onDiagnostic,
);

const _rejected = {'version': 1, 'outcome': 'rejected'};
const _configured = {'version': 1, 'outcome': 'configured'};
const _notReady = {'version': 1, 'outcome': 'not-ready'};

void main() {
  test(
    'expired queue reports fixed reason and held owner pump progress',
    () async {
      var now = 10;
      final records = <NativeTestConfigureDiagnostic>[];
      final rpc = _rpc(clock: () => now, onDiagnostic: records.add);
      rpc.refreshInfoInLoop();
      rpc.markLoopStarted();
      rpc.markPumpStarted();
      final pending = rpc.configure(jsonEncode(_session().toJson()));
      now = 3010;
      rpc.processConfigurationInLoop((_) => fail('expired slot installed'));
      expect(await pending, _rejected);
      expect(records, hasLength(1));
      expect(records.single.toJson(), {
        'version': 1,
        'reason': 'expiredInLoop',
        'pumpPending': true,
        'loopIterations': 1,
        'pumpStarts': 1,
        'pumpCompletions': 0,
        'publicationAgeMillis': 3000,
      });
      rpc.markPumpSettled();
      rpc.close();
    },
  );

  test(
    'immediate rejects classify fixed branches without reserving invalid input',
    () async {
      final records = <NativeTestConfigureDiagnostic>[];
      final rpc = _rpc(onDiagnostic: records.add);
      expect(
        await rpc.configure('x' * (nativeTestMaxEnvelopeBytes + 1)),
        _rejected,
      );
      expect(
        await rpc.configure('\u00e9' * nativeTestMaxEnvelopeBytes),
        _rejected,
      );
      expect(await rpc.configure('not-json'), _rejected);
      expect(
        await rpc.configure(
          jsonEncode({..._session().toJson(), 'privateKey': 'canary'}),
        ),
        _rejected,
      );
      expect(
        await rpc.configure(
          jsonEncode({..._session().toJson(), 'run': 'other-run'}),
        ),
        _rejected,
      );
      final pending = rpc.configure(jsonEncode(_session().toJson()));
      expect(await rpc.configure(jsonEncode(_session().toJson())), _rejected);
      rpc.close();
      expect(await pending, _rejected);
      expect(await rpc.configure(jsonEncode(_session().toJson())), _rejected);
      expect(records.map((record) => record.reason), [
        NativeTestConfigureRejection.oversize,
        NativeTestConfigureRejection.oversize,
        NativeTestConfigureRejection.invalidSession,
        NativeTestConfigureRejection.invalidSession,
        NativeTestConfigureRejection.identityMismatch,
        NativeTestConfigureRejection.alreadyAttempted,
        NativeTestConfigureRejection.closed,
        NativeTestConfigureRejection.closed,
      ]);
      expect(
        records.every((record) => record.publicationAgeMillis == null),
        isTrue,
      );
      expect(
        jsonEncode(records.map((record) => record.toJson()).toList())
            .contains('canary'),
        isFalse,
      );
    },
  );

  test(
    'sink failure cannot change rejection or accepted-attempt latch',
    () async {
      final reasons = <NativeTestConfigureRejection>[];
      final rpc = _rpc(
        onDiagnostic: (record) {
          reasons.add(record.reason);
          throw StateError('SAS739281 PIN1234 http://127.0.0.1:9999/PRIVATE=/');
        },
      );
      expect(await rpc.configure('not-json'), _rejected);
      final pending = rpc.configure(jsonEncode(_session().toJson()));
      rpc.processConfigurationInLoop((_) => throw StateError('private-canary'));
      expect(await pending, _rejected);
      expect(await rpc.configure(jsonEncode(_session().toJson())), _rejected);
      expect(reasons, [
        NativeTestConfigureRejection.invalidSession,
        NativeTestConfigureRejection.installerRejected,
        NativeTestConfigureRejection.alreadyAttempted,
      ]);
      rpc.close();
    },
  );

  test(
    'healthy publication resets age and installation emits no rejection',
    () async {
      var now = 10;
      final records = <NativeTestConfigureDiagnostic>[];
      final rpc = _rpc(clock: () => now, onDiagnostic: records.add);
      rpc.refreshInfoInLoop();
      rpc.markLoopStarted();
      rpc.markPumpStarted();
      try {
        throw StateError('fixed-test-error');
      } on StateError {
        // Completion counts a settled await, including a thrown pump.
      } finally {
        rpc.markPumpSettled();
      }
      now = 200;
      rpc.refreshInfoInLoop();
      final pending = rpc.configure(jsonEncode(_session().toJson()));
      rpc.processConfigurationInLoop((_) {});
      expect(await pending, _configured);
      expect(records, isEmpty);
      now = 225;
      expect(await rpc.configure(jsonEncode(_session().toJson())), _rejected);
      expect(records.single.toJson(), {
        'version': 1,
        'reason': 'alreadyAttempted',
        'pumpPending': false,
        'loopIterations': 1,
        'pumpStarts': 1,
        'pumpCompletions': 1,
        'publicationAgeMillis': 25,
      });
      rpc.close();
    },
  );

  test('diagnostic parser enforces exact schema, enum and progress bounds', () {
    final valid = const NativeTestConfigureDiagnostic(
      reason: NativeTestConfigureRejection.closed,
      pumpPending: false,
      loopIterations: 1,
      pumpStarts: 1,
      pumpCompletions: 1,
      publicationAgeMillis: 0,
    ).toJson();
    for (final reason in NativeTestConfigureRejection.values) {
      expect(
        NativeTestConfigureDiagnostic.fromJson({
          ...valid,
          'reason': reason.name,
        }).reason,
        reason,
      );
    }
    expect(
      NativeTestConfigureDiagnostic.fromJson({
        ...valid,
        'publicationAgeMillis': null,
      }).publicationAgeMillis,
      isNull,
    );
    final invalid = [
      {...valid, 'version': 1.0},
      {...valid, 'reason': 'unknown'},
      {...valid, 'reason': 'SAS739281'},
      {...valid, 'privateKey': 'canary'},
      {...valid, 'pumpPending': 1},
      {...valid, 'loopIterations': null},
      {...valid, 'pumpStarts': -1},
      {...valid, 'pumpCompletions': 1.0},
      {...valid, 'publicationAgeMillis': -1},
      {...valid, 'publicationAgeMillis': 9007199254740992},
      {...valid, 'loopIterations': 9007199254740992},
      {...valid, 'loopIterations': 0},
      {...valid, 'pumpCompletions': 2},
      {...valid, 'pumpPending': true},
      {
        ...valid,
        'loopIterations': 2,
        'pumpStarts': 2,
        'pumpCompletions': 0,
        'pumpPending': true,
      },
    ];
    for (final value in invalid) {
      expect(
        () => NativeTestConfigureDiagnostic.fromJson(value),
        throwsA(isA<NativeTestFailure>()),
      );
    }
  });

  testWidgets(
    'RPC info does not reread guarded widget state during pump scope',
    (tester) async {
      await tester.pumpWidget(const _Page());
      final originalState = tester.state(find.byType(_Page));
      var reads = 0;
      final diagnosticRecords = <NativeTestConfigureDiagnostic>[];
      final rpc = NativeTestResidentRpc(
        appPid: 100,
        run: 'run-a',
        role: TestRole.receiver,
        deviceId: 'receiver-a',
        peerId: 'sender-a',
        clockMillis: () => 10,
        onDiagnostic: diagnosticRecords.add,
        readInfoInLoop: () {
          reads++;
          return NativeTestResidentViewInfo(
            phase: NativeTestPhase.looking,
            sameNearbyState: identical(
              originalState,
              tester.state(find.byType(_Page)),
            ),
            discovered: false,
            codePresent: false,
          );
        },
      );
      rpc.refreshInfoInLoop();
      // registerExtension binds to this zone, before pump creates its guard zone.
      final callback = Zone.current.bindCallback(rpc.info);
      final release = Completer<void>();
      final pumpScope = TestAsyncUtils.guard<void>(() => release.future);
      Map<String, Object>? reply;
      Object? failure;
      Object? legacyFailure;
      Future<Map<String, Object>>? invalidConfiguration;
      try {
        try {
          tester.state(find.byType(_Page));
        } catch (error) {
          legacyFailure = error;
        }
        reply = callback();
        invalidConfiguration = rpc.configure('not-json');
      } catch (error) {
        failure = error;
      } finally {
        release.complete();
        await pumpScope;
      }
      expect(legacyFailure, isA<FlutterError>());
      expect(legacyFailure.toString(), contains('Guarded function conflict.'));
      expect(failure, isNull);
      expect(reply?['outcome'], 'ready');
      expect(reply?['sameNearbyState'], isTrue);
      expect(reads, 1);
      expect(await invalidConfiguration!, _rejected);
      expect(
        diagnosticRecords.single.reason,
        NativeTestConfigureRejection.invalidSession,
      );
      rpc.close();
    },
  );

  testWidgets('configure queues during guard and validates in resident loop', (
    tester,
  ) async {
    await tester.pumpWidget(const _Page());
    final original = tester.state(find.byType(_Page));
    final rpc = _rpc();
    rpc.refreshInfoInLoop();
    final callback = Zone.current.bindCallback(
      () => rpc.configure(jsonEncode(_session().toJson())),
    );
    final release = Completer<void>();
    final pumpScope = TestAsyncUtils.guard<void>(() => release.future);
    late Future<Map<String, Object>> reply;
    try {
      reply = callback();
      expectSync(rpc.info()['configured'], isFalse);
    } finally {
      release.complete();
      await pumpScope;
    }
    var installed = 0;
    rpc.processConfigurationInLoop((next) {
      expect(identical(original, tester.state(find.byType(_Page))), isTrue);
      expect(next.deviceId, 'receiver-a');
      installed++;
    });
    expect(await reply, _configured);
    expect(installed, 1);
    expect(rpc.info()['configured'], isTrue);
    rpc.close();
  });

  test(
    'single pending configure and lost reply never authorize a retry',
    () async {
      final rpc = _rpc();
      final data = jsonEncode(_session().toJson());
      final first = rpc.configure(data);
      expect(await rpc.configure(data), _rejected);
      var installs = 0;
      rpc.processConfigurationInLoop((_) => installs++);
      expect(await first, _configured);
      rpc.processConfigurationInLoop((_) => installs++);
      expect(await rpc.configure(data), _rejected);
      expect(installs, 1);
      rpc.close();
    },
  );

  test(
    'expired pending configuration cannot apply when loop resumes',
    () async {
      var now = 0;
      final rpc = _rpc(clock: () => now);
      final data = jsonEncode(_session().toJson());
      final reply = rpc.configure(data);
      now = 3000;
      var installs = 0;
      rpc.processConfigurationInLoop((_) => installs++);
      expect(await reply, _rejected);
      expect(await rpc.configure(data), _rejected);
      rpc.processConfigurationInLoop((_) => installs++);
      expect(installs, 0);
      rpc.close();
    },
  );

  test(
    'timer rejects an unserviced slot without permitting late install',
    () async {
      var now = 10;
      final records = <NativeTestConfigureDiagnostic>[];
      final rpc = _rpc(
        clock: () => now,
        onDiagnostic: (record) {
          records.add(record);
          throw StateError('private-canary');
        },
      );
      rpc.refreshInfoInLoop();
      rpc.markLoopStarted();
      rpc.markPumpStarted();
      final reply = rpc.configure(jsonEncode(_session().toJson()));
      now = 4510;
      expect(await reply, _rejected);
      expect(records.single.reason, NativeTestConfigureRejection.timerExpired);
      expect(records.single.pumpPending, isTrue);
      expect(records.single.publicationAgeMillis, 4500);
      expect(rpc.info()['outcome'], 'ready');
      var installs = 0;
      rpc.processConfigurationInLoop((_) => installs++);
      rpc.close();
      expect(installs, 0);
      expect(await reply, _rejected);
    },
  );

  test(
    'close rejects pending configuration and clears public readiness',
    () async {
      final rpc = _rpc();
      rpc.refreshInfoInLoop();
      final pending = rpc.configure(jsonEncode(_session().toJson()));
      rpc.close();
      rpc.close();
      expect(await pending, _rejected);
      expect(rpc.info(), _notReady);
      expect(await rpc.configure(jsonEncode(_session().toJson())), _rejected);
      var installed = false;
      rpc.processConfigurationInLoop((_) => installed = true);
      expect(installed, isFalse);
    },
  );

  test(
    'failed fresh validation rejects without configuring or leaking error',
    () async {
      final rpc = _rpc();
      rpc.refreshInfoInLoop();
      final pending = rpc.configure(jsonEncode(_session().toJson()));
      rpc.processConfigurationInLoop((_) {
        throw StateError('SAS739281 PIN1234 http://127.0.0.1:9999/PRIVATE=/');
      });
      expect(await pending, _rejected);
      expect(rpc.info()['configured'], isFalse);
      expect(await rpc.configure(jsonEncode(_session().toJson())), _rejected);
      rpc.close();
    },
  );

  test(
    'strict bounded configuration input does not reserve malformed attempts',
    () async {
      final rpc = _rpc();
      final valid = _session().toJson();
      final badInputs = [
        'not-json',
        jsonEncode({...valid, 'run': 'other-run'}),
        jsonEncode({...valid, 'role': 'sender'}),
        jsonEncode({...valid, 'deviceId': 'other-device'}),
        jsonEncode({...valid, 'peerId': 'other-peer'}),
        jsonEncode({...valid, 'rawCode': '739281'}),
        jsonEncode({...valid, 'privateKey': 'private-canary'}),
        'x' * (nativeTestMaxEnvelopeBytes + 1),
        '\u00e9' * nativeTestMaxEnvelopeBytes,
      ];
      for (final input in badInputs) {
        expect(await rpc.configure(input), _rejected);
      }
      final reply = rpc.configure(jsonEncode(valid));
      rpc.processConfigurationInLoop((_) {});
      expect(await reply, _configured);
      rpc.close();
    },
  );

  test('info exposes only primitive snapshot and safe live clock', () {
    var now = 10;
    var current = _looking;
    var reads = 0;
    final rpc = _rpc(
      clock: () => now,
      readInfo: () {
        reads++;
        return current;
      },
    );
    expect(rpc.info(), _notReady);
    rpc.refreshInfoInLoop();
    final reply = rpc.info();
    expect(reply.keys.toSet(), {
      'version',
      'outcome',
      'appPid',
      'run',
      'role',
      'deviceId',
      'peerId',
      'configured',
      'elapsedMillis',
      'phase',
      'sameNearbyState',
      'discovered',
      'codePresent',
    });
    reply['phase'] = 'tampered';
    current = const NativeTestResidentViewInfo(
      phase: NativeTestPhase.pairing,
      sameNearbyState: true,
      discovered: true,
      codePresent: true,
    );
    now = 20;
    expect(rpc.info()['phase'], 'looking');
    expect(rpc.info()['elapsedMillis'], 20);
    expect(reads, 1);
    rpc.refreshInfoInLoop();
    expect(rpc.info()['phase'], 'pairing');
    expect(reads, 2);
    rpc.close();
  });

  test(
    'loop refresh failure finally rejects pending and publishes not-ready',
    () async {
      var failRead = false;
      final rpc = _rpc(
        readInfo: () {
          if (failRead) throw StateError('private-canary');
          return _looking;
        },
      );
      rpc.refreshInfoInLoop();
      final pending = rpc.configure(jsonEncode(_session().toJson()));
      failRead = true;
      try {
        rpc.refreshInfoInLoop();
        fail('expected refresh failure');
      } on StateError {
        // The resident run loop closes the boundary from its finally block.
      } finally {
        rpc.close();
      }
      expect(await pending, _rejected);
      expect(rpc.info(), _notReady);
    },
  );
}
