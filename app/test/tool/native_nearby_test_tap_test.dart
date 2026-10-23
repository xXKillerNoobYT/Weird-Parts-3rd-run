import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_crypto.dart';
import '../../tool/native_nearby_test_tap.dart';

void main() {
  testWidgets('grant changing during pointer preparation prevents Match', (
    tester,
  ) async {
    var current = true;
    var matches = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Listener(
            onPointerDown: (_) {
              current = false;
            },
            child: FilledButton(
              onPressed: () {
                matches++;
              },
              child: const Text('Match'),
            ),
          ),
        ),
      ),
    );
    var rejected = false;
    try {
      await guardedNativeTap(
        tester,
        find.text('Match'),
        isStillCurrent: () => current,
      );
    } on NativeTestFailure {
      rejected = true;
    }
    await tester.pump();
    expect(rejected, true);
    expect(matches, 0);
  });

  testWidgets('unchanged grant activates the rendered control exactly once', (
    tester,
  ) async {
    var matches = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilledButton(
            onPressed: () {
              matches++;
            },
            child: const Text('Match'),
          ),
        ),
      ),
    );
    await guardedNativeTap(
      tester,
      find.text('Match'),
      isStillCurrent: () => true,
    );
    await tester.pump();
    expect(matches, 1);
  });
}
