import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/pin_hasher.dart';

void main() {
  test('same PIN verifies against its hash', () {
    final stored = PinHasher.hashPin('2468');
    expect(PinHasher.verify('2468', stored), isTrue);
  });

  test('wrong PIN fails verification', () {
    final stored = PinHasher.hashPin('2468');
    expect(PinHasher.verify('0000', stored), isFalse);
  });

  test('hash is not the raw PIN', () {
    final stored = PinHasher.hashPin('2468');
    expect(stored.contains('2468'), isFalse);
  });
}
