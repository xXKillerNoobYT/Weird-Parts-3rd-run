import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/company/company_join_page.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';

import 'company_join_test.dart'
    show JoinFixture, activateFixtureB, joinChannels, sqlSnapshot;
import 'company_join_widget_test.dart'
    show JoinLoopbackHttpOverrides, joinWidgetSignal;

void main() {
  testWidgets(
    'receiver callback is captured before a closed channel refuses it',
    (tester) => HttpOverrides.runWithHttpOverrides(() async {
      late JoinFixture f;
      late NearbyController a, b;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          f = await JoinFixture.create();
          await activateFixtureB(f);
          await joinChannels(
            onPaired: (bc, ac) {
              b = bc;
              a = ac;
            },
          );
        }, JoinLoopbackHttpOverrides()),
      );
      final diagnostics = <CreatedJobSyncDiagnostic>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CompanyJoinPage(
            enrollment: f.aEnrollment,
            approver: f.owner,
            reconnect: true,
            createController: (_) => a,
            onJobSyncDiagnostic: (diagnostic) {
              diagnostics.add(diagnostic);
              throw StateError('observer failure must not replace refusal');
            },
          ),
        ),
      );
      await joinWidgetSignal(
        tester,
        () =>
            tester
                .widget<TextButton>(find.byKey(const Key('company-join-close')))
                .onPressed !=
            null,
      );
      final receive = a.onJoinMessage!;
      final pair = a.pairedJoinSession!;
      final before = await tester.runAsync(() => sqlSnapshot(f.aDb));
      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      });
      await tester.pump();
      expect(find.text('Company connection closed'), findsOneWidget);
      await tester.runAsync(() async {
        await expectLater(
          receive(pair, {'kind': 'created-jobs'}),
          throwsA(predicate((error) => error.toString() == 'Join is closed')),
        );
      });
      expect(
        diagnostics.first.kind,
        CreatedJobSyncDiagnosticKind.receiverEntered,
      );
      expect(diagnostics.first.receiverCallbackReached, isTrue);
      expect(
        diagnostics.last.result?.failure?.stage,
        CreatedJobSyncStage.channel,
      );
      expect(
        diagnostics.last.result?.failure?.reason,
        CreatedJobSyncReason.unavailable,
      );
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), before);
      await tester.runAsync(() async {
        await a.dispose();
        await b.dispose();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      await tester.pumpWidget(const SizedBox());
    }, JoinLoopbackHttpOverrides()),
  );
  testWidgets(
    'reverification requires explicit Job availability before two-way Sync and repeat',
    (tester) => HttpOverrides.runWithHttpOverrides(() async {
      late JoinFixture f;
      late OwnerSession member;
      late NearbyController a, b;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          f = await JoinFixture.create(allowOwnerAdditions: true);
          await activateFixtureB(f);
          member = await f.bEnrollment.signIn('1234');
          await CompanyJobCommands(enrollment: f.bEnrollment).createJob(
            CreateJob(
              companyId: member.identity.companyId,
              shopId: member.identity.shopId,
              jobId: const Uuid().v4(),
              requestId: const Uuid().v4(),
              name: 'Offline widget Job',
            ),
            ownerSession: member,
          );
          await joinChannels(
            onPaired: (bc, ac) {
              b = bc;
              a = ac;
            },
          );
        }, JoinLoopbackHttpOverrides()),
      );
      stdout.writeln(
        'Job sync widget: enrolled, offline Jobs created and paired',
      );
      final beforeA = await tester.runAsync(() => sqlSnapshot(f.aDb));
      final beforeB = await tester.runAsync(() => sqlSnapshot(f.bDb));
      await tester.binding.setSurfaceSize(const Size(1600, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var freezeEntered = Completer<void>();
      var releaseFreeze = Completer<void>();
      addTearDown(() {
        f.bStore.beforeRead = null;
        if (!releaseFreeze.isCompleted) releaseFreeze.complete();
      });
      Widget connectedPeers() => MaterialApp(
        home: Row(
          children: [
            Expanded(
              child: CompanyJoinPage(
                enrollment: f.aEnrollment,
                approver: f.owner,
                reconnect: true,
                createController: (_) => a,
              ),
            ),
            Expanded(
              child: CompanyJoinPage(
                enrollment: f.bEnrollment,
                approver: member,
                reconnect: true,
                createController: (_) => b,
                onJobSyncDiagnostic: (event) {
                  if (event.kind == CreatedJobSyncDiagnosticKind.started &&
                      event.receiverCallbackReached) {
                    f.bStore.beforeRead = (namespace) {
                      if (namespace == f.b.namespace &&
                          !freezeEntered.isCompleted) {
                        freezeEntered.complete();
                        return releaseFreeze.future;
                      }
                      return null;
                    };
                  }
                },
              ),
            ),
          ],
        ),
      );
      await tester.pumpWidget(connectedPeers());
      final peer = find.byKey(
        ValueKey('company-peer-${member.identity.deviceId}'),
      );
      await joinWidgetSignal(tester, () => peer.evaluate().isNotEmpty);
      stdout.writeln('Job sync widget: retained peer rendered');
      expect(find.byKey(const Key('company-jobs-sync-now')), findsNothing);
      await tester.tap(peer);
      await tester.pump();
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-peer-verify')).at(0)),
      );
      final enable = find.byKey(const Key('company-jobs-enable-sync'));
      await joinWidgetSignal(
        tester,
        () => enable.evaluate().length == 2,
        attempts: 1200,
      );
      expect(find.byKey(const Key('company-jobs-sync-now')), findsNothing);
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), beforeA);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), beforeB);
      stdout.writeln('Job sync widget: proof-only verification complete');
      await tester.runAsync(() => tester.tap(enable.at(0)));
      await joinWidgetSignal(
        tester,
        () =>
            find.byKey(const Key('company-jobs-sync-now')).evaluate().length ==
            1,
        attempts: 1200,
      );
      final oldAvailability =
          a.companySyncDisclosure as CompanyJobSyncAvailability;
      final aPair = a.pairedJoinSession;
      final bPair = b.pairedJoinSession;
      final reversePeer = find.byKey(
        ValueKey('company-peer-${f.owner.identity.deviceId}'),
      );
      await tester.ensureVisible(reversePeer);
      await tester.tap(reversePeer);
      await tester.pump();
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-peer-verify')).at(1)),
      );
      await joinWidgetSignal(
        tester,
        () =>
            tester
                .widget<Text>(
                  find.byKey(const Key('company-join-status')).at(1),
                )
                .data ==
            'Trusted peer authenticated. Verification alone does not exchange Jobs.',
        attempts: 1200,
      );
      expect(a.pairedJoinSession, same(aPair));
      expect(b.pairedJoinSession, same(bPair));
      expect(
        oldAvailability.requireLive,
        throwsA(
          isA<CompanyBootstrapRefusal>().having(
            (error) => error.message,
            'message',
            'Retained peer context changed',
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('company-jobs-sync-now')),
            )
            .onPressed,
        isNull,
      );
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), beforeA);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), beforeB);
      expect(
        enable,
        findsNWidgets(2),
        reason: 'Reverification must offer explicit re-enable on the page holding stale availability',
      );
      await tester.runAsync(() => tester.tap(enable.at(0)));
      await joinWidgetSignal(
        tester,
        () => enable.evaluate().length == 1,
        attempts: 1200,
      );
      expect(a.companySyncDisclosure, isNot(same(oldAvailability)));
      expect(
        (a.companySyncDisclosure as CompanyJobSyncAvailability).requireLive,
        returnsNormally,
      );
      expect(
        oldAvailability.requireLive,
        throwsA(
          isA<CompanyBootstrapRefusal>().having(
            (error) => error.message,
            'message',
            'Manual Job sync is unavailable',
          ),
        ),
      );
      final enableBAction = tester.widget<FilledButton>(enable).onPressed!;
      await tester.runAsync(() => tester.tap(enable));
      final sync = find.byKey(const Key('company-jobs-sync-now'));
      await joinWidgetSignal(
        tester,
        () => sync.evaluate().length == 2,
        attempts: 1200,
      );
      expect(find.textContaining('Ready to exchange Jobs'), findsNWidgets(2));
      stdout.writeln('Job sync widget: both manually available');
      final handling = b.onJoinMessage!;
      final incomingStarted = Completer<void>();
      final releaseStartReply = Completer<void>();
      addTearDown(() {
        if (!releaseStartReply.isCompleted) releaseStartReply.complete();
      });
      b.onJoinMessage = (session, wire) async {
        final reply = await handling(session, wire);
        if (!incomingStarted.isCompleted) {
          incomingStarted.complete();
          await releaseStartReply.future;
        }
        return reply;
      };
      await tester.runAsync(() => tester.tap(sync.at(0)));
      await joinWidgetSignal(tester, () => freezeEntered.isCompleted);
      final receiverEnabledDuringFreeze =
          tester.widget<FilledButton>(sync.at(1)).onPressed != null;
      f.bStore.beforeRead = null;
      releaseFreeze.complete();
      await joinWidgetSignal(tester, () => incomingStarted.isCompleted);
      final receiverEnabledDuringRun =
          tester.widget<FilledButton>(sync.at(1)).onPressed != null;
      releaseStartReply.complete();
      await tester.pump();
      expect(find.byKey(const Key('company-join-busy')), findsOneWidget);
      await joinWidgetSignal(
        tester,
        () =>
            find.textContaining('Job snapshot synced.').evaluate().length ==
                2 ||
            find.byKey(const Key('company-join-error')).evaluate().isNotEmpty ||
            find.textContaining('Job sync incomplete.').evaluate().isNotEmpty,
        attempts: 8000,
      );
      expect(
        find.textContaining('Job snapshot synced.'),
        findsNWidgets(2),
        reason: tester
            .widgetList<Text>(
              find.byWidgetPredicate(
                (w) =>
                    w is Text &&
                    (w.key == const Key('company-join-status') ||
                        w.key == const Key('company-join-error')),
              ),
            )
            .map((w) => w.data)
            .join(' | '),
      );
      expect(
        receiverEnabledDuringFreeze,
        isFalse,
        reason:
            'Local Sync must be disabled while the inbound inventory freezes',
      );
      expect(
        receiverEnabledDuringRun,
        isFalse,
        reason: 'Local Sync must be disabled while receiving the peer run',
      );
      final aJobs = await tester.runAsync(
        () =>
            CompanyJobCommands(enrollment: f.aEnrollment)
                .listJobs(ownerSession: f.owner),
      );
      final bJobs = await tester.runAsync(
        () =>
            CompanyJobCommands(enrollment: f.bEnrollment)
                .listJobs(ownerSession: member),
      );
      expect(aJobs!.map((j) => j.id).toSet(), bJobs!.map((j) => j.id).toSet());
      expect(aJobs, hasLength(2));
      await tester.runAsync(() => tester.tap(sync.at(0)));
      await joinWidgetSignal(
        tester,
        () =>
            find
                    .text('Job snapshot synced. Sent 0, received 0.')
                    .evaluate()
                    .length ==
                2 ||
            find.byKey(const Key('company-join-error')).evaluate().isNotEmpty ||
            find.textContaining('Job sync incomplete.').evaluate().isNotEmpty,
        attempts: 8000,
      );
      expect(
        find.text('Job snapshot synced. Sent 0, received 0.'),
        findsNWidgets(2),
      );
      final confirmedA = await tester.runAsync(() => sqlSnapshot(f.aDb));
      final confirmedB = await tester.runAsync(() => sqlSnapshot(f.bDb));
      freezeEntered = Completer<void>();
      releaseFreeze = Completer<void>();
      await tester.runAsync(() => tester.tap(sync.at(0)));
      await joinWidgetSignal(tester, () => freezeEntered.isCompleted);
      final receivingAvailability =
          b.companySyncDisclosure as CompanyJobSyncAvailability;
      receivingAvailability.close();
      await tester.pumpWidget(connectedPeers());
      await tester.pump();
      expect(enable, findsOneWidget);
      expect(
        tester.widget<FilledButton>(enable).onPressed,
        isNull,
        reason: 'A stale receiving exchange must drain before availability can be replaced',
      );
      await tester.runAsync(() async => enableBAction());
      await joinWidgetSignal(
        tester,
        () => find.byKey(const Key('company-join-error')).evaluate().isNotEmpty,
      );
      expect(b.companySyncDisclosure, same(receivingAvailability));
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), confirmedA);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), confirmedB);
      f.bStore.beforeRead = null;
      releaseFreeze.complete();
      await joinWidgetSignal(
        tester,
        () =>
            tester.widget<FilledButton>(enable).onPressed != null &&
            tester.widget<FilledButton>(sync.at(0)).onPressed != null,
        attempts: 1200,
      );
      expect(b.companySyncDisclosure, same(receivingAvailability));
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), confirmedA);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), confirmedB);
      (a.companySyncDisclosure as CompanyJobSyncAvailability).close();
      await tester.pumpWidget(connectedPeers());
      await tester.pump();
      expect(tester.widget<FilledButton>(sync.at(0)).onPressed, isNull);
      expect(find.byKey(const Key('company-join-busy')), findsNothing);
      expect(
        find.byKey(const Key('company-jobs-last-confirmed')),
        findsNWidgets(2),
      );
      expect(find.textContaining('Pair again and verify'), findsNWidgets(2));
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), confirmedA);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), confirmedB);
      expect(tester.widget<FilledButton>(sync.at(1)).onPressed, isNull);
      final otherPeer = find.byKey(
        ValueKey('company-peer-${member.identity.deviceId}'),
      );
      await tester.ensureVisible(otherPeer);
      await tester.tap(otherPeer);
      await tester.pump();
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-peer-verify')).at(0)),
      );
      await joinWidgetSignal(
        tester,
        () =>
            tester
                .widget<Text>(
                  find.byKey(const Key('company-join-status')).at(0),
                )
                .data ==
            'Trusted peer authenticated. Verification alone does not exchange Jobs.',
        attempts: 1200,
      );
      expect(tester.widget<FilledButton>(sync.at(1)).onPressed, isNull);
      expect(find.textContaining('Pair again and verify'), findsNWidgets(2));
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), confirmedA);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), confirmedB);
      final staleB = b.companySyncDisclosure;
      await tester.runAsync(() => f.bEnrollment.signOut());
      await tester.runAsync(() => tester.tap(enable.at(1)));
      await joinWidgetSignal(
        tester,
        () => find.byKey(const Key('company-join-error')).evaluate().isNotEmpty,
      );
      expect(b.companySyncDisclosure, same(staleB));
      expect(tester.widget<FilledButton>(sync.at(1)).onPressed, isNull);
      aPair!.revoke();
      final staleA = a.companySyncDisclosure;
      await tester.runAsync(() => tester.tap(enable.at(0)));
      await joinWidgetSignal(
        tester,
        () =>
            find.byKey(const Key('company-join-error')).evaluate().length == 2,
      );
      expect(a.companySyncDisclosure, same(staleA));
      expect(tester.widget<FilledButton>(sync.at(0)).onPressed, isNull);
      expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), confirmedA);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), confirmedB);
      stdout.writeln(
        'Job sync widget: one Sync Now produced both production Job lists',
      );
      await tester.runAsync(() async {
        await a.dispose();
        await b.dispose();
        await f.closeAndCheckOwnerData();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, JoinLoopbackHttpOverrides()),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
