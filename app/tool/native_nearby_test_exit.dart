import 'package:flutter/services.dart';

/// Use the public native exit channel because the test binding overrides
/// ServicesBinding.exitApplication to cancel without contacting the embedder.
/// A channel reply is not process-exit evidence; acquire that externally.
Future<void> requestNativeTestExit() async {
  await SystemChannels.platform.invokeMethod<Object?>(
    'System.exitApplication',
    {'type': 'cancelable', 'exitCode': 0},
  );
}
