import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late AppDatabase db;
  late PinService pin;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    pin = PinService(db.settingsDao);
  });

  tearDown(() async => db.close());

  test('no PIN set means catalog unlocked until set', () async {
    expect(await pin.isPinSet(), isFalse);
  });

  test('set and unlock with correct PIN', () async {
    await pin.setPin('1357');
    expect(await pin.isPinSet(), isTrue);
    expect(await pin.unlock('1357'), isTrue);
    expect(pin.isUnlocked, isTrue);
  });

  test('wrong PIN does not unlock', () async {
    await pin.setPin('1357');
    expect(await pin.unlock('0000'), isFalse);
    expect(pin.isUnlocked, isFalse);
  });
}
