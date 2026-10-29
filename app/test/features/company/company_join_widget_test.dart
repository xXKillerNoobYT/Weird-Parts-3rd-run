import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/company/company_join_page.dart';
import 'package:wired_parts/features/company/company_gate.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';

import 'company_join_test.dart'
    show
        JoinFixture,
        joinChannels,
        sqlSnapshot,
        activateFixtureB,
        expectJoinProtectedUnchanged;

Future<void> joinWidgetSignal(
  WidgetTester tester,
  bool Function() ready, {
  int attempts = 400,
}) async {
  for (var i = 0; i < attempts && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(ready(), isTrue);
}

class JoinLoopbackHttpOverrides extends HttpOverrides {}

enum _PeerAckOutcome {
  success,
  refused,
  jobsAvailable,
  lateRefusalAfterJobs,
  newerError,
  closed,
  replacedPair,
}

void main() {
  for (final outcome in _PeerAckOutcome.values) {
    testWidgets(
      'retained peer acknowledgment ${outcome.name} preserves current status and data',
      (tester) => HttpOverrides.runWithHttpOverrides(() async {
        late JoinFixture f;
        late NearbyController a;
        late NearbyController b;
        late OwnerSession member;
        await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(() async {
            f = await JoinFixture.create();
            await activateFixtureB(f);
            member = await f.bEnrollment.signIn('1234');
            await joinChannels(
              onPaired: (bc, ac) {
                b = bc;
                a = ac;
              },
            );
          }, JoinLoopbackHttpOverrides()),
        );
        final beforeA = await tester.runAsync(() => sqlSnapshot(f.aDb));
        final beforeB = await tester.runAsync(() => sqlSnapshot(f.bDb));
        final protectedA = Map.of(f.aStore.states);
        final protectedB = Map.of(f.bStore.states);
        await tester.binding.setSurfaceSize(const Size(1500, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
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
                  ),
                ),
              ],
            ),
          ),
        );
        final retained = find.byKey(
          ValueKey('company-peer-${f.owner.identity.deviceId}'),
        );
        await joinWidgetSignal(tester, () => retained.evaluate().isNotEmpty);
        final buttons = find.byKey(const Key('company-peer-verify'));
        expect(tester.widget<FilledButton>(buttons.at(1)).onPressed, isNull);
        await tester.tap(retained);
        await tester.pump();
        final acknowledgmentHeld = Completer<void>();
        final releaseAcknowledgment = Completer<void>();
        final acknowledgmentReturned = Completer<void>();
        addTearDown(() {
          if (!releaseAcknowledgment.isCompleted) {
            releaseAcknowledgment.complete();
          }
        });
        final receive = b.onJoinMessage!;
        b.onJoinMessage = (pair, wire) async {
          final reply = await receive(pair, wire);
          if (wire['kind'] == 'peer-ack') {
            acknowledgmentHeld.complete();
            await releaseAcknowledgment.future;
            acknowledgmentReturned.complete();
            if (outcome == _PeerAckOutcome.refused ||
                outcome == _PeerAckOutcome.lateRefusalAfterJobs) {
              throw StateError('Test acknowledgment response refused');
            }
          }
          return reply;
        };
        await tester.runAsync(() => tester.tap(buttons.at(1)));
        const pending = 'Trusted peer authenticated. Confirming completion.';
        const verified =
            'Trusted peer authenticated. Verification alone does not exchange Jobs.';
        await joinWidgetSignal(tester, () => acknowledgmentHeld.isCompleted);
        expect(find.text(pending), findsOneWidget);
        expect(find.text(verified), findsOneWidget);
        String? newerError;
        const available =
            'Ready to exchange Jobs with this verified peer while this page is open and unlocked. Either device can choose Sync Now.';
        if (outcome == _PeerAckOutcome.jobsAvailable ||
            outcome == _PeerAckOutcome.lateRefusalAfterJobs) {
          await tester.runAsync(
            () => tester.tap(
              find.byKey(const Key('company-jobs-enable-sync')).first,
            ),
          );
          await joinWidgetSignal(
            tester,
            () => find.text(available).evaluate().isNotEmpty,
          );
        } else if (outcome == _PeerAckOutcome.newerError) {
          await tester.runAsync(
            () => tester.tap(find.byKey(const Key('company-user-provision'))),
          );
          await joinWidgetSignal(
            tester,
            () => find
                .byKey(const Key('company-join-error'))
                .evaluate()
                .isNotEmpty,
          );
          newerError = tester
              .widget<Text>(find.byKey(const Key('company-join-error')))
              .data;
        } else if (outcome == _PeerAckOutcome.closed) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          await tester.pump();
        } else if (outcome == _PeerAckOutcome.replacedPair) {
          final oldPair = a.pairedJoinSession;
          final peer = a.state.pairedPeer!;
          await tester.runAsync(() async {
            await a.pair(peer);
            await b.confirmCode();
            await a.confirmCode();
          });
          expect(a.pairedJoinSession, isNot(same(oldPair)));
        }
        releaseAcknowledgment.complete();
        await joinWidgetSignal(
          tester,
          () => acknowledgmentReturned.isCompleted,
        );
        if (outcome == _PeerAckOutcome.success) {
          await joinWidgetSignal(
            tester,
            () => find.text(verified).evaluate().length == 2,
          );
          expect(find.text(pending), findsNothing);
        } else if (outcome == _PeerAckOutcome.refused) {
          await joinWidgetSignal(
            tester,
            () => find
                .byKey(const Key('company-join-error'))
                .evaluate()
                .isNotEmpty,
          );
          expect(find.text(pending), findsOneWidget);
          expect(find.text(verified), findsOneWidget);
        } else {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
          if (outcome == _PeerAckOutcome.jobsAvailable ||
              outcome == _PeerAckOutcome.lateRefusalAfterJobs) {
            expect(find.text(available), findsOneWidget);
            expect(find.byKey(const Key('company-join-error')), findsNothing);
          } else if (outcome == _PeerAckOutcome.newerError) {
            expect(find.text(newerError!), findsOneWidget);
            expect(find.text(pending), findsOneWidget);
          } else if (outcome == _PeerAckOutcome.closed) {
            expect(find.text('Company connection closed'), findsNWidgets(2));
            expect(find.byKey(const Key('company-join-error')), findsNothing);
          } else {
            expect(find.text(pending), findsOneWidget);
            expect(find.text(verified), findsOneWidget);
            expect(find.byKey(const Key('company-join-error')), findsNothing);
          }
        }
        expect(await tester.runAsync(() => sqlSnapshot(f.aDb)), beforeA);
        expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), beforeB);
        expectJoinProtectedUnchanged(f.aStore, protectedA);
        expectJoinProtectedUnchanged(f.bStore, protectedB);
        await tester.runAsync(() async {
          await a.dispose();
          await b.dispose();
          await f.closeAndCheckOwnerData();
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, JoinLoopbackHttpOverrides()),
    );
  }

  testWidgets(
    'saved additional user status survives a delayed provisioning request response',
    (tester) => HttpOverrides.runWithHttpOverrides(() async {
      late JoinFixture f;
      late NearbyController a;
      late NearbyController b;
      late OwnerSession member;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          f = await JoinFixture.create();
          await activateFixtureB(f);
          member = await f.bEnrollment.signIn('1234');
          await f.aEnrollment.createRestrictedUser(
            owner: f.owner,
            requestId: '9f5329f7-9c27-4a7c-aeab-d72d9ac35945',
            name: 'Sam Builder',
            pin: '0123',
          );
          await joinChannels(
            onPaired: (bc, ac) {
              b = bc;
              a = ac;
            },
          );
        }, JoinLoopbackHttpOverrides()),
      );
      await tester.binding.setSurfaceSize(const Size(1500, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
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
                ),
              ),
            ],
          ),
        ),
      );
      final retained = find.byKey(
        ValueKey('company-peer-${f.owner.identity.deviceId}'),
      );
      await joinWidgetSignal(tester, () => retained.evaluate().isNotEmpty);
      await tester.tap(retained);
      await tester.pump();
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-peer-verify')).at(1)),
      );
      final provision = find.byKey(const Key('company-user-provision'));
      await joinWidgetSignal(tester, () => provision.evaluate().isNotEmpty);
      final responseHeld = Completer<void>();
      final releaseResponse = Completer<void>();
      addTearDown(() {
        if (!releaseResponse.isCompleted) releaseResponse.complete();
      });
      final receive = a.onJoinMessage!;
      a.onJoinMessage = (pair, wire) async {
        final reply = await receive(pair, wire);
        if (wire['kind'] == 'user-provision-request') {
          responseHeld.complete();
          await releaseResponse.future;
        }
        return reply;
      };
      await tester.runAsync(() => tester.tap(provision));
      final accept = find.byKey(const Key('company-user-provision-accept'));
      await joinWidgetSignal(tester, () => accept.evaluate().isNotEmpty);
      await tester.runAsync(() => tester.tap(accept));
      const saved =
          'Additional user saved on this installation. Close this page and switch user to sign in offline.';
      await joinWidgetSignal(
        tester,
        () =>
            responseHeld.isCompleted && find.text(saved).evaluate().isNotEmpty,
      );
      releaseResponse.complete();
      await joinWidgetSignal(
        tester,
        () => find
            .text(
              'The retained installation confirmed the additional user is saved. Repeating this transfer preserves PIN attempts.',
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text(saved), findsOneWidget);
      expect(
        find.text(
          'Confirmed this user and installation. Waiting for protected provisioning.',
        ),
        findsNothing,
      );
      expect(
        (await tester.runAsync(() => f.bEnrollment.listCompanyUsers()))!
            .map((user) => user.name),
        contains('Sam Builder'),
      );
      await tester.runAsync(() async {
        await a.dispose();
        await b.dispose();
        await f.closeAndCheckOwnerData();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, JoinLoopbackHttpOverrides()),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'real paired dispatcher requires approval then consent and confirms rootless activation',
    (tester) => HttpOverrides.runWithHttpOverrides(() async {
      late JoinFixture f;
      late NearbyController b;
      late NearbyController a;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          f = await JoinFixture.create();
          await joinChannels(
            onPaired: (bc, ac) {
              b = bc;
              a = ac;
            },
          );
        }, JoinLoopbackHttpOverrides()),
      );
      final bBefore = await tester.runAsync(() => sqlSnapshot(f.bDb));
      await tester.binding.setSurfaceSize(const Size(1500, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              Expanded(
                child: CompanyJoinPage(
                  enrollment: f.aEnrollment,
                  approver: f.owner,
                  createController: (_) => a,
                ),
              ),
              Expanded(
                child: CompanyJoinPage(
                  enrollment: f.bEnrollment,
                  createController: (_) => b,
                ),
              ),
            ],
          ),
        ),
      );
      await joinWidgetSignal(
        tester,
        () =>
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('company-join-request')),
                )
                .onPressed !=
            null,
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-join-request'))),
      );
      await joinWidgetSignal(
        tester,
        () =>
            find.byKey(const Key('company-join-approve')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const Key('company-join-company')), findsNothing);
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), bBefore);
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-join-approve'))),
      );
      await joinWidgetSignal(
        tester,
        () =>
            find.byKey(const Key('company-join-consent')).evaluate().isNotEmpty,
      );
      expect(await tester.runAsync(() => sqlSnapshot(f.bDb)), bBefore);
      expect(
        await tester.runAsync(() => f.bEnrollment.readStatus()),
        CompanyBootstrapStatus.unjoined,
      );
      await tester.ensureVisible(find.byKey(const Key('company-join-consent')));
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('company-join-consent'))),
      );
      await joinWidgetSignal(
        tester,
        () => find
            .text('The other installation confirmed activation.')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        await tester.runAsync(() => f.bEnrollment.readStatus()),
        CompanyBootstrapStatus.active,
      );
      expect(
        await tester.runAsync(
          () => f.aDb.select(f.aDb.companyJoinEvents).get(),
        ),
        hasLength(2),
      );
      expect(
        (await tester.runAsync(() => f.bEnrollment.signIn('1234')))!
            .identity
            .userId,
        f.owner.identity.userId,
      );
      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      });
      await tester.pump();
      expect(find.text('Company connection closed'), findsNWidgets(2));
      expect(find.byKey(const Key('company-join-company')), findsNothing);
      expect(find.byKey(const Key('company-join-recipient')), findsNothing);
      await tester.runAsync(() async {
        await a.dispose();
        await b.dispose();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() => f.bEnrollment.signOut());
      await tester.pumpWidget(
        MaterialApp(
          home: CompanyBootstrapGate(db: f.bDb, installation: f.b),
        ),
      );
      await joinWidgetSignal(
        tester,
        () => find.byKey(const Key('company-signin')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const Key('company-enroll-open')), findsNothing);
      expect(find.byKey(const Key('create-company')), findsNothing);
      await tester.runAsync(() async {
        await f.closeAndCheckOwnerData();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 25));
    }, JoinLoopbackHttpOverrides()),
  );
}
