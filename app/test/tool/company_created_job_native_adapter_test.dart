import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/features/company/company_gate.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/company/company_join_page.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_commands.dart';
import 'native_nearby_test_commands_test.dart' as command_test show Fixture;
import '../features/company/company_join_test.dart'
    show JoinFixture, JoinTestDiscovery;
import '../features/company/company_join_widget_test.dart'
    show joinWidgetSignal;

final _revision = List.filled(40, 'a').join();
final _tree = List.filled(40, 'b').join();
final _adapterHash = List.filled(64, 'c').join();

final class _HeldStopDiscovery implements NearbyDiscovery {
  final delegate = JoinTestDiscovery();
  final entered = Completer<void>();
  final release = Completer<void>();
  bool hold = false;
  @override
  Stream<List<NearbyPeer>> get peers => delegate.peers;
  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) => delegate.start(deviceId: deviceId, name: name, port: port, ips: ips);
  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) => delegate.updateAdvertisement(name: name, port: port, ips: ips);
  @override
  Future<void> stop() async {
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await delegate.stop();
  }
}

Future<NativeTestCommandReply> _settleNativeCommand(
  command_test.Fixture cache,
  NativeTestCommand command,
  Future<NativeTestCommandResult> operation,
) async {
  try {
    return cache.cache.complete(command, await operation);
  } on adapter.CreatedJobNativeTerminalFailure catch (failure) {
    return cache.cache.fail(
      command,
      failure.error,
      effect: NativeTestEffect.completed,
    );
  } catch (_) {
    return cache.cache.fail(
      command,
      NativeTestCommandError.harnessFailed,
      effect: NativeTestEffect.possible,
    );
  }
}

void _validate({
  bool createdMode = true,
  String? run,
  String? revision,
  String? productRevision,
  String role = 'owner',
  String platform = 'windows',
}) => adapter.validateJoinNativeDefines(
  enabled: true,
  run: run ?? adapter.createdJobNativeRun,
  role: role,
  platform: platform,
  revision: revision ?? _revision,
  tree: _tree,
  adapter: _adapterHash,
  createdMode: createdMode,
  productRevision: productRevision ?? _revision,
);

void main() {
  test('native diagnostic retention and evidence writes stay bounded across remounts', () {
    final diagnostics = adapter.CreatedJobNativeSyncDiagnostics();
    var writes = 0;
    for (var i = 0; i < 35; i++) {
      if (diagnostics.observe(
        const CreatedJobSyncDiagnostic.terminal(
          CreatedJobSyncResult(0, 0, false, 0),
        ),
      )) {
        writes++;
      }
    }
    expect(writes, 32);
    expect(diagnostics.snapshot['terminals'], hasLength(32));
    expect(diagnostics.snapshot['droppedTerminals'], 3);
    expect(diagnostics.snapshot['evidenceWriteAttempts'], 32);
    expect(diagnostics.snapshot['droppedEvidence'], 3);
    diagnostics.resetAttempt();
    expect(
      diagnostics.observe(const CreatedJobSyncDiagnostic.receiverEntered()),
      isFalse,
    );
    expect(diagnostics.snapshot['evidenceWriteAttempts'], 32);
    expect(diagnostics.snapshot['droppedEvidence'], 4);
  });
  test(
    'native terminal capture survives remount and resets the next attempt',
    () {
      final diagnostics = adapter.CreatedJobNativeSyncDiagnostics();
      const failure = CreatedJobSyncResult(
        0,
        0,
        false,
        0,
        failure: CreatedJobSyncFailure(
          CreatedJobSyncStage.preflight,
          CreatedJobSyncReason.unavailable,
        ),
      );
      diagnostics.observe(const CreatedJobSyncDiagnostic.started());
      diagnostics.observe(const CreatedJobSyncDiagnostic.terminal(failure));
      final terminal = diagnostics.snapshot;
      expect(terminal['receiverCallbackReached'], isFalse);
      expect(terminal['failureStage'], 'preflight');
      expect(terminal['failureReason'], 'unavailable');
      diagnostics.resetAttempt();
      expect(diagnostics.snapshot['terminalObserved'], isFalse);
      expect(diagnostics.snapshot['receiverCallbackReached'], isFalse);
      expect((diagnostics.snapshot['terminals'] as List).single, {
        'receiverCallbackReached': false,
        'terminalObserved': true,
        'complete': false,
        'sent': 0,
        'received': 0,
        'unsupported': 0,
        'failureStage': 'preflight',
        'failureReason': 'unavailable',
      });
      expect(
        diagnostics.observe(const CreatedJobSyncDiagnostic.receiverEntered()),
        isTrue,
      );
      expect(diagnostics.snapshot['receiverCallbackReached'], isTrue);
      diagnostics.observe(
        const CreatedJobSyncDiagnostic.started(receiverCallbackReached: true),
      );
      diagnostics.observe(
        const CreatedJobSyncDiagnostic.terminal(
          CreatedJobSyncResult(0, 1, true, 0),
          receiverCallbackReached: true,
        ),
      );
      expect(diagnostics.snapshot['complete'], isTrue);
      expect(diagnostics.snapshot['failureReason'], isNull);
      expect(diagnostics.snapshot['receiverCallbackReached'], isTrue);
      diagnostics.observe(const CreatedJobSyncDiagnostic.started());
      expect(diagnostics.snapshot['terminalObserved'], isFalse);
      expect(diagnostics.snapshot['receiverCallbackReached'], isFalse);
      expect(diagnostics.snapshot['terminals'], hasLength(2));
      expect(jsonEncode(terminal), contains('unavailable'));
    },
  );
  for (final beforeEffect in [false, true]) {
    test(
      'native readiness keeps ${beforeEffect ? 'effect deadline' : 'three-minute passive bound'}',
      () async {
        var elapsed = 0;
        var pumps = 0;
        await expectLater(
          adapter.waitForJoinNativeCompletion(
            ready: () => false,
            elapsedMillis: () => elapsed,
            commandDeadlineMillis: 15000,
            enforceCommandDeadline: beforeEffect,
            pump: () async {
              pumps++;
              elapsed = beforeEffect ? 15000 : 180000;
            },
          ),
          throwsA(anything),
        );
        expect(pumps, 1);
        expect(elapsed, beforeEffect ? 15000 : 180000);
      },
    );
  }
  testWidgets(
    'stale disabled Sync Now is not busy without actual busy indicator',
    (tester) async {
      Widget page({required bool busy}) => MaterialApp(
        home: Column(
          children: [
            const FilledButton(
              key: Key('company-jobs-sync-now'),
              onPressed: null,
              child: Text('Sync Now'),
            ),
            if (busy)
              const CircularProgressIndicator(key: Key('company-join-busy')),
          ],
        ),
      );
      await tester.pumpWidget(page(busy: false));
      expect(adapter.createdJobNativeUiBusy(), isFalse);
      expect(
        adapter.createdJobNativeUiState(
          status: 'Job snapshot synced. Sent 1, received 1.',
          errorVisible: false,
          busy: adapter.createdJobNativeUiBusy(),
        ),
        adapter.CreatedJobNativeUiState.complete,
      );
      await tester.pumpWidget(page(busy: true));
      expect(adapter.createdJobNativeUiBusy(), isTrue);
      expect(
        adapter.createdJobNativeUiState(
          status: 'Job snapshot synced. Sent 1, received 1.',
          errorVisible: false,
          busy: adapter.createdJobNativeUiBusy(),
        ),
        adapter.CreatedJobNativeUiState.pending,
      );
    },
  );
  test(
    'admitted Sync resolves original UNKNOWN command after late terminal UI',
    () async {
      final cache = command_test.Fixture();
      final wire = cache.request(
        1,
        action: NativeTestAction.accept,
        deadline: 15000,
      );
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var state = adapter.CreatedJobNativeUiState.pending;
      var pumps = 0;
      var taps = 0;
      adapter.validateJoinNativeDeadline(cache.now, command.deadlineMillis);
      taps++;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.waitForCreatedJobNativeSyncTerminal(
          waitUntilReady: (ready) => adapter.waitForJoinNativeCompletion(
            ready: ready,
            elapsedMillis: () => cache.now,
            commandDeadlineMillis: command.deadlineMillis,
            pump: () async {
              pumps++;
              if (pumps == 1) {
                cache.now = 15000;
                expect(
                  cache.cache.submitJson(wire).state,
                  NativeTestCommandState.unknown,
                );
                expect(cache.cache.takeNext(), isNull);
                expect(
                  cache.cache
                      .submitJson(cache.request(2, deadline: 30000))
                      .error,
                  NativeTestCommandError.busy,
                );
                expect(taps, 1);
              } else {
                cache.now = 15001;
                state = adapter.CreatedJobNativeUiState.complete;
              }
            },
          ),
          readState: () => state,
          isStillCurrent: () => true,
        ),
      );
      expect(reply.state, NativeTestCommandState.completed);
      expect(reply.effect, NativeTestEffect.completed);
      expect(pumps, 2);
      expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
      expect(cache.cache.takeNext(), isNull);
      expect(taps, 1);
      expect(
        () => adapter.validateJoinNativeDeadline(
          cache.now,
          command.deadlineMillis,
        ),
        throwsA(anything),
      );
      final expiredNew = cache.cache.submitJson(
        cache.request(
          2,
          action: NativeTestAction.accept,
          deadline: command.deadlineMillis,
        ),
      );
      expect(expiredNew.state, NativeTestCommandState.failed);
      expect(expiredNew.error, NativeTestCommandError.deadlineExpired);
      expect(cache.cache.takeNext(), isNull);
      expect(taps, 1);
    },
  );
  test(
    'admitted Close resolves original UNKNOWN command only after late drain',
    () async {
      final cache = command_test.Fixture();
      final wire = cache.request(
        1,
        action: NativeTestAction.finish,
        deadline: 15000,
      );
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var drained = false;
      var pumps = 0;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.waitForCreatedJobNativeCloseDrain(
          waitUntilReady: (ready) => adapter.waitForJoinNativeCompletion(
            ready: ready,
            elapsedMillis: () => cache.now,
            commandDeadlineMillis: command.deadlineMillis,
            pump: () async {
              pumps++;
              cache.now = pumps == 1 ? 15000 : 15001;
              if (pumps == 1) {
                expect(
                  cache.cache.submitJson(wire).state,
                  NativeTestCommandState.unknown,
                );
                expect(cache.cache.takeNext(), isNull);
                expect(
                  cache.cache
                      .submitJson(cache.request(2, deadline: 30000))
                      .error,
                  NativeTestCommandError.busy,
                );
              } else {
                drained = true;
              }
            },
          ),
          isDrained: () => drained,
        ),
      );
      expect(reply.state, NativeTestCommandState.completed);
      expect(reply.effect, NativeTestEffect.completed);
      expect(pumps, 2);
      expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
      expect(cache.cache.takeNext(), isNull);
    },
  );
  test('created native Pair retries failed state once through cache', () async {
    final cache = command_test.Fixture();
    final wire = cache.request(1, action: NativeTestAction.pair);
    cache.cache.submitJson(wire);
    final command = cache.cache.takeNext()!;
    var taps = 0;
    final reply = await _settleNativeCommand(
      cache,
      command,
      adapter.performJoinNativePair(
        createdMode: true,
        finished: false,
        phase: NearbyPhase.failed,
        peerCount: 1,
        tapPair: () async {
          taps++;
        },
      ),
    );
    expect(reply.state, NativeTestCommandState.completed);
    expect(reply.effect, NativeTestEffect.completed);
    expect(taps, 1);
    expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
    expect(cache.cache.takeNext(), isNull);
    expect(taps, 1);
  });
  test('native Pair preserves looking behavior in both modes', () async {
    for (final createdMode in [false, true]) {
      var taps = 0;
      final result = await adapter.performJoinNativePair(
        createdMode: createdMode,
        finished: false,
        phase: NearbyPhase.looking,
        peerCount: 1,
        tapPair: () async {
          taps++;
        },
      );
      expect(result.effect, NativeTestEffect.completed);
      expect(taps, 1);
    }
  });
  test('native Pair refuses legacy failure and other inactive boundary shapes before tapping', () async {
    final refused = [
      (created: false, finished: false, phase: NearbyPhase.failed, peers: 1),
      for (final created in [false, true])
        for (final phase in NearbyPhase.values)
          if (phase != NearbyPhase.looking && phase != NearbyPhase.failed)
            (created: created, finished: false, phase: phase, peers: 1),
      (created: true, finished: true, phase: NearbyPhase.failed, peers: 1),
      (created: true, finished: false, phase: NearbyPhase.failed, peers: 0),
      (created: true, finished: false, phase: NearbyPhase.failed, peers: 2),
    ];
    for (final input in refused) {
      final cache = command_test.Fixture();
      final wire = cache.request(1, action: NativeTestAction.pair);
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var taps = 0;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.performJoinNativePair(
          createdMode: input.created,
          finished: input.finished,
          phase: input.phase,
          peerCount: input.peers,
          tapPair: () async {
            taps++;
          },
        ),
      );
      expect(reply.state, NativeTestCommandState.failed, reason: '$input');
      expect(reply.effect, NativeTestEffect.possible);
      expect(taps, 0, reason: '$input');
    }
  });
  for (final terminal in [
    adapter.CreatedJobNativeUiState.complete,
    adapter.CreatedJobNativeUiState.incomplete,
    adapter.CreatedJobNativeUiState.error,
  ]) {
    test(
      'native Sync cache stays running until terminal ${terminal.name}',
      () async {
        final cache = command_test.Fixture();
        final wire = cache.request(1, action: NativeTestAction.accept);
        cache.cache.submitJson(wire);
        final command = cache.cache.takeNext()!;
        var state = adapter.CreatedJobNativeUiState.pending;
        bool Function()? ready;
        final waited = Completer<void>();
        var settled = false;
        final result =
            _settleNativeCommand(
              cache,
              command,
              adapter.waitForCreatedJobNativeSyncTerminal(
                waitUntilReady: (predicate) {
                  ready = predicate;
                  return waited.future;
                },
                readState: () => state,
                isStillCurrent: () => true,
              ),
            ).then((reply) {
              settled = true;
              return reply;
            });
        await Future<void>.value();
        expect(settled, isFalse);
        expect(ready!(), isFalse);
        expect(
          cache.cache.submitJson(wire).state,
          NativeTestCommandState.running,
        );
        expect(cache.cache.takeNext(), isNull);
        expect(
          cache.cache.submitJson(cache.request(2)).error,
          NativeTestCommandError.busy,
        );
        state = terminal;
        expect(ready!(), isTrue);
        waited.complete();
        final reply = await result;
        expect(reply.effect, NativeTestEffect.completed);
        expect(
          reply.state,
          terminal == adapter.CreatedJobNativeUiState.complete
              ? NativeTestCommandState.completed
              : NativeTestCommandState.failed,
        );
        expect(
          reply.error,
          terminal == adapter.CreatedJobNativeUiState.complete
              ? isNull
              : NativeTestCommandError.stateChanged,
        );
        expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
        expect(cache.cache.takeNext(), isNull);
      },
    );
  }
  for (final nonterminal in [
    adapter.CreatedJobNativeUiState.idle,
    adapter.CreatedJobNativeUiState.pending,
    adapter.CreatedJobNativeUiState.unknown,
  ]) {
    test(
      'native Sync refuses nonterminal ${nonterminal.name} after bounded wait',
      () async {
        final cache = command_test.Fixture();
        final wire = cache.request(1, action: NativeTestAction.accept);
        cache.cache.submitJson(wire);
        final command = cache.cache.takeNext()!;
        final reply = await _settleNativeCommand(
          cache,
          command,
          adapter.waitForCreatedJobNativeSyncTerminal(
            waitUntilReady: (ready) async {
              expect(ready(), isFalse);
              cache.now = 1000;
              cache.cache.tick();
              expect(
                cache.cache.submitJson(wire).state,
                NativeTestCommandState.unknown,
              );
              throw StateError('bounded wait expired');
            },
            readState: () => nonterminal,
            isStillCurrent: () => true,
          ),
        );
        expect(reply.state, NativeTestCommandState.failed);
        expect(reply.effect, NativeTestEffect.possible);
        expect(reply.error, NativeTestCommandError.harnessFailed);
      },
    );
  }
  test(
    'native Sync refuses late terminal UI after page or lifecycle cancellation',
    () async {
      final cache = command_test.Fixture();
      final wire = cache.request(1, action: NativeTestAction.accept);
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var current = true;
      var state = adapter.CreatedJobNativeUiState.pending;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.waitForCreatedJobNativeSyncTerminal(
          waitUntilReady: (ready) => adapter.waitForJoinNativeCompletion(
            ready: ready,
            elapsedMillis: () => cache.now,
            commandDeadlineMillis: command.deadlineMillis,
            pump: () async {
              cache.now = 1000;
              expect(
                cache.cache.submitJson(wire).state,
                NativeTestCommandState.unknown,
              );
              current = false;
              state = adapter.CreatedJobNativeUiState.complete;
            },
          ),
          readState: () => state,
          isStillCurrent: () => current,
        ),
      );
      expect(reply.state, NativeTestCommandState.failed);
      expect(reply.effect, NativeTestEffect.possible);
      expect(reply.error, NativeTestCommandError.harnessFailed);
    },
  );
  testWidgets(
    'native Close waits for actual route return after controller stop drains',
    (tester) async {
      late JoinFixture fixture;
      await tester.runAsync(() async => fixture = await JoinFixture.create());
      final discovery = _HeldStopDiscovery();
      final controller = NearbyController(
        deviceId: 'native-close',
        deviceName: 'native-close',
        discovery: discovery,
        companyJoin: true,
        bindAddress: InternetAddress.loopbackIPv4,
        localIps: () async => ['127.0.0.1'],
        collectPayload: () async =>
            throw StateError('Join must not collect a shop'),
        applyPayload: (_) async =>
            throw StateError('Join must not replace a shop'),
      );
      final cache = command_test.Fixture();
      final wire = cache.request(1, action: NativeTestAction.finish);
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      final returned = Completer<void>();
      bool Function()? ready;
      final waited = Completer<void>();
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final navigator = Navigator.of(tester.element(find.byType(Scaffold)));
      unawaited(
        navigator
            .push<bool>(
              MaterialPageRoute(
                builder: (_) => CompanyJoinPage(
                  enrollment: fixture.aEnrollment,
                  approver: fixture.owner,
                  reconnect: true,
                  createController: (_) => controller,
                ),
              ),
            )
            .then((_) => returned.complete()),
      );
      final page = find.byType(CompanyJoinPage);
      try {
        final close = find.byKey(const Key('company-join-close'));
        await joinWidgetSignal(
          tester,
          () =>
              page.evaluate().length == 1 &&
              close.evaluate().length == 1 &&
              tester.widget<TextButton>(close).onPressed != null &&
              controller.state.running,
        );
        final state = tester.state(page);
        discovery.hold = true;
        await tester.runAsync(() => tester.tap(close));
        await joinWidgetSignal(tester, () => discovery.entered.isCompleted);
        expect(
          controller.state.running,
          isFalse,
          reason: 'Transport stop alone is not route/drain completion.',
        );
        expect(state.mounted, isTrue);
        expect(returned.isCompleted, isFalse);
        var settled = false;
        final result =
            _settleNativeCommand(
              cache,
              command,
              adapter.waitForCreatedJobNativeCloseDrain(
                waitUntilReady: (predicate) {
                  ready = predicate;
                  return waited.future;
                },
                isDrained: () =>
                    returned.isCompleted &&
                    !state.mounted &&
                    !controller.state.running,
              ),
            ).then((reply) {
              settled = true;
              return reply;
            });
        await tester.pump();
        expect(settled, isFalse);
        expect(
          cache.cache.submitJson(wire).state,
          NativeTestCommandState.running,
        );
        expect(cache.cache.takeNext(), isNull);
        expect(
          cache.cache.submitJson(cache.request(2)).error,
          NativeTestCommandError.busy,
        );
        discovery.release.complete();
        await joinWidgetSignal(
          tester,
          () =>
              returned.isCompleted &&
              !state.mounted &&
              !controller.state.running,
        );
        expect(ready!(), isTrue);
        waited.complete();
        await tester.pump();
        final reply = await result;
        expect(reply.state, NativeTestCommandState.completed);
        expect(reply.effect, NativeTestEffect.completed);
        expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
        expect(cache.cache.takeNext(), isNull);
      } finally {
        if (!discovery.release.isCompleted) discovery.release.complete();
        await joinWidgetSignal(
          tester,
          () =>
              returned.isCompleted &&
              page.evaluate().isEmpty &&
              !controller.state.running,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await controller.dispose();
          await discovery.delegate.controller.close();
          await fixture.closeAndCheckOwnerData();
        });
      }
    },
  );
  testWidgets(
    'native signin waits for loaded Jobs before extra authority verification',
    (tester) async {
      late JoinFixture fixture;
      await tester.runAsync(() async {
        fixture = await JoinFixture.create();
        await fixture.aEnrollment.signOut();
      });
      final originalJobs = (await tester.runAsync(
        () => fixture.aDb.select(fixture.aDb.jobs).get(),
      ))!;
      final originalHistory = (await tester.runAsync(
        () => fixture.aDb.select(fixture.aDb.companyJobs).get(),
      ))!;
      final entered = Completer<void>();
      final released = Completer<void>();
      await tester.binding.setSurfaceSize(const Size(1500, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: CompanyBootstrapGate(
              db: fixture.aDb,
              installation: fixture.a,
            ),
          ),
        );
        await joinWidgetSignal(
          tester,
          () =>
              find.byKey(const Key('company-signin-pin')).evaluate().length ==
              1,
        );
        fixture.aStore.beforeRead = (namespace) {
          if (!entered.isCompleted &&
              namespace == fixture.a.namespace &&
              find.byType(CompanyJobsPanel).evaluate().length == 1) {
            entered.complete();
            return released.future;
          }
          return null;
        };
        await tester.enterText(
          find.byKey(const Key('company-signin-pin')),
          '1234',
        );
        await tester.runAsync(
          () => tester.tap(find.byKey(const Key('company-signin'))),
        );
        await joinWidgetSignal(tester, () => entered.isCompleted);
        expect(find.byKey(const Key('company-peer-open')), findsOneWidget);
        expect(find.text('Loading company Jobs...'), findsOneWidget);
        expect(find.byKey(const Key('company-jobs-list')), findsNothing);
        var readyForExtraSignIn = false;
        final readiness = adapter
            .waitForJoinNativeSignInReady(
              waitUntilReady: (ready) async {
                if (!ready()) {
                  await released.future;
                  await joinWidgetSignal(tester, ready);
                }
              },
            )
            .then((_) => readyForExtraSignIn = true);
        await tester.pump();
        expect(
          readyForExtraSignIn,
          isFalse,
          reason: 'The signed-in shell must not authorize another protected read while Jobs load.',
        );
        released.complete();
        await readiness;
        expect(readyForExtraSignIn, isTrue);
        final original = originalJobs.single;
        final renderedRow = find.byKey(Key('company-job-${original.id}'));
        expect(renderedRow, findsOneWidget);
        expect(
          find.descendant(of: renderedRow, matching: find.text(original.name)),
          findsOneWidget,
        );
        expect(find.byKey(const Key('company-job-error')), findsNothing);
        await tester.runAsync(() async {
          final extra = await fixture.aEnrollment.signIn('1234');
          final commands = CompanyJobCommands(enrollment: fixture.aEnrollment);
          final listed = await commands.listJobs(ownerSession: extra);
          expect(listed.map((job) => job.id), [original.id]);
          final verified = await commands.verifySyncRecord(original.id, extra);
          expect(verified, originalHistory.single);
          expect(
            await fixture.aDb.select(fixture.aDb.jobs).get(),
            originalJobs,
          );
          expect(
            await fixture.aDb.select(fixture.aDb.companyJobs).get(),
            originalHistory,
          );
          await fixture.aEnrollment.signOut();
        });
        expect(find.byKey(const Key('company-job-error')), findsNothing);
      } finally {
        fixture.aStore.beforeRead = null;
        if (!released.isCompleted) released.complete();
        await joinWidgetSignal(
          tester,
          () =>
              find
                  .byKey(const Key('company-jobs-list'))
                  .evaluate()
                  .isNotEmpty ||
              find.byKey(const Key('company-job-error')).evaluate().isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.closeAndCheckOwnerData);
      }
    },
  );
  testWidgets(
    'pushed page State capture waits for route build and preserves pop completion',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final navigator = Navigator.of(tester.element(find.byType(Scaffold)));
      const pageKey = Key('native-pushed-page');
      final page = find.byKey(pageKey);
      var routeReturned = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          navigator
              .push<void>(
                MaterialPageRoute(
                  builder: (_) => const Form(key: pageKey, child: SizedBox()),
                ),
              )
              .then((_) => routeReturned = true),
        );
      });
      await tester.pump();
      expect(page, findsNothing);
      var readinessPumps = 0;
      final captured = await adapter.captureJoinNativePageState(
        tester: tester,
        page: page,
        waitUntilReady: (ready) async {
          while (!ready() && readinessPumps < 10) {
            readinessPumps++;
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(ready(), isTrue);
        },
      );
      expect(readinessPumps, greaterThan(0));
      expect(captured, same(tester.state<FormState>(page)));
      expect(captured.mounted, isTrue);
      expect(routeReturned, isFalse);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(routeReturned, isTrue);
      expect(captured.mounted, isFalse);
    },
  );
  test('created mode requires a fresh run and the exact full source pin', () {
    expect(() => _validate(), returnsNormally);
    expect(() => _validate(role: 'member', platform: 'macos'), returnsNormally);
    expect(() => _validate(run: adapter.joinNativeRun), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v1'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v2'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v3'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v4'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v5'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v6'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v7'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v8'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v9'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v15'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v17'), throwsA(anything));
    expect(() => _validate(productRevision: _tree), throwsA(anything));
    expect(
      () => _validate(revision: 'short', productRevision: 'short'),
      throwsA(anything),
    );
    expect(
      () => _validate(
        revision: adapter.joinNativeProductRevision,
        productRevision: adapter.joinNativeProductRevision,
      ),
      throwsA(anything),
    );
    expect(() => _validate(role: 'member'), throwsA(anything));
  });

  test('legacy defaults retain their exact run and product pin', () {
    expect(
      () => adapter.validateJoinNativeDefines(
        enabled: true,
        run: adapter.joinNativeRun,
        role: 'owner',
        platform: 'windows',
        revision: _revision,
        tree: _tree,
        adapter: _adapterHash,
      ),
      returnsNormally,
    );
    expect(() => _validate(createdMode: false), throwsA(anything));
    expect(
      adapter.joinNativeNamespace(adapter.joinNativeRun, 'owner'),
      'synthetic.company.join.j60-join-v10.owner',
    );
    expect(
      adapter.joinNativeNamespace(
        adapter.createdJobNativeRun,
        'owner',
        createdMode: true,
      ),
      'synthetic.company.created.j61-created-v16.owner',
    );
    expect(
      () => adapter.joinNativeNamespace(
        adapter.joinNativeRun,
        'owner',
        createdMode: true,
      ),
      throwsA(anything),
    );
  });

  test('public UI completion remains pending until its button is released', () {
    adapter.CreatedJobNativeUiState state(
      String status, {
      bool busy = false,
      bool error = false,
    }) => adapter.createdJobNativeUiState(
      status: status,
      errorVisible: error,
      busy: busy,
    );
    expect(
      state('Checking Job sync permissions.'),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Exchanging Job holdings with the verified peer.'),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.', busy: true),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.'),
      adapter.CreatedJobNativeUiState.complete,
    );
    expect(
      state(
        'Confirmed sent 0, received 0. More Jobs pending. Pair again and retry Sync Now.',
      ),
      adapter.CreatedJobNativeUiState.incomplete,
    );
    expect(
      state(
        'Job sync incomplete. Confirmed sent 0, received 0. Pair again and retry Sync Now.',
      ),
      adapter.CreatedJobNativeUiState.incomplete,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.', error: true),
      adapter.CreatedJobNativeUiState.error,
    );
    expect(
      state(
        'Trusted peer authenticated. Verification alone does not exchange Jobs.',
      ),
      adapter.CreatedJobNativeUiState.idle,
    );
    expect(
      state('Unrecognized future product copy'),
      adapter.CreatedJobNativeUiState.unknown,
    );
  });

  test(
    'partial created fixtures cannot be adopted for an interruption retry',
    () {
      final root = Directory.systemTemp.createTempSync('j61-adapter-boundary-');
      addTearDown(() => root.deleteSync(recursive: true));
      bool validate() => adapter.validateJoinNativeExistingRoot(
        root,
        run: adapter.createdJobNativeRun,
        role: 'owner',
        revision: _revision,
        tree: _tree,
        adapter: _adapterHash,
        createdMode: true,
        productRevision: _revision,
      );
      expect(validate, throwsA(anything));
      final receipt = <String, Object?>{
        'format': 1,
        'passed': true,
        'run': adapter.createdJobNativeRun,
        'role': 'owner',
        'namespace': adapter.joinNativeNamespace(
          adapter.createdJobNativeRun,
          'owner',
          createdMode: true,
        ),
        'sourceRevision': _revision,
        'sourceTree': _tree,
        'adapterSha256': _adapterHash,
        'productRevision': _revision,
        'root': root.path,
        'locked': true,
        'mode': 'created-jobs',
        'schema': 8,
        'createdJobsComplete': false,
        'bothJobsRendered': true,
        'receiptCountVerifiedBeforeLock': 2,
        'identity': {
          for (final key in [
            'installation',
            'generation',
            'publicKeySha256',
            'storeGeneration',
            'company',
            'shop',
            'user',
            'device',
          ])
            key: key,
        },
      };
      final file = File(p.join(root.path, 'join-exercise.json'));
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate, throwsA(anything));
      receipt['createdJobsComplete'] = true;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate(), isTrue);
      receipt['sourceTree'] = _revision;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate, throwsA(anything));
    },
  );
}
