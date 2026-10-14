import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

import 'backup_recovery_scenario.dart';

/// Receipts only. The operator performs pairing, consent, transfer, and quit.
class IdentityNearbyReceipts {
  IdentityNearbyReceipts(this.scenario, this.role);

  final RecoveryScenario scenario;
  final String role;
  String get run => scenario.run;
  String get root => scenario.receiver.root.path;
  File file(String name) => File(p.join(root, 'identity-nearby-$name.json'));

  Map<String, Object?> read(String name) {
    final input = file(name);
    require(
      FileSystemEntity.typeSync(input.path, followLinks: false) ==
          FileSystemEntityType.file,
      'Nearby $name must be an ordinary owned file',
    );
    final value = jsonDecode(input.readAsStringSync());
    require(value is Map<String, dynamic>, 'Malformed Nearby $name');
    final result = Map<String, Object?>.from(value as Map);
    if (name != 'expected-source') validateEnvelope(result, run: run);
    return result;
  }

  void writeOnce(String name, Map<String, Object?> fields) {
    final output = file(name);
    require(
      FileSystemEntity.typeSync(output.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Nearby $name already exists; preserve prior proof',
    );
    output.createSync(exclusive: true);
    output.writeAsStringSync(
      jsonEncode({
        'format': 1,
        'run': run,
        'root': root,
        'pid': pid,
        'observedAt': DateTime.now().toUtc().toIso8601String(),
        ...fields,
      }),
      flush: true,
    );
  }

  Future<void> captureOrRestart(
    Future<Map<String, Object?>> Function() observe,
  ) async {
    final current = await observe();
    if (role == 'receiver' && file('copy').existsSync()) {
      final baseline = read('baseline');
      final copy = read('copy');
      require(
        baseline['root'] == root &&
            copy['root'] == root &&
            baseline['phase'] == 'before-copy' &&
            baseline['bindingSha256'] is String,
        'Nearby receipt belongs to another workspace',
      );
      require(
        copy['phase'] == 'copy' && copy['validation'] == 'pass',
        'Nearby copy proof is missing',
      );
      final source = Map<String, Object?>.from(
        baseline['expectedSource'] as Map,
      );
      validateSource(source);
      final exported = read('expected-source');
      require(
        source['run'] != run &&
            same(exported, source) &&
            sha256
                    .convert(file('expected-source').readAsBytesSync())
                    .toString() ==
                baseline['expectedSourceSha256'] &&
            copy['expectedSourceRun'] == source['run'] &&
            copy['expectedSourceSha256'] == baseline['expectedSourceSha256'],
        'Nearby copy source differs from the pinned baseline',
      );
      compareCopy(baseline, source, copy);
      compareProtected(baseline, current);
      compareRestart(copy, current);
      writeOnce('restart', {
        'phase': 'restart',
        'validation': 'pass',
        'previousPid': copy['pid'],
        'pidDiffersFromCopy': copy['pid'] != pid,
        ...current,
        'operatorGates': operatorGates,
      });
      debugPrint('IDENTITY NEARBY restart PASS: $root');
      return;
    }

    final legacy = jsonDecode(
      File(p.join(root, 'identity-validation.json')).readAsStringSync(),
    ) as Map;
    require(
      legacy['format'] == 2 &&
          legacy['run'] == run &&
          legacy['state'] == 'restored' &&
          legacy['sameInstallRestore'] == 'passed',
      'Completed identity baseline is missing',
    );
    require(
      same(legacy['receiver'], current['identity']) &&
          same(legacy['fixtureSeededFloors'], current['floors']) &&
          legacy['bindingSha256'] == current['bindingSha256'],
      'Pre-Nearby identity, floors, or binding changed',
    );
    RecoveryScenario.compareShop(
      Map<String, Object?>.from(scenario.readManifest()['restored'] as Map),
      shop(current),
    );
    if (role == 'source') {
      writeOnce('source', {'phase': 'source-before', ...current});
      debugPrint('IDENTITY NEARBY source EXPORTED: ${file('source').path}');
      return;
    }
    require(role == 'receiver', 'Unsupported Nearby role');
    debugPrint('IDENTITY NEARBY awaiting expected source: $root');
    while (!file('expected-source').existsSync()) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final source = read('expected-source');
    validateSource(source);
    require(
      source['run'] != run,
      'Nearby acceptance requires distinct source and receiver fixture runs',
    );
    require(
      !file('request').existsSync(),
      'Capture request must be created after receiver baseline is pinned',
    );
    final pinned = await observe();
    compareProtected(current, pinned);
    compareRestart(current, pinned);
    final sourceSha = sha256
        .convert(file('expected-source').readAsBytesSync())
        .toString();
    writeOnce('baseline', {
      'phase': 'before-copy',
      'expectedSourceSha256': sourceSha,
      'expectedSource': source,
      ...current,
    });
    debugPrint('IDENTITY NEARBY receiver PINNED: $root');
    String? attempted;
    String? lastError;
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!file('request').existsSync()) continue;
      try {
        final request = read('request');
        final digest = sha256
            .convert(utf8.encode(jsonEncode(request)))
            .toString();
        if (digest == attempted) continue;
        attempted = digest;
        validateRequest(
          request,
          run: run,
          root: root,
          sourceSha: sourceSha,
          sourceRun: source['run'] as String,
        );
        final baseline = read('baseline');
        require(
          baseline['root'] == root &&
              baseline['phase'] == 'before-copy' &&
              baseline['bindingSha256'] is String &&
              baseline['expectedSourceSha256'] == sourceSha &&
              same(baseline['expectedSource'], source),
          'Pinned Nearby source changed',
        );
        final after = await observe();
        compareCopy(baseline, source, after);
        writeOnce('copy', {
          'phase': 'copy',
          'validation': 'pass',
          'expectedSourceSha256': sourceSha,
          'expectedSourceRun': source['run'],
          ...after,
          'operatorGates': operatorGates,
        });
        debugPrint('IDENTITY NEARBY copy PASS: $root');
        return;
      } catch (error) {
        if ('$error' != lastError) {
          debugPrint('IDENTITY NEARBY request REFUSED: $error');
          lastError = '$error';
        }
      }
    }
  }

  static const operatorGates = {
    'networkPairSendAccept': 'operator evidence required',
    'normalQuitFreshProcess': 'operator evidence required',
    'exactBundleAndCrossHostSourceHash': 'operator evidence required',
  };

  static void validateEnvelope(
    Map<String, Object?> value, {
    required String run,
  }) {
    require(
      value['format'] == 1 && value['run'] == run,
      'Nearby receipt version or run mismatch',
    );
  }

  static void validateRequest(
    Map<String, Object?> value, {
    required String run,
    required String root,
    required String sourceSha,
    required String sourceRun,
  }) {
    validateEnvelope(value, run: run);
    require(
      value.keys.toSet().difference({
            'format',
            'run',
            'root',
            'phase',
            'expectedSourceSha256',
            'expectedSourceRun',
            'attempt',
          }).isEmpty &&
          value['root'] == root &&
          value['phase'] == 'capture-copy' &&
          value['expectedSourceSha256'] == sourceSha &&
          value['expectedSourceRun'] == sourceRun &&
          value['attempt'] is int &&
          (value['attempt'] as int) > 0,
      'Unsafe Nearby phase, path, or source expectation',
    );
  }

  static void validateSource(Map<String, Object?> source) {
    final sourceRun = source['run'];
    require(
      sourceRun is String &&
          RegExp(r'^[a-z0-9][a-z0-9-]{0,31}$').hasMatch(sourceRun),
      'Invalid source run',
    );
    validateEnvelope(source, run: sourceRun as String);
    require(
      source['phase'] == 'source-before' &&
          source['pid'] is int &&
          DateTime.tryParse('${source['observedAt']}') != null &&
          source['root'] is String &&
          p.basename(source['root'] as String) ==
              'wired-parts-lan-recovery-$sourceRun-receiver',
      'Invalid source-before provenance',
    );
    final receipt = shop(source);
    require(
      receipt['records'] is Map &&
          (receipt['records'] as Map).keys.toSet().containsAll({
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
          }) &&
          receipt['photos'] is List &&
          (receipt['photos'] as List).isNotEmpty &&
          receipt['sqliteSchemaVersion'] == kAppSchemaVersion &&
          (receipt['settings'] as Map)['lan_validation_fixture'] ==
              'recovery-$sourceRun-sender',
      'Incomplete or non-synthetic expected source shop',
    );
  }

  static Map<String, Object?> shop(Map<String, Object?> state) =>
      Map<String, Object?>.from(state['shop'] as Map);

  static void compareProtected(
    Map<String, Object?> baseline,
    Map<String, Object?> actual,
  ) {
    for (final field in ['identity', 'floors']) {
      require(
        baseline[field] != null && same(baseline[field], actual[field]),
        'Nearby changed protected $field',
      );
    }
    for (final field in ['deviceProfiles', 'localDeviceIds', 'pinConfigured']) {
      require(
        same(shop(baseline)[field], shop(actual)[field]),
        'Nearby changed recipient $field',
      );
    }
  }

  static void compareCopy(
    Map<String, Object?> baseline,
    Map<String, Object?> source,
    Map<String, Object?> actual,
  ) {
    compareProtected(baseline, actual);
    comparePinUsability(actual);
    require(
      actual['pinSha256'] == source['pinSha256'],
      'Nearby shop catalog PIN differs from the expected source',
    );
    require(
      actual['bindingSha256'] is String &&
          baseline['bindingSha256'] != actual['bindingSha256'],
      'Nearby import did not change receiving-store binding',
    );
    Map<String, Object?> business(Map<String, Object?> state) {
      final value = shop(state);
      final settings = Map<String, Object?>.from(value['settings'] as Map);
      for (final key in [
        kInstallationBindingKey,
        kLastBackupAtKey,
        kLastBackupSourceKey,
        kLastNearbyAtKey,
        kLastNearbyPeerKey,
      ]) {
        settings.remove(key);
      }
      return {
        ...value,
        'settings': settings,
        'deviceProfiles': [],
        'localDeviceIds': [],
        'pinConfigured': true,
      };
    }

    RecoveryScenario.compareShop(business(source), business(actual));
    final settings = shop(actual)['settings'] as Map;
    require(
      settings[kLastNearbyPeerKey] ==
              (shop(source)['localDeviceIds'] as List).single &&
          DateTime.tryParse('${settings[kLastNearbyAtKey]}') != null,
      'Nearby import metadata is missing',
    );
  }

  static void compareRestart(
    Map<String, Object?> copy,
    Map<String, Object?> actual,
  ) {
    compareProtected(copy, actual);
    comparePinUsability(actual);
    require(
      copy['pinSha256'] != null && copy['pinSha256'] == actual['pinSha256'],
      'Nearby catalog PIN changed across restart',
    );
    require(
      copy['bindingSha256'] != null &&
          copy['bindingSha256'] == actual['bindingSha256'],
      'Nearby binding changed across restart',
    );
    RecoveryScenario.compareShop(shop(copy), shop(actual));
  }

  static void comparePinUsability(Map<String, Object?> state) {
    require(
      shop(state)['pinConfigured'] == true &&
          state['syntheticPinUnlocks'] == true &&
          state['wrongPinRejected'] == true,
      'Synthetic shop PIN is unusable or accepted the wrong PIN',
    );
  }

  static bool same(Object? a, Object? b) =>
      const DeepCollectionEquality().equals(a, b);
}
