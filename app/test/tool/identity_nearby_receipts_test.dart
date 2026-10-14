import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

import '../../tool/backup_recovery_scenario.dart';
import '../../tool/identity_nearby_receipts.dart';

Map<String, Object?> clone(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

Map<String, Object?> fixture(String run) => {
  'format': 1,
  'run': run,
  'root': '/tmp/wired-parts-lan-recovery-$run-receiver',
  'pid': 42,
  'observedAt': '2026-10-11T12:00:00Z',
  'phase': 'source-before',
  'identity': {'id': run, 'generation': '1', 'publicKeySha256': 'public'},
  'floors': {'authority.test-company': 7, 'revocation.test-device': 11},
  'pinSha256': '$run-pin-fingerprint',
  'syntheticPinUnlocks': true,
  'wrongPinRejected': true,
  'bindingSha256': 'before-binding',
  'shop': {
    'sqliteSchemaVersion': kAppSchemaVersion,
    'records': {
      for (final table in [
        'categories',
        'styles',
        'types',
        'devices',
        'brands',
        'suppliers',
        'parts',
        'part_devices',
        'brand_versions',
        'supplier_listings',
        'jobs',
        'job_lines',
        'order_splits',
      ])
        table: [
          {'id': '$run-$table', 'part_id': '$run-parts'},
        ],
    },
    'settings': {'lan_validation_fixture': 'recovery-$run-sender'},
    'pinConfigured': true,
    'localDeviceIds': ['lan-recovery-$run-receiver'],
    'deviceProfiles': [
      {'id': 'lan-recovery-$run-receiver', 'name': run},
    ],
    'photos': [
      {'name': '$run.png', 'sha256': 'expected-photo-bytes'},
    ],
  },
};

void main() {
  late Map<String, Object?> baseline;
  late Map<String, Object?> source;
  late Map<String, Object?> received;
  setUp(() {
    baseline = fixture('windows');
    source = fixture('mac');
    received = clone(source)
      ..['identity'] = baseline['identity']
      ..['floors'] = baseline['floors']
      ..['bindingSha256'] = 'after-binding';
    final shop = received['shop'] as Map;
    final local = baseline['shop'] as Map;
    shop['localDeviceIds'] = local['localDeviceIds'];
    shop['deviceProfiles'] = local['deviceProfiles'];
    (shop['settings'] as Map).addAll(<String, Object?>{
      kLastNearbyPeerKey: 'lan-recovery-mac-receiver',
      kLastNearbyAtKey: '2026-10-11T12:01:00Z',
    });
  });

  test(
    'pins a distinct source and validates full replacement plus restart',
    () {
      IdentityNearbyReceipts.validateSource(source);
      IdentityNearbyReceipts.compareCopy(baseline, source, received);
      IdentityNearbyReceipts.compareRestart(received, clone(received));
      expect(
        (received['shop'] as Map)['records'],
        (source['shop'] as Map)['records'],
      );
      expect(
        (received['shop'] as Map)['records'],
        isNot((baseline['shop'] as Map)['records']),
      );
    },
  );

  test(
    'request refuses wrong run, version, phase, root, source or extra path',
    () {
      final valid = <String, Object?>{
        'format': 1,
        'run': 'windows',
        'root': '/owned',
        'phase': 'capture-copy',
        'expectedSourceSha256': 'source-hash',
        'expectedSourceRun': 'mac',
        'attempt': 1,
      };
      void validate(Map<String, Object?> value) =>
          IdentityNearbyReceipts.validateRequest(
            value,
            run: 'windows',
            root: '/owned',
            sourceSha: 'source-hash',
            sourceRun: 'mac',
          );
      validate(valid);
      for (final change in <Map<String, Object?>>[
        {'format': 2},
        {'run': 'other'},
        {'phase': 'restore'},
        {'root': '/private'},
        {'expectedSourceSha256': 'bad'},
        {'expectedSourceRun': 'other'},
        {'path': '/private'},
        {'attempt': 0},
      ]) {
        expect(() => validate({...valid, ...change}), throwsStateError);
      }
    },
  );

  test(
    'source expectation refuses missing rows, wrong provenance or fixture',
    () {
      for (final change in <Map<String, Object?>>[
        {'phase': 'copy'},
        {'root': '/private'},
        {'run': '../private'},
        {'observedAt': 'invalid'},
        {'format': 2},
      ]) {
        expect(
          () => IdentityNearbyReceipts.validateSource({...source, ...change}),
          throwsStateError,
        );
      }
      final bad = clone(source);
      ((bad['shop'] as Map)['records'] as Map).remove('job_lines');
      expect(
        () => IdentityNearbyReceipts.validateSource(bad),
        throwsStateError,
      );
    },
  );

  for (final field in ['identity', 'floors']) {
    test('copy refuses changed recipient $field', () {
      final bad = clone(received)..[field] = {'changed': true};
      expect(
        () => IdentityNearbyReceipts.compareCopy(baseline, source, bad),
        throwsStateError,
      );
    });
  }

  test('copy imports usable shop PIN; restart preserves its fingerprint', () {
    expect(received['pinSha256'], isNot(baseline['pinSha256']));
    IdentityNearbyReceipts.compareCopy(baseline, source, received);
    for (final field in ['syntheticPinUnlocks', 'wrongPinRejected']) {
      expect(
        () => IdentityNearbyReceipts.compareCopy(baseline, source, {
          ...received,
          field: false,
        }),
        throwsStateError,
      );
    }
    expect(
      () => IdentityNearbyReceipts.compareCopy(baseline, source, {
        ...received,
        'pinSha256': 'another-pin',
      }),
      throwsStateError,
    );
    expect(
      () => IdentityNearbyReceipts.compareRestart(received, {
        ...received,
        'pinSha256': 'another-pin',
      }),
      throwsStateError,
    );
  });

  test(
    'copy requires new binding; restart requires the new binding unchanged',
    () {
      expect(
        () => IdentityNearbyReceipts.compareCopy(baseline, source, {
          ...received,
          'bindingSha256': baseline['bindingSha256'],
        }),
        throwsStateError,
      );
      expect(
        () => IdentityNearbyReceipts.compareRestart(received, {
          ...received,
          'bindingSha256': 'another-generation',
        }),
        throwsStateError,
      );
    },
  );

  for (final field in [
    'records',
    'photos',
    'deviceProfiles',
    'localDeviceIds',
  ]) {
    test('copy and restart refuse changed $field', () {
      final bad = clone(received);
      (bad['shop'] as Map)[field] = field == 'records' ? {} : [];
      expect(
        () => IdentityNearbyReceipts.compareCopy(baseline, source, bad),
        throwsStateError,
      );
      expect(
        () => IdentityNearbyReceipts.compareRestart(received, bad),
        throwsStateError,
      );
    });
  }

  test(
    'missing baseline and repeated receipt write preserve existing proof',
    () {
      final temp = Directory.systemTemp.createTempSync('nearby-identity-test-');
      final scenario = RecoveryScenario.open(
        run: 'guard',
        action: RecoveryAction.exercise,
        temporaryDirectory: temp,
      );
      addTearDown(() {
        scenario.close();
        temp.deleteSync(recursive: true);
      });
      final receipts = IdentityNearbyReceipts(scenario, 'receiver');
      expect(() => receipts.read('baseline'), throwsStateError);
      receipts.writeOnce('copy', {'phase': 'copy', 'validation': 'pass'});
      final before = receipts.file('copy').readAsStringSync();
      expect(
        () => receipts.writeOnce('copy', {'validation': 'fail'}),
        throwsStateError,
      );
      expect(receipts.file('copy').readAsStringSync(), before);
      expect(receipts.file('baseline').existsSync(), isFalse);
    },
  );
}
