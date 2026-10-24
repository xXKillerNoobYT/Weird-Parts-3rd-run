import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

String _canonical(Object? value) {
  Object? sorted(Object? item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(item[key])};
    }
    if (item is List) return item.map(sorted).toList();
    return item;
  }

  return jsonEncode(sorted(value));
}

Map<String, Object?> maximumDisableRecord(String name, {int authority = 17}) {
  const id = 'ffffffff-ffff-4fff-bfff-ffffffffffff';
  final signature = base64Encode(List<int>.filled(64, 255));
  final key = base64Encode(List<int>.filled(32, 255));
  final certificate = _canonical({
    'body': {
      'v': 1,
      'kind': 'company.user.authority@1',
      'company': id,
      'shop': id,
      'authority': authority,
      'facts': 'f' * 64,
      'user': id,
      'name': name,
      'credential': 1,
      'permission': 1,
      'capabilities': ['createJob'],
      'request': id,
      'issuer': id,
      'device': id,
    },
    'signature': signature,
  });
  return {
    'v': 2,
    'c': certificate,
    'b': [id, id, key, id],
    'p': null,
    'a': 8,
    'o': [0, id, id, id, id, key, id, id],
    'r': signature,
    'd': [
      1,
      id,
      signature,
      [0, id, id, id, key, id, id],
      signature,
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('maximum integer canonical capacity stays bounded without a write', () {
    final bytes = utf8.encode(
      _canonical(maximumDisableRecord('\\' * 64, authority: 9007199254740991)),
    );
    expect(bytes.length, 1980);
    expect(bytes.length, lessThanOrEqualTo(kInstallationStateLimit));
  });

  test('maximum canonical disabled record retains both audits and fits native capacity', () {
    var maximum = 0;
    for (final name in ['\\' * 64, '"' * 64, '😀' * 16, '\u2028' * 21 + 'x']) {
      expect(utf8.encode(name).length, 64);
      final record = maximumDisableRecord(name);
      final bytes = utf8.encode(_canonical(record));
      if (bytes.length > maximum) maximum = bytes.length;
      expect(bytes.length, lessThanOrEqualTo(kInstallationStateLimit));
      expect(record['p'], isNull);
      expect(record['o'], hasLength(8));
      expect(record['r'], isNotNull);
      expect(record['d'], hasLength(5));
    }
    expect(maximum, 1966);
    // ignore: avoid_print
    print(
      'Maximum complete canonical disabled account: $maximum / $kInstallationStateLimit bytes.',
    );
  });

  test('oversize native protected record refuses before invoking any native mutation', () async {
    var nativeCalls = 0;
    const channel = MethodChannel('wired_parts/installation_security');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          nativeCalls++;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await expectLater(
      const NativeInstallationSecureStore().compareAndSwapState(
        companyUserNamespace('synthetic.disable-capacity'),
        expectedRevision: null,
        nextRevision: 'ffffffff-ffff-4fff-bfff-ffffffffffff',
        bytes: Uint8List(kInstallationStateLimit + 1),
      ),
      throwsStateError,
    );
    expect(nativeCalls, 0);
  });
}
