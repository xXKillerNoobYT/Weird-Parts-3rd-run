import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_commands.dart';
import '../../tool/native_nearby_test_crypto.dart';
import '../../tool/native_nearby_test_host.dart';

const run = 'nearby-lifecycle-20261007a';
const canary =
    'SAS739281/PIN1234/http://127.0.0.1:9999/AUTH_CANARY=/PRIVATE_KEY';

final class FakeTransport implements NativeTestHostTransport {
  final calls = <String>[];
  bool configured = false;
  bool failConfigure = false;
  bool failInfo = false;
  Object? infoOverride;
  Object? reply;
  final isolates = ['isolates/123'];
  final isolateReplies = <String, Object?>{};

  Map<String, Object> get infoValue => {
    'version': 1,
    'outcome': 'ready',
    'appPid': 100,
    'run': run,
    'role': 'receiver',
    'deviceId': 'lan-$run-receiver',
    'peerId': 'lan-$run-sender',
    'configured': configured,
    'elapsedMillis': 10,
    'phase': 'looking',
    'sameNearbyState': true,
    'discovered': true,
    'codePresent': false,
  };
  @override
  Future<Object?> getVm() async {
    calls.add('getVM');
    return {
      'isolates': [
        for (final id in isolates) {'id': id},
      ],
    };
  }

  @override
  Future<Object?> getIsolate(String id) async {
    calls.add('getIsolate');
    if (isolateReplies.containsKey(id)) return isolateReplies[id];
    return {
      'id': id,
      'extensionRPCs': [
        'ext.wired_parts.nearbyTest.info',
        'ext.wired_parts.nearbyTest.configure',
        'ext.wired_parts.nearbyTest.command',
      ],
    };
  }

  @override
  Future<Object?> info(String id) async {
    calls.add('info');
    if (failInfo) throw StateError(canary);
    return infoOverride ?? infoValue;
  }

  @override
  Future<Object?> configure(String id, String data) async {
    calls.add('configure');
    if (failConfigure) throw StateError(canary);
    configured = true;
    return {'version': 1, 'outcome': 'configured'};
  }

  @override
  Future<Object?> command(String id, String data) async {
    calls.add('command');
    return reply;
  }
}

final class Fixture {
  final transport = FakeTransport();
  late final host = NativeTestHost(
    transport: transport,
    run: run,
    platform: 'windows',
  );
  final session = TestSession(
    epoch: 'epoch-a',
    run: run,
    role: TestRole.receiver,
    deviceId: 'lan-$run-receiver',
    peerId: 'lan-$run-sender',
    encryptionPublicKey: base64Url.encode(List.filled(32, 1)),
    signingPublicKey: base64Url.encode(List.filled(32, 2)),
  );

  Future<void> ready() async {
    expect(await host.discover(), isTrue);
    expect(
      await host.handleLine(
        jsonEncode({'operation': 'configure', 'session': session.toJson()}),
      ),
      {
        'outcome': 'configure',
        'value': {'version': 1, 'outcome': 'configured'},
      },
    );
    transport.calls.clear();
  }

  String request({
    NativeTestAction action = NativeTestAction.pair,
    ComparisonChallenge? comparison,
  }) => jsonEncode({
    'operation': 'command',
    'command': jsonDecode(
      NativeTestCommand.encodeRequest(
        session: session,
        sequence: 1,
        action: action,
        deadlineMillis: 1000,
        comparison: comparison,
        snapshotStage: action == NativeTestAction.snapshot
            ? PrivateSnapshotStage.baseline
            : null,
      ),
    ),
  });
  Map<String, Object> result(Object value, {String effect = 'none'}) => {
    'version': 1,
    'sequence': 1,
    'state': 'completed',
    'outcome': 'success',
    'inflight': false,
    'effect': effect,
    'result': value,
  };
}

Map<String, Object> sealedObservation(
  Fixture f,
  ComparisonChallenge comparison,
) => {
  'version': 1,
  'epoch': f.session.epoch,
  'run': run,
  'role': 'receiver',
  'comparison': comparison.toJson(),
  'ephemeralPublicKey': base64Url.encode(List.filled(32, 3)),
  'nonce': base64Url.encode(List.filled(12, 4)),
  'ciphertext': base64Url.encode(utf8.encode(canary)),
  'tag': base64Url.encode(List.filled(16, 5)),
};

Map<String, Object> sealedSnapshot(Fixture f) => {
  'version': 1,
  'epoch': f.session.epoch,
  'run': run,
  'role': 'receiver',
  'stage': 'baseline',
  'ordinal': 1,
  'ephemeralPublicKey': base64Url.encode(List.filled(32, 3)),
  'nonce': base64Url.encode(List.filled(12, 4)),
  'ciphertext': base64Url.encode(utf8.encode(canary)),
  'tag': base64Url.encode(List.filled(16, 5)),
};

void main() {
  test(
    'asynchronous output failures become fixed exit status without raw errors',
    () async {
      final savedExit = exitCode;
      try {
        await nativeTestHostOutputDone(Future<void>.error(StateError(canary)));
        expect(exitCode, 1);
      } finally {
        exitCode = savedExit;
      }
    },
  );
  test('unsupported runs and platforms never construct launcher state', () {
    for (final candidate in ['arbitrary', canary]) {
      expect(
        () => NativeTestHost(
          transport: FakeTransport(),
          run: candidate,
          platform: 'windows',
        ),
        throwsA(isA<NativeTestHostFailure>()),
      );
    }
    expect(
      () => NativeTestHost(
        transport: FakeTransport(),
        run: run,
        platform: 'linux',
      ),
      throwsA(isA<NativeTestHostFailure>()),
    );
  });

  test('discovery requires exactly one matching actual VM isolate', () async {
    final f = Fixture();
    expect(await f.host.discover(), isTrue);
    expect(f.transport.calls, ['getVM', 'getIsolate']);
    final output = await f.host.handleLine('{"operation":"info"}');
    expect(output, {
      'outcome': 'info',
      'isolateId': 'isolates/123',
      'value': f.transport.infoValue,
    });
    f.transport.isolates.add('isolates/124');
    await expectLater(f.host.discover(), throwsA(isA<NativeTestHostFailure>()));
  });

  test('discovery skips workers without registered extensions', () async {
    for (final includeNull in [false, true]) {
      final f = Fixture();
      f.transport.isolates.insert(0, 'isolates/125');
      f.transport.isolateReplies['isolates/125'] = {
        'id': 'isolates/125',
        if (includeNull) 'extensionRPCs': null,
      };
      expect(await f.host.discover(), isTrue);
      expect(
        (await f.host.handleLine('{"operation":"info"}'))['isolateId'],
        'isolates/123',
      );
    }
  });

  test('collected isolate permits main match and later rediscovery', () async {
    final f = Fixture();
    f.transport.isolateReplies['isolates/123'] = {
      'type': 'Sentinel',
      'kind': 'Collected',
    };
    expect(await f.host.discover(), isFalse);
    f.transport.isolates.add('isolates/126');
    expect(await f.host.discover(), isTrue);
    expect(
      (await f.host.handleLine('{"operation":"info"}'))['isolateId'],
      'isolates/126',
    );
  });

  test('worker extension types and isolate identity remain strict', () async {
    for (final reply in <Object>[
      {'id': 'isolates/125', 'extensionRPCs': canary},
      {
        'id': 'isolates/125',
        'extensionRPCs': [1],
      },
      {'id': 'isolates/999'},
      {'type': 'Sentinel', 'kind': 'Expired'},
    ]) {
      final f = Fixture();
      f.transport.isolates.insert(0, 'isolates/125');
      f.transport.isolateReplies['isolates/125'] = reply;
      await expectLater(
        f.host.discover(),
        throwsA(isA<NativeTestHostFailure>()),
      );
    }
  });

  test('missing isolate is notReady and identity changes reject', () async {
    final f = Fixture();
    f.transport.isolates.clear();
    expect(await f.host.discover(), isFalse);
    expect(await f.host.handleLine('{"operation":"info"}'), {
      'outcome': 'failed',
      'category': 'notReady',
    });
    f.transport.isolates.add('isolates/123');
    expect(await f.host.discover(), isTrue);
    f.transport.isolates[0] = 'isolates/124';
    await expectLater(f.host.discover(), throwsA(isA<NativeTestHostFailure>()));
  });

  test(
    'only exact info configure command operations can call transport',
    () async {
      final f = Fixture();
      await f.ready();
      for (final input in [
        '{"operation":"evaluate","expression":"$canary"}',
        '{"operation":"info","vmMethod":"getObject"}',
        '{"operation":"command","shell":"$canary"}',
        jsonEncode(canary),
        'x' * 65537,
      ]) {
        final output = await f.host.handleLine(input);
        expect(output['outcome'], 'failed');
        expect(jsonEncode(output).contains(canary), isFalse);
        expect(f.transport.calls, isEmpty);
      }
    },
  );

  test('configure checks fixed native identity and occurs only once', () async {
    final f = Fixture();
    await f.ready();
    final output = await f.host.handleLine(
      jsonEncode({'operation': 'configure', 'session': f.session.toJson()}),
    );
    expect(output, {'outcome': 'failed', 'category': 'alreadyConfigured'});
    expect(f.transport.calls, isEmpty);
    final other = Fixture();
    await other.host.discover();
    expect(
      await other.host.handleLine(
        jsonEncode({
          'operation': 'configure',
          'session': {...other.session.toJson(), 'peerId': 'other-device'},
        }),
      ),
      {'outcome': 'failed', 'category': 'identityMismatch'},
    );
    expect(other.transport.calls.contains('configure'), isFalse);
  });

  test(
    'concurrent host requests cannot duplicate a configure or RPC',
    () async {
      final f = Fixture();
      await f.host.discover();
      final source = jsonEncode({
        'operation': 'configure',
        'session': f.session.toJson(),
      });
      final first = f.host.handleLine(source);
      expect(await f.host.handleLine(source), {
        'outcome': 'failed',
        'category': 'busy',
      });
      expect((await first)['outcome'], 'configure');
      expect(
        f.transport.calls.where((method) => method == 'configure').length,
        1,
      );
    },
  );

  test('lost configure response cannot cause second configuration', () async {
    final f = Fixture();
    await f.host.discover();
    f.transport.failConfigure = true;
    final source = jsonEncode({
      'operation': 'configure',
      'session': f.session.toJson(),
    });
    final output = await f.host.handleLine(source);
    expect(output['outcome'], 'failed');
    expect(jsonEncode(output).contains(canary), isFalse);
    expect(await f.host.handleLine(source), {
      'outcome': 'failed',
      'category': 'alreadyConfigured',
    });
    expect(
      f.transport.calls.where((method) => method == 'configure').length,
      1,
    );
  });

  test(
    'command cannot run before configuration or after PID changes',
    () async {
      final f = Fixture();
      await f.host.discover();
      expect(await f.host.handleLine(f.request()), {
        'outcome': 'failed',
        'category': 'notConfigured',
      });
      await f.ready();
      f.transport.infoOverride = {...f.transport.infoValue, 'appPid': 101};
      expect(await f.host.handleLine(f.request()), {
        'outcome': 'failed',
        'category': 'identityMismatch',
      });
      expect(f.transport.calls, ['info']);
    },
  );

  test('valid command UNKNOWN retains inflight and possible effect', () async {
    final f = Fixture();
    await f.ready();
    f.transport.reply = {
      'version': 1,
      'sequence': 1,
      'state': 'unknown',
      'outcome': 'UNKNOWN',
      'inflight': true,
      'effect': 'possible',
    };
    expect(await f.host.handleLine(f.request()), {
      'outcome': 'command',
      'value': f.transport.reply,
    });
    expect(f.transport.calls, ['info', 'command']);
  });

  test(
    'malformed reply schemas and supplied errors cannot leave host',
    () async {
      final f = Fixture();
      await f.ready();
      final accepted = <String, Object>{
        'version': 1,
        'sequence': 1,
        'state': 'accepted',
        'outcome': 'pending',
        'inflight': false,
        'effect': 'none',
      };
      for (final malformed in [
        canary,
        {'error': canary},
        {...accepted, 'rawError': canary},
        {...accepted, 'outcome': canary},
        {...accepted, 'state': canary},
        {...accepted, 'sequence': 2},
        {...accepted, 'inflight': true},
        {...accepted, 'result': canary},
        {...accepted, 'effect': canary},
      ]) {
        f.transport.reply = malformed;
        final output = await f.host.handleLine(f.request());
        expect(output['outcome'], 'failed');
        expect(jsonEncode(output).contains(canary), isFalse);
      }
    },
  );

  test(
    'info canaries unknown fields and raw transport errors never emerge',
    () async {
      final f = Fixture();
      await f.host.discover();
      for (final field in [
        'phase',
        'deviceId',
        'peerId',
        'appPid',
        'elapsedMillis',
        'configured',
        'sameNearbyState',
        'codePresent',
        'rawDump',
      ]) {
        f.transport.infoOverride = {...f.transport.infoValue, field: canary};
        final output = await f.host.handleLine('{"operation":"info"}');
        expect(output['outcome'], 'failed');
        expect(jsonEncode(output).contains(canary), isFalse);
      }
      f.transport.failInfo = true;
      expect(
        jsonEncode(await f.host.handleLine('{"operation":"info"}'))
            .contains(canary),
        isFalse,
      );
    },
  );

  test(
    'typed encrypted observation remains ciphertext with exact challenge',
    () async {
      final f = Fixture();
      await f.ready();
      final comparison = ComparisonChallenge(
        epoch: f.session.epoch,
        leg: 1,
        comparisonId: 1,
        challenge: base64Url.encode(List.filled(32, 3)),
      );
      final observation = {
        'epoch': f.session.epoch,
        'run': run,
        'role': 'receiver',
        'deviceId': f.host.deviceId,
        'peerId': f.host.peerId,
        'phase': 'pairing',
        'sameNearbyState': true,
        'discovered': true,
        'codePresent': true,
        'sealedObservation': sealedObservation(f, comparison),
      };
      f.transport.reply = f.result({
        'outcome': 'success',
        'effect': 'none',
        'observation': observation,
      });
      final output = await f.host.handleLine(
        f.request(action: NativeTestAction.observe, comparison: comparison),
      );
      expect(output['outcome'], 'command');
      expect(jsonEncode(output).contains(canary), isFalse);
      final wrong = ComparisonChallenge(
        epoch: f.session.epoch,
        leg: 1,
        comparisonId: 2,
        challenge: comparison.challenge,
      );
      expect(
        (await f.host.handleLine(
          f.request(action: NativeTestAction.observe, comparison: wrong),
        ))['outcome'],
        'failed',
      );
    },
  );

  test(
    'actual snapshot reply requires encrypted proof and strict summary',
    () async {
      final f = Fixture();
      await f.ready();
      final snapshot = <String, Object>{
        'digest': 'a' * 64,
        'assetsDigest': 'b' * 64,
        'sharedSettingsDigest': 'c' * 64,
        'profileDigest': 'd' * 64,
        'schemaVersion': 15,
        'tableCount': 20,
        'rowCount': 30,
        'assetCount': 0,
        'integrityValid': true,
        'referencesValid': true,
        'profileEqual': true,
        'assetsEqual': true,
        'settingsEqual': false,
        'ownershipEqual': true,
        'sealedProof': sealedSnapshot(f),
        'lastNearbySourceId': f.host.peerId,
        'lastNearbyAtMillis': 500,
      };
      f.transport.reply = f.result({
        'outcome': 'success',
        'effect': 'none',
        'snapshot': snapshot,
      });
      final output = await f.host.handleLine(
        f.request(action: NativeTestAction.snapshot),
      );
      expect(output['outcome'], 'command');
      expect(jsonEncode(output).contains(canary), isFalse);
      snapshot['pinDigest'] = canary;
      expect(
        (await f.host.handleLine(
          f.request(action: NativeTestAction.snapshot),
        ))['outcome'],
        'failed',
      );
      snapshot.remove('pinDigest');
      snapshot.remove('sealedProof');
      expect(
        (await f.host.handleLine(
          f.request(action: NativeTestAction.snapshot),
        ))['outcome'],
        'failed',
      );
    },
  );

  test('banner scanner bounds private raw memory and accepts only loopback banners', () {
    final scanner = NativeTestVmBannerScanner();
    scanner.add(utf8.encode('ordinary failure $canary\n'));
    expect(scanner.privateUri, isNull);
    scanner.add(
      utf8.encode(
        'The Dart VM service is listening on http://192.168.1.1:9999/AUTH=/\n',
      ),
    );
    expect(scanner.privateUri, isNull);
    scanner.add(utf8.encode('x' * 100000));
    expect(scanner.bufferedCharacters, lessThanOrEqualTo(4096));
    scanner.add(
      utf8.encode(
        '\nThe Dart VM service is listening on http://127.0.0.1:9999/',
      ),
    );
    scanner.add(utf8.encode('AUTH_CANARY=/\n'));
    expect(scanner.privateUri?.host, '127.0.0.1');
    expect(scanner.privateUri?.port, 9999);
    expect(scanner.bufferedCharacters, 0);
    expect(scanner.toString().contains('AUTH_CANARY'), isFalse);
  });

  test(
    'stdin scanner bounds oversized and unterminated input without exposing it',
    () async {
      final source = Stream<List<int>>.fromIterable([
        utf8.encode('x' * 100000),
        utf8.encode('\n{"operation":"info"}\n'),
        utf8.encode(canary),
      ]);
      expect(await nativeTestHostInputLines(source).toList(), [
        null,
        '{"operation":"info"}',
        null,
      ]);
    },
  );

  test('desktop VM trace stays bounded and accepts a split trusted banner', () {
    const token = 'SYNTHETIC_AUTH_TOKEN=';
    final scanner = NativeTestVmBannerScanner();
    for (final line in [
      'unrelated http://127.0.0.1:12345/$token/',
      'VM Service URL on device: http://192.0.2.1:12345/$token/',
      'VM Service URL on device: http://127.0.0.1:0/$token/',
      'VM Service URL on device: http://127.0.0.1:65536/$token/',
      'VM Service URL on device: http://127.0.0.1:12345/',
    ]) {
      scanner.add(utf8.encode('$line\n'));
      expect(scanner.privateUri, isNull);
    }
    scanner.add(utf8.encode('VM Service URL on device: ${'x' * 5000}'));
    expect(scanner.bufferedCharacters, lessThanOrEqualTo(4096));
    scanner.add(utf8.encode('\n'));
    expect(scanner.privateUri, isNull);
    for (final chunk in [
      '[ +27 ms] VM Serv',
      'ice URL on dev',
      'ice: http://127.0.',
      '0.1:12345/SYNTHETIC_',
      'AUTH_TOKEN=/\r',
      '\n',
    ]) {
      scanner.add(utf8.encode(chunk));
    }
    expect(scanner.privateUri?.host, '127.0.0.1');
    expect(scanner.privateUri?.port, 12345);
    expect(scanner.privateUri?.path, '/$token/');
    expect(scanner.bufferedCharacters, 0);
    expect(scanner.toString().contains(token), isFalse);
  });

  test('VM response boundary accepts only the matching response', () {
    final response = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'result': {'type': 'VM'},
    });
    expect(
      nativeTestVmResult(
        response,
        method: NativeTestVmMethod.getVM,
        expectedId: 1,
      ),
      {'type': 'VM'},
    );
    expect(
      () => nativeTestVmResult(
        response,
        method: NativeTestVmMethod.getVM,
        expectedId: 2,
      ),
      throwsA(
        isA<NativeTestHostFailure>().having(
          (failure) => failure.diagnostic?.reason,
          'reason',
          NativeTestVmFailureReason.invalidEnvelope,
        ),
      ),
    );
  });

  test('VM failure diagnostics expose only fixed metadata', () {
    final cases = <(Object, NativeTestVmFailureReason)>[
      (canary, NativeTestVmFailureReason.invalidEnvelope),
      (
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'message': canary, 'data': canary},
        }),
        NativeTestVmFailureReason.rpcError,
      ),
      (
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'streamNotify',
          'params': {'event': canary},
        }),
        NativeTestVmFailureReason.invalidEnvelope,
      ),
    ];
    for (final (message, reason) in cases) {
      NativeTestHostFailure? failure;
      try {
        nativeTestVmResult(
          message,
          method: NativeTestVmMethod.getIsolate,
          expectedId: 1,
        );
      } on NativeTestHostFailure catch (caught) {
        failure = caught;
      }
      expect(failure, isNotNull);
      expect(failure!.toJson(), {
        'outcome': 'failed',
        'category': 'disconnected',
        'diagnostic': {
          'reason': reason.name,
          'method': 'getIsolate',
          'byteCount': utf8.encode(message as String).length,
        },
      });
      expect(jsonEncode(failure.toJson()).contains(canary), isFalse);
      expect(failure.toString(), 'NativeTestHostFailure');
    }
  });

  test('oversized VM text reports only boundedly measured byte counts', () {
    final cases = <(String, int?)>[
      ('$canary${'x' * 65536}', null),
      ('é' * 65537, null),
      ('é' * 32769, 65538),
    ];
    for (final (message, expectedBytes) in cases) {
      NativeTestHostFailure? failure;
      try {
        nativeTestVmResult(
          message,
          method: NativeTestVmMethod.getIsolate,
          expectedId: 1,
        );
      } on NativeTestHostFailure catch (caught) {
        failure = caught;
      }
      expect(failure, isNotNull);
      expect(failure!.toJson(), {
        'outcome': 'failed',
        'category': 'disconnected',
        'diagnostic': {
          'reason': 'frameTooLarge',
          'method': 'getIsolate',
          'byteCount': expectedBytes,
        },
      });
      expect(jsonEncode(failure.toJson()).contains(canary), isFalse);
    }
  });
}
