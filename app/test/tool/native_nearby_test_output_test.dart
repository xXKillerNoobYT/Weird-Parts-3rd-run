import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_output.dart';

const stream = '0123456789abcdef';
const accepted = <String, Object>{
  'outcome': 'command',
  'value': {
    'version': 1,
    'sequence': 3,
    'state': 'accepted',
    'outcome': 'pending',
    'inflight': false,
    'effect': 'none',
  },
};

Map<String, dynamic> decodePayload(List<String> lines) {
  final encoded = lines
      .where((line) => line.substring(30).startsWith('D:'))
      .map((line) => line.substring(37))
      .join();
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))))
      as Map<String, dynamic>;
}

List<String> outputLines(NativeTestOutputEncoding value) =>
    value.text.split('\r\n').where((line) => line.isNotEmpty).toList();

void main() {
  inputEchoTests();
  test('matches the independent Python accepted-reply vector', () {
    final lines = nativeTestOutputFrames(
      accepted,
      streamId: stream,
      messageId: 1,
    );
    expect(lines.first, '!W1:$stream:00000001:H:00080:0006:C:00000000000003');
    expect(
      lines[1],
      '!W1:$stream:00000001:S0:79894383433d19fa3be17466cffac8be',
    );
    expect(
      lines[2],
      '!W1:$stream:00000001:S1:91bb081839e8ce2598fa55471d8ca0b5',
    );
    expect(lines.last, '!W1:$stream:00000001:E');
    expect(decodePayload(lines), accepted);
  });

  test('frames UTF-8 bytes as bounded ASCII and ordered data indexes', () {
    final record = <String, Object>{
      'outcome': 'info',
      'value': {'synthetic': 'é🙂漢字' * 300},
    };
    final lines = nativeTestOutputFrames(
      record,
      streamId: stream,
      messageId: 0xffffffff,
    );
    for (final line in lines) {
      expect(ascii.encode(line).length + 2, lessThanOrEqualTo(72));
    }
    final chunks = lines.where((line) => line.substring(30).startsWith('D:'));
    for (final (index, line) in chunks.indexed) {
      expect(line.substring(32, 36), index.toRadixString(16).padLeft(4, '0'));
      expect(line.substring(37).length, lessThanOrEqualTo(32));
    }
    expect(decodePayload(lines), record);
    expect(lines.first.contains(':I:00000000000000'), isTrue);
  });

  test('accepts exactly 65536 UTF-8 bytes and bounds the data count', () {
    final record = <String, Object>{'outcome': 'diagnostic', 'padding': ''};
    record['padding'] = 'A' * (65536 - utf8.encode(jsonEncode(record)).length);
    final lines = nativeTestOutputFrames(
      record,
      streamId: stream,
      messageId: 1,
    );
    expect(lines.first, contains(':H:10000:0aab:D:'));
    expect(lines.length, 2735);
    expect(lines.every((line) => ascii.encode(line).length + 2 <= 72), isTrue);
    expect(decodePayload(lines), record);
  });

  for (final record in <Map<String, Object>>[
    {'outcome': 'diagnostic', 'padding': 'A' * 65536},
    {'outcome': 'diagnostic', 'padding': '🙂' * 20000},
    {'outcome': 'unsupported', 'privateCanary': 'SYNTHETIC_PRIVATE_CANARY'},
    {
      'outcome': 'command',
      'value': {'sequence': -1},
    },
    {
      'outcome': 'command',
      'value': {'sequence': 9007199254740992},
    },
    {
      'outcome': 'command',
      'value': {'sequence': '3'},
    },
  ]) {
    test('invalid output becomes one bounded failure without the record', () {
      final encoder = NativeTestOutputEncoder(framed: true, streamId: stream);
      final failed = encoder.encode(record);
      expect(failed.invalidOutput, isTrue);
      expect(decodePayload(outputLines(failed)), {
        'outcome': 'failed',
        'category': 'invalidOutput',
      });
      expect(failed.text.length, lessThan(1024));
      expect(outputLines(failed).first, contains(':00000001:H:'));
      final next = encoder.encode(accepted);
      expect(next.invalidOutput, isFalse);
      expect(outputLines(next).first, contains(':00000002:H:'));
    });
  }

  test('JSON serialization failure is also a bounded framed failure', () {
    final encoder = NativeTestOutputEncoder(framed: true, streamId: stream);
    final result = encoder.encode({'outcome': 'info', 'value': Object()});
    expect(result.invalidOutput, isTrue);
    expect(decodePayload(outputLines(result)), {
      'outcome': 'failed',
      'category': 'invalidOutput',
    });
  });

  for (final id in [0, -1, 0x100000000]) {
    test('rejects invalid message identity $id', () {
      expect(
        () => nativeTestOutputFrames(accepted, streamId: stream, messageId: id),
        throwsFormatException,
      );
    });
  }
  for (final id in ['', 'ABCDEF0123456789', '0123456789abcde', '0' * 17]) {
    test('rejects malformed stream identity $id', () {
      expect(
        () => nativeTestOutputFrames(accepted, streamId: id, messageId: 1),
        throwsFormatException,
      );
    });
  }

  test('preserves unframed Mac JSON bytes and newline', () {
    final encoder = NativeTestOutputEncoder(framed: false);
    final record = <String, Object>{'outcome': 'anything', 'unicode': 'é🙂'};
    final result = encoder.encode(record);
    expect(result.text, '${jsonEncode(record)}\n');
    expect(result.invalidOutput, isFalse);
  });

  test(
    'coordinator generic kind preserves sessions, grants and five booleans',
    () {
      final encoder = NativeTestOutputEncoder(
        framed: true,
        allowGeneric: true,
        streamId: stream,
      );
      for (final record in <Map<String, Object>>[
        {
          'outcome': 'sessions-issued',
          'sessions': {'sender': {}, 'receiver': {}},
        },
        {
          'outcome': 'comparison-issued',
          'comparison': {'comparisonId': 1},
        },
        {
          'outcome': 'grants-issued',
          'grants': {'sender': {}, 'receiver': {}},
        },
        {
          'domainMatch': true,
          'assetsMatch': false,
          'profileMatch': true,
          'settingsMatch': false,
          'pinMatch': true,
        },
      ]) {
        final result = encoder.encode(record);
        expect(result.invalidOutput, isFalse);
        expect(outputLines(result).first, contains(':J:00000000000000'));
        expect(decodePayload(outputLines(result)), record);
      }
    },
  );

  test('known coordinator kinds retain their specific kind', () {
    final encoder = NativeTestOutputEncoder(
      framed: true,
      allowGeneric: true,
      streamId: stream,
    );
    expect(
      outputLines(encoder.encode(accepted)).first,
      contains(':C:00000000000003'),
    );
  });
}

void inputEchoTests() {
  Future<void> run(
    EchoProbe probe,
    Future<void> Function() body, {
    bool windows = true,
    bool terminal = true,
  }) => nativeTestGuardInputEcho(
    body,
    windows: windows,
    terminal: terminal,
    readEcho: probe.read,
    writeEcho: probe.write,
  );

  for (final old in [true, false]) {
    test('echo guard restores original $old after awaited body', () async {
      final probe = EchoProbe(old);
      final held = Completer<void>();
      var called = false;
      final pending = run(probe, () async {
        called = true;
        expect(probe.mode, false);
        await held.future;
        expect(probe.mode, false);
      });
      expect(called, true);
      expect(probe.writes, [false]);
      held.complete();
      await pending;
      expect(probe.mode, old);
      expect(probe.writes, [false, old]);
    });
  }
  for (final target in [(false, true), (true, false), (false, false)]) {
    test('echo guard leaves non-Windows or pipe untouched $target', () async {
      final probe = EchoProbe(true)..readFailureAt = 1;
      var called = false;
      await run(
        probe,
        () async {
          called = true;
        },
        windows: target.$1,
        terminal: target.$2,
      );
      expect(called, true);
      expect(probe.reads, 0);
      expect(probe.writes, isEmpty);
    });
  }
  test(
    'echo guard restores after body exception without exposing it',
    () async {
      final probe = EchoProbe(true);
      final original = StateError('private-canary');
      await expectLater(
        run(probe, () async {
          throw original;
        }),
        throwsA(same(original)),
      );
      expect(probe.writes, [false, true]);
      expect(probe.mode, true);
    },
  );
  test(
    'echo guard fails before body when original mode cannot be read',
    () async {
      final probe = EchoProbe(true)..readFailureAt = 1;
      var called = false;
      await expectLater(
        run(probe, () async {
          called = true;
        }),
        throwsA(isA<NativeTestInputEchoFailure>()),
      );
      expect(called, false);
      expect(probe.writes, isEmpty);
    },
  );
  test(
    'echo guard restores even when disable partially changes then throws',
    () async {
      final probe = EchoProbe(true)..writeFailureAt = 1;
      var called = false;
      await expectLater(
        run(probe, () async {
          called = true;
        }),
        throwsA(isA<NativeTestInputEchoFailure>()),
      );
      expect(called, false);
      expect(probe.writes, [false, true]);
      expect(probe.mode, true);
    },
  );
  test('echo guard restores after failed disable readback', () async {
    final probe = EchoProbe(true)..readFailureAt = 2;
    var called = false;
    await expectLater(
      run(probe, () async {
        called = true;
      }),
      throwsA(isA<NativeTestInputEchoFailure>()),
    );
    expect(called, false);
    expect(probe.writes, [false, true]);
    expect(probe.mode, true);
  });
  test(
    'echo guard rejects ineffective disable before body and restores',
    () async {
      final probe = EchoProbe(true)..ignoreWriteAt = 1;
      var called = false;
      await expectLater(
        run(probe, () async {
          called = true;
        }),
        throwsA(isA<NativeTestInputEchoFailure>()),
      );
      expect(called, false);
      expect(probe.writes, [false, true]);
    },
  );
  for (final failure in ['write', 'read', 'unchanged']) {
    test(
      'echo guard rejects failed restoration $failure with fixed error',
      () async {
        final probe = EchoProbe(true);
        if (failure == 'write') probe.writeFailureAt = 2;
        if (failure == 'read') probe.readFailureAt = 3;
        if (failure == 'unchanged') probe.ignoreWriteAt = 2;
        Object? caught;
        try {
          await run(probe, () async {});
        } catch (error) {
          caught = error;
        }
        expect(caught, isA<NativeTestInputEchoFailure>());
        expect(caught.toString(), 'input echo guard failed');
        expect(probe.writes, [false, true]);
      },
    );
  }
}

final class EchoProbe {
  EchoProbe(this.mode);
  bool mode;
  int reads = 0;
  int? readFailureAt, writeFailureAt, ignoreWriteAt;
  final writes = <bool>[];
  bool read() {
    if (++reads == readFailureAt) throw StateError('private-read-canary');
    return mode;
  }

  void write(bool value) {
    writes.add(value);
    if (writes.length != ignoreWriteAt) mode = value;
    if (writes.length == writeFailureAt) {
      throw StateError('private-write-canary');
    }
  }
}
