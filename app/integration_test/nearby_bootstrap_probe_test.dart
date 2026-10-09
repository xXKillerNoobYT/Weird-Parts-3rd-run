import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wired_parts/features/nearby/nearby_page.dart';
import 'package:wired_parts/features/nearby/nearby_wifi.dart';

import '../tool/nearby_lan_validation.dart' as validation;

void _guardProbe() {
  const enabled = bool.fromEnvironment('NATIVE_NEARBY_TEST_MODE');
  const run = String.fromEnvironment('LAN_VALIDATION_RUN');
  const role = String.fromEnvironment('LAN_VALIDATION_ROLE');
  const prefix = 'nearby-integration-probe-';

  if (!Platform.isWindows && !Platform.isMacOS) {
    throw StateError('The bootstrap probe requires native Windows or macOS.');
  }
  if (!enabled) {
    throw StateError('The bootstrap probe requires explicit native test mode.');
  }
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$').hasMatch(run) ||
      !run.startsWith(prefix) ||
      run.length == prefix.length) {
    throw StateError('The bootstrap probe requires a separate synthetic run.');
  }
  if (role != 'sender' && role != 'receiver') {
    throw StateError('The bootstrap probe requires a sender or receiver role.');
  }
}

void main() {
  _guardProbe();
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'isolated native bootstrap renders Jobs and More and reads Wi-Fi',
    (tester) async {
      const run = String.fromEnvironment('LAN_VALIDATION_RUN');
      const role = String.fromEnvironment('LAN_VALIDATION_ROLE');

      await validation.main();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 30),
      );
      expect(find.widgetWithText(AppBar, 'Jobs'), findsOneWidget);
      expect(find.text('Synthetic $role shop $run'), findsOneWidget);

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 30),
      );
      expect(find.widgetWithText(AppBar, 'More'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Nearby'), findsOneWidget);
      expect(find.byType(NearbyPage), findsNothing);

      await readNearbyWifiNetwork().timeout(const Duration(seconds: 10));
      binding.reportData = <String, dynamic>{
        'format': 1,
        'probe': 'native-nearby-bootstrap',
        'platform': Platform.isWindows ? 'windows' : 'macos',
        'run': run,
        'role': role,
        'jobsRendered': true,
        'moreRendered': true,
        'nearbyControlRendered': true,
        'wifiChannelIdentified': true,
        'nearbyRouteOpened': false,
        'transportStarted': false,
      };
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
