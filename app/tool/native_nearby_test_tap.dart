import 'package:flutter_test/flutter_test.dart';

import 'native_nearby_test_crypto.dart';

/// Pointer preparation can yield. Recheck the live grant at pointer-up, where
/// a rendered button can actually execute its action, and cancel on change.
Future<void> guardedNativeTap(
  WidgetTester tester,
  Finder target, {
  required bool Function() isStillCurrent,
}) async {
  if (target.evaluate().length != 1 || !isStillCurrent()) {
    rejectNativeTest('control-not-rendered');
  }
  final gesture = await tester.startGesture(tester.getCenter(target));
  var released = false;
  try {
    if (!isStillCurrent()) rejectNativeTest('state-changed');
    // No asynchronous preparation is allowed between this check and up().
    await gesture.up();
    released = true;
  } finally {
    if (!released) await gesture.cancel();
  }
}
