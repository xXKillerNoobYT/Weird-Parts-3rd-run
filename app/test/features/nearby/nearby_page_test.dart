import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_page.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

void main() {
  testWidgets('looking state shows none-found on screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NearbyView(
            state: const NearbyViewState(
              phase: NearbyPhase.looking,
              deviceName: 'Shop Mac',
              deviceId: 'mac',
              status: 'Visible on this Wi‑Fi as Shop Mac.',
            ),
            onRename: () {},
            onPair: (_) {},
            onConfirmCode: () {},
            onRejectCode: () {},
            onAcceptOffer: () {},
            onDeclineOffer: () {},
            onSend: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('Shop Mac'), findsWidgets);
    expect(find.text('None found yet'), findsOneWidget);
    expect(find.textContaining('More → Nearby'), findsOneWidget);
  });

  testWidgets('pairing code and match actions are on screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NearbyView(
            state: const NearbyViewState(
              phase: NearbyPhase.pairing,
              deviceName: 'Shop Mac',
              deviceId: 'mac',
              verifyCode: '123456',
              peerName: 'Shop Windows',
              status: 'Check that Shop Windows shows this same code.',
            ),
            onRename: () {},
            onPair: (_) {},
            onConfirmCode: () {},
            onRejectCode: () {},
            onAcceptOffer: () {},
            onDeclineOffer: () {},
            onSend: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('123456'), findsOneWidget);
    expect(find.text('Match'), findsOneWidget);
    expect(find.text("Codes don't match"), findsOneWidget);
  });

  testWidgets('failure stays on the page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NearbyView(
            state: const NearbyViewState(
              phase: NearbyPhase.failed,
              deviceName: 'Shop Mac',
              deviceId: 'mac',
              error: 'Could not reach Shop Windows. Same Wi‑Fi?',
              status: 'Could not reach Shop Windows. Same Wi‑Fi?',
            ),
            onRename: () {},
            onPair: (_) {},
            onConfirmCode: () {},
            onRejectCode: () {},
            onAcceptOffer: () {},
            onDeclineOffer: () {},
            onSend: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('Nearby failed'), findsOneWidget);
    expect(find.textContaining('Same Wi‑Fi?'), findsWidgets);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('paired peer shows Send this shop', (tester) async {
    const peer = NearbyPeer(
      deviceId: 'win',
      name: 'Shop Windows',
      host: '192.168.1.20',
      port: 1234,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NearbyView(
            state: NearbyViewState(
              phase: NearbyPhase.paired,
              deviceName: 'Shop Mac',
              deviceId: 'mac',
              peers: const [peer],
              pairedPeer: peer,
              status: 'Paired with Shop Windows.',
            ),
            onRename: () {},
            onPair: (_) {},
            onConfirmCode: () {},
            onRejectCode: () {},
            onAcceptOffer: () {},
            onDeclineOffer: () {},
            onSend: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('Send this shop'), findsOneWidget);
    expect(find.text('Shop Windows'), findsWidgets);
  });

  testWidgets('incoming offer shows accept and decline', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NearbyView(
            state: const NearbyViewState(
              phase: NearbyPhase.offering,
              deviceName: 'Shop Mac',
              deviceId: 'mac',
              incoming: NearbyOffer(
                sourceDeviceId: 'win',
                sourceName: 'Shop Windows',
                jobs: 2,
                parts: 5,
                photos: 1,
                bytes: 4096,
              ),
              status: 'Incoming shop',
            ),
            onRename: () {},
            onPair: (_) {},
            onConfirmCode: () {},
            onRejectCode: () {},
            onAcceptOffer: () {},
            onDeclineOffer: () {},
            onSend: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining('Incoming shop from Shop Windows'), findsOneWidget);
    expect(find.text('Accept shop'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
  });
}
