import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_exit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );

  test(
    'native request contacts embedder while test binding cancels locally',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        return {'response': 'cancel'};
      });
      expect(
        await ServicesBinding.instance.exitApplication(AppExitType.cancelable),
        AppExitResponse.cancel,
      );
      expect(calls, isEmpty);

      await requestNativeTestExit();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'System.exitApplication');
      expect(calls.single.arguments, {'type': 'cancelable', 'exitCode': 0});
    },
  );

  test('native channel failure remains a failed request', () async {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async {
      throw PlatformException(code: 'synthetic-native-exit-failure');
    });
    await expectLater(
      requestNativeTestExit(),
      throwsA(isA<PlatformException>()),
    );
  });
}
