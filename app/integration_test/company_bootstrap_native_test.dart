import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse, FrameTiming;

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

import '../tool/nearby_lan_workspace.dart';
import '../tool/native_nearby_test_exit.dart';

const _run = String.fromEnvironment('COMPANY_VALIDATION_RUN');
const _revision = String.fromEnvironment('COMPANY_VALIDATION_SOURCE_REVISION');
const _tree = String.fromEnvironment('COMPANY_VALIDATION_SOURCE_TREE');
const _readOnlyCustody = bool.fromEnvironment(
  'COMPANY_VALIDATION_READ_ONLY_CUSTODY',
);
const _passphrase = 'Synthetic authority recovery only 123';
const _replacementPassphrase = 'Synthetic replacement recovery only 456';
const _store = NativeInstallationSecureStore();
final _measurements = <Map<String, Object?>>[];
var _stage = 'initializing';

Map<String, Object?> _publicUiSignals() {
  final errorVisible = find.byType(Text).evaluate().any((element) {
    final widget = element.widget as Text;
    return widget.style?.color == Theme.of(element).colorScheme.error;
  });
  return {
    'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
    'createControl': find.byKey(const Key('create-company')).evaluate().length,
    'signinControl': find.byKey(const Key('company-signin')).evaluate().length,
    'signinEnabled':
        find.byKey(const Key('company-signin')).evaluate().length == 1
        ? ((find.byKey(const Key('company-signin')).evaluate().single.widget
                      as FilledButton)
                  .onPressed !=
              null)
        : null,
    'signoutControl': find
        .byKey(const Key('company-signout'))
        .evaluate()
        .length,
    'lockedTitle': find.text('Company locked').evaluate().length,
    'createTitle': find.text('Create company').evaluate().length,
    'setupPendingTitle': find.text('Finish company setup').evaluate().length,
    'recoveryNeededTitle': find
        .text('Company recovery needed')
        .evaluate()
        .length,
    'createError': find
        .text(
          'Company creation needs recovery or a retry with the same details.',
        )
        .evaluate()
        .length,
    'signinError': find
        .text('Administrator PIN refused or company needs recovery.')
        .evaluate()
        .length,
    'errorClass': !errorVisible
        ? 'none'
        : find
              .text(
                'Company creation needs recovery or a retry with the same details.',
              )
              .evaluate()
              .isNotEmpty
        ? 'create-unexpected-error'
        : find
              .text('Administrator PIN refused or company needs recovery.')
              .evaluate()
              .isNotEmpty
        ? 'signin-refused'
        : 'other-company-error',
  };
}

void _require(bool value) {
  if (!value) throw const _NativeFailure();
}

final class _NativeFailure implements Exception {
  const _NativeFailure();
  @override
  String toString() => 'company-native-validation-failed';
}

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

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

void _writeOnce(File file, Map<String, Object?> fields) {
  _require(
    FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.notFound,
  );
  file.createSync(exclusive: true);
  file.writeAsStringSync(
    jsonEncode({
      'format': 1,
      'run': _run,
      'sourceRevision': _revision,
      'sourceTree': _tree,
      'pid': pid,
      'platform': Platform.operatingSystem,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      ...fields,
    }),
    flush: true,
  );
}

Map<String, dynamic> _read(File file) {
  _require(
    FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file &&
        file.lengthSync() < 65536,
  );
  final decoded = jsonDecode(file.readAsStringSync());
  _require(decoded is Map<String, dynamic>);
  return decoded as Map<String, dynamic>;
}

final class _Installation {
  _Installation(this.workspace, this.db, this.security);
  final ValidationWorkspace workspace;
  final AppDatabase db;
  final InstallationSecurity security;
  CompanyEnrollment get enrollment =>
      CompanyEnrollment(installation: security, db: db);
  File get package => File(p.join(workspace.root.path, 'authority.wpca'));
}

final class _Lifetime with WidgetsBindingObserver {
  final installations = <_Installation>[];
  final workspaces = <ValidationWorkspace>[];
  final lifecycleStates = <String>[];
  var _closed = false;
  _Installation? visible;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (lifecycleStates.length < 16) lifecycleStates.add(state.name);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final installation in installations.reversed) {
      await installation.db.close();
    }
    for (final workspace in workspaces.reversed) {
      workspace.close();
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // WiredPartsApp owns the visible connection's ordinary exit callback.
    for (final installation in installations) {
      if (!identical(installation, visible)) await installation.db.close();
    }
    return AppExitResponse.exit;
  }
}

Future<_Installation> _open(
  _Lifetime lifetime,
  ValidationRole role,
  bool restart,
) async {
  final workspace = ValidationWorkspace.open(
    run: 'company-$_run',
    role: role,
    requireExisting: restart,
  );
  lifetime.workspaces.add(workspace);
  _require(restart || !workspace.initialized);
  final db = AppDatabase.forTesting(
    NativeDatabase(File(p.join(workspace.support.path, kSqliteFileName))),
  );
  final security = InstallationSecurity(
    store: _store,
    namespace:
        'synthetic.company.$_run.${role == ValidationRole.sender ? 'original' : 'replacement'}',
  );
  final installation = _Installation(workspace, db, security);
  lifetime.installations.add(installation);
  await security.start(db);
  _require(security.readiness == InstallationReadiness.ready);
  if (!restart) workspace.markInitialized();
  return installation;
}

Future<void> _proveExclusivePublisher(
  _Installation original,
  bool restart,
) async {
  final destination = File(
    p.join(original.workspace.root.path, 'publication-probe.bin'),
  );
  final first = Uint8List.fromList(
    utf8.encode('native exclusive publication probe'),
  );
  final second = Uint8List.fromList(utf8.encode('must not replace first'));
  if (!restart) {
    _require(!destination.existsSync());
    await _store.writeRecoveryFileExclusive(destination.path, first);
  }
  _require(
    destination.existsSync() &&
        _hash(destination.readAsBytesSync()) == _hash(first),
  );
  var refused = false;
  try {
    await _store.writeRecoveryFileExclusive(destination.path, second);
  } on PlatformException catch (error) {
    refused = Platform.isWindows
        ? error.code == 'installation_file_exists'
        : error.code == 'installation_unavailable' &&
              error.details is Map &&
              (error.details as Map)['errno'] == 17; // Darwin EEXIST.
  }
  _require(refused && _hash(destination.readAsBytesSync()) == _hash(first));
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready, {
  String? measurement,
  Stopwatch? started,
}) async {
  final clock = started ?? (Stopwatch()..start());
  var polls = 0;
  var frames = 0;
  var previousMicros = 0;
  var maxPollingGapMicros = 0;
  var maxFrameMicros = 0;
  var maxBuildMicros = 0;
  var maxRasterMicros = 0;
  var sampledRssMax = ProcessInfo.currentRss;
  void onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      frames++;
      if (timing.totalSpan.inMicroseconds > maxFrameMicros) {
        maxFrameMicros = timing.totalSpan.inMicroseconds;
      }
      if (timing.buildDuration.inMicroseconds > maxBuildMicros) {
        maxBuildMicros = timing.buildDuration.inMicroseconds;
      }
      if (timing.rasterDuration.inMicroseconds > maxRasterMicros) {
        maxRasterMicros = timing.rasterDuration.inMicroseconds;
      }
    }
  }

  if (measurement != null) {
    WidgetsBinding.instance.addTimingsCallback(onTimings);
  }
  try {
    while (!ready() && clock.elapsed < const Duration(minutes: 3)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      polls++;
      final now = clock.elapsedMicroseconds;
      final gap = now - previousMicros;
      previousMicros = now;
      if (gap > maxPollingGapMicros) maxPollingGapMicros = gap;
      final rss = ProcessInfo.currentRss;
      if (rss > sampledRssMax) sampledRssMax = rss;
      if ((measurement == 'create-and-signin' ||
              measurement == 'replacement-recovery-and-signin') &&
          polls >= 10 &&
          !ready()) {
        final signals = _publicUiSignals();
        if (signals['errorClass'] != 'none' ||
            (signals['lockedTitle'] == 1 && signals['signinEnabled'] == true) ||
            signals['recoveryNeededTitle'] == 1) {
          throw const _NativeFailure();
        }
      }
    }
    _require(ready());
  } finally {
    if (measurement != null) {
      WidgetsBinding.instance.removeTimingsCallback(onTimings);
      _measurements.add({
        'action': measurement,
        'uiSubmitElapsedMicros': clock.elapsedMicroseconds,
        'pollSamples': polls,
        'intendedPollIntervalMicros': 100000,
        'maxObservedPollingGapMicros': maxPollingGapMicros,
        'flutterFrameSamples': frames,
        'maxFrameTotalSpanMicros': frames == 0 ? null : maxFrameMicros,
        'maxFrameBuildMicros': frames == 0 ? null : maxBuildMicros,
        'maxFrameRasterMicros': frames == 0 ? null : maxRasterMicros,
        'sampledWholeProcessRssMaxBytes': sampledRssMax,
        'isTruePeakMemory': false,
        'isKdfOnlyMeasurement': false,
      });
    }
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  _require(finder.evaluate().length == 1);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _mount(
  WidgetTester tester,
  _Installation installation, {
  File? sourcePackage,
}) async {
  final deviceId = await installation.db.settingsDao.ensureDeviceId();
  await tester.pumpWidget(
    WiredPartsApp(
      key: ValueKey(installation.workspace.role.name),
      db: installation.db,
      pin: PinService(installation.db.settingsDao),
      deviceId: deviceId,
      installation: installation.security,
      enableCompanyBootstrap: true,
      pickCompanyRecoveryPath: () async => installation.package.path,
      pickCompanySourcePath: () async => sourcePackage?.path,
      reset: LocalDataReset(
        supportDir: installation.workspace.support,
        documentsDir: installation.workspace.documents,
        photosDir: installation.workspace.photos,
      ),
    ),
  );
  await _waitFor(
    tester,
    () =>
        find.byKey(const Key('company-pin')).evaluate().isNotEmpty ||
        find.byKey(const Key('company-signin-pin')).evaluate().isNotEmpty,
  );
  _require(find.byType(HomeShell).evaluate().isEmpty);
}

Future<void> _signIn(WidgetTester tester, {bool wrong = false}) async {
  await tester.enterText(
    find.byKey(const Key('company-signin-pin')),
    wrong ? '9999' : '1234',
  );
  final started = Stopwatch()..start();
  await _tap(tester, find.byKey(const Key('company-signin')));
  await _waitFor(
    tester,
    () => wrong
        ? find.textContaining('Administrator PIN refused').evaluate().isNotEmpty
        : find.byKey(const Key('company-signout')).evaluate().isNotEmpty,
    measurement: wrong ? 'wrong-pin-signin' : 'correct-pin-signin',
    started: started,
  );
  _require(find.byType(HomeShell).evaluate().isEmpty);
  if (wrong) {
    _require(find.text('Company locked').evaluate().length == 1);
    _require(find.textContaining('Company ID:').evaluate().isEmpty);
  } else {
    _require(find.textContaining('Company ID:').evaluate().length == 1);
  }
}

Future<void> _signOut(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('company-signout')));
  await _waitFor(
    tester,
    () => find.text('Company locked').evaluate().length == 1,
  );
  _require(find.textContaining('Company ID:').evaluate().isEmpty);
  _require(find.byType(HomeShell).evaluate().isEmpty);
}

Future<void> _createOrRecover(
  WidgetTester tester,
  _Installation installation, {
  bool recovery = false,
}) async {
  _stage = recovery ? 'entering-recovery' : 'entering-create';
  if (recovery) {
    await _tap(tester, find.byKey(const Key('switch-company-recovery')));
    await _tap(tester, find.byKey(const Key('choose-source-package')));
    await tester.enterText(
      find.byKey(const Key('source-passphrase')),
      _passphrase,
    );
  } else {
    await tester.enterText(
      find.byKey(const Key('company-name')),
      'Synthetic company $_run',
    );
  }
  await tester.enterText(find.byKey(const Key('company-pin')), '1234');
  await tester.enterText(
    find.byKey(const Key('recovery-passphrase')),
    recovery ? _replacementPassphrase : _passphrase,
  );
  await _tap(tester, find.byKey(const Key('local-continuity-consent')));
  await _tap(tester, find.byKey(const Key('authority-only-consent')));
  await _tap(tester, find.text('Choose encrypted recovery file'));
  await _waitFor(
    tester,
    () =>
        find.text('Recovery file destination selected').evaluate().length == 1,
  );
  final started = Stopwatch()..start();
  _stage = recovery
      ? 'awaiting-recovery-active-ui'
      : 'awaiting-create-active-ui';
  await _tap(tester, find.byKey(const Key('create-company')));
  await _waitFor(
    tester,
    () => find.byKey(const Key('company-signout')).evaluate().length == 1,
    measurement: recovery
        ? 'replacement-recovery-and-signin'
        : 'create-and-signin',
    started: started,
  );
  _require(installation.package.existsSync());
  _require(find.textContaining('Company ID:').evaluate().length == 1);
  _stage = recovery ? 'recovery-signout' : 'create-signout';
  await _signOut(tester);
  _stage = recovery ? 'recovery-wrong-pin' : 'create-wrong-pin';
  await _signIn(tester, wrong: true);
  _stage = recovery ? 'recovery-correct-pin' : 'create-correct-pin';
  await _signIn(tester);
  _stage = recovery ? 'recovery-final-signout' : 'create-final-signout';
  await _signOut(tester);
}

Future<Map<String, Object?>> _snapshot(_Installation installation) async {
  final db = installation.db;
  final security = installation.security;
  _require(
    await installation.enrollment.readStatus() == CompanyBootstrapStatus.active,
  );
  final company = await installation.enrollment.readIdentity();
  final identity = security.identity;
  final trust = await security.readCompanyTrust(db);
  _require(company != null && identity != null && trust != null);
  _require(security.canUseCompanyOperations);
  final facts = await db
      .customSelect(
        'SELECT signed_bytes FROM company_authority_facts WHERE commitment = ?',
        variables: [Variable.withString(trust!.factsCommitment)],
      )
      .getSingle();
  final signed = jsonDecode(facts.read<String>('signed_bytes')) as Map;
  _require(
    await Ed25519().verify(
      utf8.encode('wiredpart.company.facts@2:${_canonical(signed['body'])}'),
      signature: Signature(
        base64Decode(signed['signature'] as String),
        publicKey: SimplePublicKey(trust.rootKey, type: KeyPairType.ed25519),
      ),
    ),
  );
  final evidence = <String, Object?>{};
  final counts = <String, int>{};
  await db.transaction(() async {
    for (final table in db.allTables) {
      final name = table.actualTableName;
      final rows = await db.customSelect('SELECT * FROM "$name"').get();
      evidence[name] = rows.map((row) => _canonical(row.data)).toList()..sort();
      counts[name] = rows.length;
      if (![
        'device_profiles',
        'app_settings',
        'company_authority_facts',
        'company_bootstrap_witnesses',
      ].contains(name)) {
        _require(rows.isEmpty);
      }
    }
  });
  final base = await _store.readState(security.namespace);
  final custody = await _store.readState(
    companyCustodyNamespace(security.namespace),
  );
  _require(base != null && custody != null);
  _require(
    base!.bytes.length <= kInstallationStateLimit &&
        custody!.bytes.length <= kInstallationStateLimit,
  );
  final custodyState = jsonDecode(utf8.decode(custody!.bytes)) as Map;
  _require(
    custodyState['status'] == 'active' &&
        custodyState['recoverySeed'] == null &&
        custodyState['attempts'] == 8,
  );
  _require(
    !installation.workspace.photos.existsSync() ||
        installation.workspace.photos.listSync().isEmpty,
  );
  return {
    'company': company!.companyId,
    'shop': company.shopId,
    'user': company.userId,
    'device': company.deviceId,
    'package': company.packageId,
    'installation': identity!.id.value,
    'installationGeneration': identity.generation.value,
    'publicKeySha256': _hash(identity.publicKey),
    'storeGeneration': security.receivingStoreGeneration!.value,
    'authorityVersion': trust.authorityVersion,
    'authorityKeySha256': _hash(trust.rootKey),
    'factsCommitment': trust.factsCommitment,
    'policy': trust.policy,
    'floors': security.knownSecurityFloors,
    'logicalSha256': _hash(utf8.encode(_canonical(evidence))),
    'counts': counts,
    'packageSha256': _hash(installation.package.readAsBytesSync()),
    'signedFactsVerified': true,
    'nativeCustodyActive': true,
    'recoverySeedRemoved': true,
    'attemptBudgetRestored': true,
    'nativeRecordsWithinCapacity': true,
    'baseProtectedBytes': base.bytes.length,
    'custodyProtectedBytes': custody.bytes.length,
    'legacyBusinessEmpty': true,
  };
}

Future<void> _resident(
  WidgetTester tester,
  _Installation original,
  String phase,
) async {
  final clock = Stopwatch()..start();
  final request = File(
    p.join(
      original.workspace.receipts.path,
      'company-$phase-normal-exit-request.json',
    ),
  );
  while (clock.elapsed < const Duration(minutes: 20)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (!request.existsSync()) continue;
    final value = _read(request);
    _require(
      value.length == 4 &&
          value['run'] == _run &&
          value['pid'] == pid &&
          value['phase'] == phase &&
          value['normalCloseCancelled'] == true,
    );
    _writeOnce(
      File(
        p.join(
          original.workspace.receipts.path,
          'company-$phase-exit-fallback.json',
        ),
      ),
      {
        'phase': phase,
        'method':
            'owned-request-after-operator-observed-normal-close-cancellation',
        'processExit': 'host evidence required',
      },
    );
    await requestNativeTestExit();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );
    throw const _NativeFailure();
  }
  throw const _NativeFailure();
}

void main() {
  _require(const bool.fromEnvironment('NATIVE_COMPANY_TEST_MODE'));
  _require(Platform.isWindows || Platform.isMacOS);
  _require(RegExp(r'^j97-(win|mac)-[a-z0-9-]{1,20}$').hasMatch(_run));
  _require(_run.startsWith(Platform.isWindows ? 'j97-win-' : 'j97-mac-'));
  _require(
    RegExp(r'^[a-f0-9]{40}$').hasMatch(_revision) &&
        RegExp(r'^[a-f0-9]{40}$').hasMatch(_tree),
  );
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native production company bootstrap and recovery', (
    tester,
  ) async {
    final lifetime = _Lifetime();
    WidgetsBinding.instance.addObserver(lifetime);
    final originalError = FlutterError.onError;
    FlutterError.onError = (_) => originalError?.call(
      FlutterErrorDetails(exception: const _NativeFailure()),
    );
    var phase = 'bootstrap';
    try {
      final root = p.join(
        Directory.systemTemp.resolveSymbolicLinksSync(),
        'wired-parts-lan-company-$_run-sender',
        'receipts',
      );
      if (_readOnlyCustody) {
        final namespace = 'synthetic.company.$_run.original';
        final base = await _store.readState(namespace);
        final companion = await _store.readState(
          companyCustodyNamespace(namespace),
        );
        _require(base != null && companion != null);
        final baseFields =
            jsonDecode(utf8.decode(base!.bytes)) as Map<String, dynamic>;
        final custodyFields =
            jsonDecode(utf8.decode(companion!.bytes)) as Map<String, dynamic>;
        _writeOnce(File(p.join(root, 'company-custody-readonly.json')), {
          'phase': 'read-only-native-store',
          'passed': true,
          'baseBytes': base.bytes.length,
          'companionBytes': companion.bytes.length,
          'baseTrustPresent': baseFields['companyTrust'] != null,
          'custodyStatus': custodyFields['status'],
          'remainingAttempts': custodyFields['attempts'],
          'noStartOrCas': true,
        });
        // ignore: avoid_print
        print('COMPANY_NATIVE read-only custody PASS pid=$pid');
        return;
      }
      final exerciseFile = File(p.join(root, 'company-exercise.json'));
      final restarting = exerciseFile.existsSync();
      final original = await _open(lifetime, ValidationRole.sender, restarting);
      final replacement = await _open(
        lifetime,
        ValidationRole.receiver,
        restarting,
      );
      await _proveExclusivePublisher(original, restarting);
      final sourcePackage = original.package;
      Map<String, dynamic>? exercise;
      if (restarting) {
        phase = 'restart';
        exercise = _read(exerciseFile);
        _require(
          exercise['format'] == 1 &&
              exercise['run'] == _run &&
              exercise['phase'] == 'exercise' &&
              exercise['platform'] == Platform.operatingSystem &&
              exercise['sourceRevision'] == _revision &&
              exercise['sourceTree'] == _tree &&
              exercise['passed'] == true &&
              exercise['pid'] != pid &&
              exercise['originalRoot'] == original.workspace.root.path &&
              exercise['replacementRoot'] == replacement.workspace.root.path,
        );
        _require(!File(p.join(root, 'company-restart.json')).existsSync());
        _require(
          _canonical(await _snapshot(original)) ==
              _canonical(exercise['original']),
        );
        _require(
          _canonical(await _snapshot(replacement)) ==
              _canonical(exercise['replacement']),
        );
        for (final installation in [original, replacement]) {
          lifetime.visible = installation;
          await _mount(tester, installation);
          _require(find.text('Company locked').evaluate().length == 1);
          await _signIn(tester, wrong: true);
          await _signIn(tester);
          await _signOut(tester);
        }
      } else {
        phase = 'exercise';
        lifetime.visible = original;
        await _mount(tester, original);
        await _createOrRecover(tester, original);
        lifetime.visible = replacement;
        await _mount(tester, replacement, sourcePackage: sourcePackage);
        await _createOrRecover(tester, replacement, recovery: true);
      }
      final first = await _snapshot(original);
      final second = await _snapshot(replacement);
      _require(
        ['company', 'shop', 'user'].every((key) => first[key] == second[key]),
      );
      _require(
        [
          'device',
          'installation',
          'installationGeneration',
          'publicKeySha256',
          'storeGeneration',
          'authorityKeySha256',
          'package',
        ].every((key) => first[key] != second[key]),
      );
      _require(
        (second['authorityVersion'] as int) >
            (first['authorityVersion'] as int),
      );
      if (exercise != null) {
        _require(
          _canonical(first) == _canonical(exercise['original']) &&
              _canonical(second) == _canonical(exercise['replacement']),
        );
      }
      await _signIn(tester);
      _writeOnce(File(p.join(root, 'company-$phase.json')), {
        'phase': phase,
        'passed': true,
        if (exercise != null) 'exercisePid': exercise['pid'],
        'originalRoot': original.workspace.root.path,
        'replacementRoot': replacement.workspace.root.path,
        'original': first,
        'replacement': second,
        'productionWidgetFlow': true,
        'wrongPinRejected': true,
        'finalVisibleCompanyShell': true,
        'measurements': _measurements,
        'measurementScope': 'small native UI-action samples; polling gaps and Flutter frame timings are distinct; RSS is sampled whole process, not peak or KDF-only',
        'lockedFreshProcess': restarting,
        'recoveryOnFreshInstallation': true,
        'nativeExclusivePublisherNoOverwrite': true,
        'sessionAndPrivateMaterialExported': false,
        'normalQuitFreshProcess': 'external host evidence required',
      });
      // ignore: avoid_print
      print('COMPANY_NATIVE $phase PASS pid=$pid');
      await _resident(tester, original, phase);
    } catch (_) {
      if (lifetime.workspaces.isNotEmpty) {
        int? witnessCount;
        int? factsCount;
        String? witnessStatus;
        if (lifetime.installations.isNotEmpty) {
          try {
            final failedDb = lifetime.installations.first.db;
            final witnesses = await failedDb
                .select(failedDb.companyBootstrapWitnesses)
                .get();
            witnessCount = witnesses.length;
            witnessStatus = witnesses.length == 1
                ? witnesses.single.status
                : null;
            factsCount =
                (await failedDb.select(failedDb.companyAuthorityFacts).get())
                    .length;
          } catch (_) {
            // A failed database read must not replace the original failure.
          }
        }
        _writeOnce(
          File(
            p.join(
              lifetime.workspaces.first.receipts.path,
              'company-failure-$pid-${DateTime.now().toUtc().microsecondsSinceEpoch}.json',
            ),
          ),
          {
            'phase': phase,
            'passed': false,
            'reason': 'native-validation-failed',
            'stage': _stage,
            'lifecycleStates': lifetime.lifecycleStates,
            'witnessCount': witnessCount,
            'witnessStatus': witnessStatus,
            'factsCount': factsCount,
            'ui': _publicUiSignals(),
          },
        );
      }
      throw const _NativeFailure();
    } finally {
      FlutterError.onError = originalError;
      WidgetsBinding.instance.removeObserver(lifetime);
      await lifetime.close();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
