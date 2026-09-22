import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

String _fixturePin() =>
    List.generate(6, (_) => Random.secure().nextInt(10)).join();

Future<PinService> _openMore(WidgetTester tester, {String? initialPin}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final pin = PinService(db.settingsDao);
  if (initialPin != null) await pin.setPin(initialPin);
  await tester.pumpWidget(
    AppScope(
      db: db,
      pin: pin,
      deviceId: 'pin-dialog-test',
      wipeLocalData: () async {},
      restoreFromBackup: (_, _) async {},
      child: const MaterialApp(home: HomeShell()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.more_horiz).last);
  await tester.pumpAndSettle();
  return pin;
}

Future<void> _enterMatchingPin(WidgetTester tester, String value) async {
  await tester.tap(find.widgetWithText(ListTile, 'Set PIN'));
  await tester.pumpAndSettle();
  await _fillPinFields(tester, value);
}

Future<void> _fillPinFields(WidgetTester tester, String value) async {
  final fields = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.at(0), value);
  await tester.tap(fields.at(1));
  await tester.enterText(fields.at(1), value);
  await tester.pump();
  expect(
    tester
        .widget<EditableText>(find.byType(EditableText).last)
        .focusNode
        .hasFocus,
    isTrue,
  );
}

void main() {
  testWidgets(
    'focused Set PIN dialog survives Save and its closing animation',
    (tester) async {
      final pin = await _openMore(tester);
      final fixture = _fixturePin();
      await _enterMatchingPin(tester, fixture);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.takeException() == null,
        isTrue,
        reason: 'Dialog must retain live controllers while closing',
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException() == null,
        isTrue,
        reason: 'Dialog teardown must finish without framework errors',
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(await pin.isPinSet(), isTrue);
      expect(pin.isUnlocked, isFalse);
      expect(await pin.unlock(fixture), isTrue);
    },
  );

  testWidgets('focused Set PIN dialog cancels without storing a PIN', (
    tester,
  ) async {
    final pin = await _openMore(tester);
    await _enterMatchingPin(tester, _fixturePin());
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.takeException() == null,
      isTrue,
      reason: 'Cancel must retain live controllers while closing',
    );
    await tester.pumpAndSettle();
    expect(
      tester.takeException() == null,
      isTrue,
      reason: 'Cancelled dialog must tear down cleanly',
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(await pin.isPinSet(), isFalse);
  });
  testWidgets(
    'changing a locked PIN requires unlock and preserves catalog locking',
    (tester) async {
      final previous = _fixturePin();
      var replacement = _fixturePin();
      while (replacement == previous) {
        replacement = _fixturePin();
      }
      final pin = await _openMore(tester, initialPin: previous);
      await tester.tap(find.widgetWithText(ListTile, 'Change PIN'));
      await tester.pumpAndSettle();
      expect(find.text('Editor PIN'), findsOneWidget);
      final gateField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(gateField, previous);
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();
      await _fillPinFields(tester, replacement);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.takeException() == null,
        isTrue,
        reason: 'Changing PIN must close cleanly',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException() == null, isTrue);
      expect(pin.isUnlocked, isFalse);
      expect(await pin.unlock(previous), isFalse);
      expect(await pin.unlock(replacement), isTrue);
    },
  );
}
