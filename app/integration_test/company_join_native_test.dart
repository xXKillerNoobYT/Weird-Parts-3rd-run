// Opt-in native acceptance adapter for isolated #60 and #61 exercises.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/company/company_join_page.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import '../tool/nearby_lan_workspace.dart';
import '../tool/native_nearby_test_commands.dart';
import '../tool/native_nearby_test_crypto.dart';
import '../tool/native_nearby_test_exit.dart';
import '../tool/native_nearby_test_rpc.dart';
import '../tool/native_nearby_test_tap.dart';

const joinNativeProductRevision = '0f381e9c19200ffb7a2c7ceb82524dd8019bae53';
const _enabled = bool.fromEnvironment('COMPANY_JOIN_NATIVE_MODE');
const _run = String.fromEnvironment('COMPANY_JOIN_NATIVE_RUN');
const _roleName = String.fromEnvironment('COMPANY_JOIN_NATIVE_ROLE');
const _revision = String.fromEnvironment('COMPANY_JOIN_NATIVE_SOURCE_REVISION');
const _tree = String.fromEnvironment('COMPANY_JOIN_NATIVE_SOURCE_TREE');
const _adapter = String.fromEnvironment('COMPANY_JOIN_NATIVE_ADAPTER_SHA256');
const joinNativeRun = 'j60-join-v10';
const createdJobNativeRun = 'j61-created-v5';
const _createdMode = bool.fromEnvironment('COMPANY_CREATED_JOB_NATIVE_MODE');
const _createdProductRevision = String.fromEnvironment(
  'COMPANY_CREATED_JOB_NATIVE_PRODUCT_REVISION',
);
const _pin = '1234'; // Isolated synthetic namespace only; never emitted.
const _phrase = 'Synthetic Join owner authority only 123';
const _nativeStore = NativeInstallationSecureStore();

void _require(bool value) {
  if (!value) rejectNativeTest('join-native-refused');
}

Map<String, Object?> captureJoinNativeStartupLifecycle({
  required TestWidgetsFlutterBinding binding,
  required String Function() readNativeInitialLifecycleState,
}) {
  final before = binding.lifecycleState;
  String? nativeInitial;
  if (before == null) {
    nativeInitial = readNativeInitialLifecycleState();
    final previousTestValue = binding.platformDispatcher.initialLifecycleState;
    try {
      binding.platformDispatcher.initialLifecycleStateTestValue = nativeInitial;
      binding.readTestInitialLifecycleStateFromNativeWindow();
    } finally {
      binding.platformDispatcher.initialLifecycleStateTestValue =
          previousTestValue;
    }
  }
  return {
    'nativeInitial': nativeInitial,
    'bindingBefore': before?.name,
    'bindingAfter': binding.lifecycleState?.name,
  };
}

Future<State> captureJoinNativePageState({
  required WidgetTester tester,
  required Finder page,
  required Future<void> Function(bool Function()) waitUntilReady,
}) async {
  await waitUntilReady(() => page.evaluate().length == 1);
  return tester.state(page);
}

Future<void> waitForJoinNativeSignInReady({
  required Future<void> Function(bool Function()) waitUntilReady,
}) => waitUntilReady(
  () =>
      find.byKey(const Key('company-peer-open')).evaluate().length == 1 &&
      find.byKey(const Key('company-jobs-list')).evaluate().length == 1 &&
      find.text('Loading company Jobs...').evaluate().isEmpty &&
      find.byKey(const Key('company-job-error')).evaluate().isEmpty,
);

/// Pure startup contract, tested without accessing native custody or SQLite.
void validateJoinNativeDefines({
  required bool enabled,
  required String run,
  required String role,
  required String platform,
  required String revision,
  required String tree,
  required String adapter,
  bool createdMode = false,
  String productRevision = joinNativeProductRevision,
}) {
  _require(enabled && {'windows', 'macos'}.contains(platform));
  _require(role == (platform == 'windows' ? 'owner' : 'member'));
  _require(run == (createdMode ? createdJobNativeRun : joinNativeRun));
  if (createdMode) {
    _require(
      productRevision == revision &&
          productRevision != joinNativeProductRevision &&
          RegExp(r'^[a-f0-9]{40}$').hasMatch(productRevision),
    );
  } else {
    _require(productRevision == joinNativeProductRevision);
  }
  for (final nativeRole in ['owner', 'member']) {
    joinNativeNamespace(run, nativeRole, createdMode: createdMode);
  }
  _require(RegExp(r'^[a-f0-9]{40}$').hasMatch(revision));
  _require(RegExp(r'^[a-f0-9]{40}$').hasMatch(tree));
  _require(RegExp(r'^[a-f0-9]{64}$').hasMatch(adapter));
}

/// The exact base and companion namespaces must pass the real store contract.
String joinNativeNamespace(
  String run,
  String role, {
  bool createdMode = false,
}) {
  _require(
    run == (createdMode ? createdJobNativeRun : joinNativeRun) &&
        {'owner', 'member'}.contains(role),
  );
  final family = createdMode ? 'created' : 'join';
  final namespace = 'synthetic.company.$family.$run.$role';
  validateInstallationNamespace(namespace);
  companyCustodyNamespace(namespace);
  return namespace;
}

void validateJoinNativeDeadline(int elapsed, int deadline) {
  _require(elapsed >= 0 && elapsed < deadline);
}

bool joinNativeMatchWindow({
  required int elapsed,
  required int captured,
  required int ttl,
  required int remaining,
  required int now,
  required int expires,
}) {
  final age = elapsed - captured;
  return age >= 0 && age < ttl && age < remaining && now < expires;
}

String _canonical(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(v[key])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

String _hash(Object? value) =>
    sha256.convert(utf8.encode(_canonical(value))).toString();

Map<String, dynamic> _readOwnedJson(File file) {
  _require(
    FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.file,
  );
  _require(file.lengthSync() > 0 && file.lengthSync() <= 65536);
  final value = jsonDecode(file.readAsStringSync());
  _require(value is Map<String, dynamic>);
  return value as Map<String, dynamic>;
}

/// No existing root may be adopted without the exact completed exercise receipt.
/// This check precedes NativeInstallationSecureStore and AppDatabase access.
bool validateJoinNativeExistingRoot(
  Directory root, {
  required String run,
  required String role,
  required String revision,
  required String tree,
  required String adapter,
  bool createdMode = false,
  String productRevision = joinNativeProductRevision,
}) {
  final type = FileSystemEntity.typeSync(root.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return false;
  _require(type == FileSystemEntityType.directory);
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    _require(
      FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.link,
    );
  }
  final receipt = _readOwnedJson(File(p.join(root.path, 'join-exercise.json')));
  _require(
    receipt['format'] == 1 &&
        receipt['passed'] == true &&
        receipt['run'] == run &&
        receipt['role'] == role &&
        receipt['namespace'] ==
            joinNativeNamespace(run, role, createdMode: createdMode) &&
        receipt['sourceRevision'] == revision &&
        receipt['sourceTree'] == tree &&
        receipt['adapterSha256'] == adapter &&
        receipt['productRevision'] == productRevision &&
        receipt['root'] == root.path &&
        receipt['locked'] == true,
  );
  if (createdMode) {
    _require(
      receipt['mode'] == 'created-jobs' &&
          receipt['schema'] == 8 &&
          receipt['createdJobsComplete'] == true &&
          receipt['bothJobsRendered'] == true &&
          receipt['receiptCountVerifiedBeforeLock'] == 2 &&
          productRevision == revision &&
          productRevision != joinNativeProductRevision,
    );
  }
  final identity = receipt['identity'];
  _require(
    identity is Map &&
        identity.length == 8 &&
        identity.values.every(
          (value) => value is String && value.isNotEmpty && value.length <= 64,
        ) &&
        identity.keys.toSet().containsAll({
          'installation',
          'generation',
          'publicKeySha256',
          'storeGeneration',
          'company',
          'shop',
          'user',
          'device',
        }),
  );
  return true;
}

final class _SavedPair {
  _SavedPair(this.sealed, this.plain, this.captured);
  final SealedObservation sealed;
  final RenderedObservation plain;
  final int captured;
}

enum _CreatedJobStage { enrollment, retainedPeer, cancelling }

enum _CreatedJobCancelReason { incomingInterruption, retryIncomplete }

enum CreatedJobNativeUiState {
  idle,
  pending,
  complete,
  incomplete,
  error,
  unknown,
}

final class CreatedJobNativeTerminalFailure implements Exception {
  const CreatedJobNativeTerminalFailure();
  NativeTestCommandError get error => NativeTestCommandError.stateChanged;
}

Future<NativeTestCommandResult> waitForCreatedJobNativeSyncTerminal({
  required Future<void> Function(bool Function()) waitUntilReady,
  required CreatedJobNativeUiState Function() readState,
  required bool Function() isStillCurrent,
}) async {
  bool terminal(CreatedJobNativeUiState state) =>
      state == CreatedJobNativeUiState.complete ||
      state == CreatedJobNativeUiState.incomplete ||
      state == CreatedJobNativeUiState.error;
  await waitUntilReady(() => !isStillCurrent() || terminal(readState()));
  _require(isStillCurrent());
  final state = readState();
  _require(terminal(state));
  if (state != CreatedJobNativeUiState.complete) {
    throw const CreatedJobNativeTerminalFailure();
  }
  return const NativeTestCommandResult.effect();
}

Future<NativeTestCommandResult> waitForCreatedJobNativeCloseDrain({
  required Future<void> Function(bool Function()) waitUntilReady,
  required bool Function() isDrained,
}) async {
  await waitUntilReady(isDrained);
  _require(isDrained());
  return const NativeTestCommandResult.effect();
}

CreatedJobNativeUiState createdJobNativeUiState({
  required String status,
  required bool errorVisible,
  required bool busy,
}) {
  if (busy) return CreatedJobNativeUiState.pending;
  if (errorVisible) return CreatedJobNativeUiState.error;
  if (RegExp(r'^Job snapshot synced\. Sent \d+, received \d+\.$')
      .hasMatch(status)) {
    return CreatedJobNativeUiState.complete;
  }
  if (status.startsWith('Confirmed sent ') &&
      status.contains('More Jobs pending.')) {
    return CreatedJobNativeUiState.incomplete;
  }
  if ({
    'Exchanging offline-created Jobs in both directions.',
    'Checking Job sync permissions.',
    'Comparing verified Job holdings.',
    'Exchanging Job holdings with the verified peer.',
    'Sending an offline-created Job to the retained peer.',
    'Receiving an offline-created Job from the retained peer.',
    'Confirming the Job snapshot exchange.',
  }.contains(status)) {
    return CreatedJobNativeUiState.pending;
  }
  if (status.startsWith('Ready to exchange Jobs with this verified peer ') ||
      status.startsWith('Trusted peer authenticated') ||
      status.startsWith('Checking the selected retained peer.') ||
      status == 'Pair and compare the code on both devices.') {
    return CreatedJobNativeUiState.idle;
  }
  return CreatedJobNativeUiState.unknown;
}

final class _JoinNative with WidgetsBindingObserver {
  _JoinNative(
    this.tester,
    this.workspace,
    this.db,
    this.security,
    this.restart,
  );
  final WidgetTester tester;
  final ValidationWorkspace workspace;
  final AppDatabase db;
  final InstallationSecurity security;
  final bool restart;
  final clock = Stopwatch()..start();
  late final enrollment = CompanyEnrollment(installation: security, db: db);
  NearbyController? controller;
  OwnerSession? adapterSession;
  TestSession? session;
  NativeTestCommandCache? cache;
  MatchGrantVerifier? verifier;
  _SavedPair? savedPair;
  NativeTestResidentRpc? _rpc;
  bool finished = false, closed = false, exitRequested = false;
  bool lifecycleCancelled = false;
  int lifecycleEvent = 0;
  NativeTestCommand? activeCommand;
  State? _pageState;
  int snapshotOrdinal = 0;
  String stage = 'setup';
  String? originalJobHash;
  String? initialFreshSqlHash;
  ProtectedInstallationState? initialFreshBase;
  Map<String, Object?>? initialIdentity;
  late _CreatedJobStage createdStage = restart
      ? _CreatedJobStage.retainedPeer
      : _CreatedJobStage.enrollment;
  int syncStarts = 0;
  int cancelStarts = 0;
  int interruptionStarts = 0;
  int interruptionDrains = 0;
  int joinPageEpoch = 0;
  bool routeReturned = false;
  _CreatedJobCancelReason? cancelReason;
  bool get owner => _roleName == 'owner';
  TestRole get role => owner ? TestRole.sender : TestRole.receiver;
  String get peerId => 'lan-${workspace.run}-${owner ? 'receiver' : 'sender'}';
  String get phase => restart ? 'restart' : 'exercise';
  String get namespace =>
      joinNativeNamespace(_run, _roleName, createdMode: _createdMode);
  String get productRevision =>
      _createdMode ? _createdProductRevision : joinNativeProductRevision;
  bool get reconnect =>
      restart || (_createdMode && createdStage != _CreatedJobStage.enrollment);
  bool get cancellationDrained =>
      createdStage == _CreatedJobStage.cancelling &&
      routeReturned &&
      !pageMounted &&
      !view.running &&
      effectCurrent();
  bool get incomingSyncPending =>
      !owner &&
      syncUiState == CreatedJobNativeUiState.pending &&
      joinStatus == 'Exchanging Job holdings with the verified peer.';
  bool get pageMounted =>
      find.byType(CompanyJoinPage).evaluate().length == 1 &&
      identical(_pageState, tester.state(find.byType(CompanyJoinPage)));
  NearbyViewState get view => controller!.state;
  NativeTestResidentRpc get rpc => _rpc!;

  String get joinStatus {
    final status = find.byKey(const Key('company-join-status'));
    return status.evaluate().length == 1
        ? tester.widget<Text>(status).data!
        : '';
  }

  bool buttonEnabled(String key) {
    final button = find.byKey(Key(key));
    return button.evaluate().length == 1 &&
        tester.widget<FilledButton>(button).onPressed != null;
  }

  CreatedJobNativeUiState get syncUiState => createdJobNativeUiState(
    status: joinStatus,
    errorVisible: find
        .byKey(const Key('company-join-error'))
        .evaluate()
        .isNotEmpty,
    busy:
        find.byKey(const Key('company-jobs-sync-now')).evaluate().length == 1 &&
        !buttonEnabled('company-jobs-sync-now'),
  );

  NativeTestPhase get reportedPhase {
    if (finished) return NativeTestPhase.success;
    if (_createdMode && createdStage == _CreatedJobStage.cancelling) {
      return cancellationDrained
          ? NativeTestPhase.idle
          : NativeTestPhase.transferring;
    }
    if (_createdMode && reconnect) {
      switch (syncUiState) {
        case CreatedJobNativeUiState.pending:
          return NativeTestPhase.transferring;
        case CreatedJobNativeUiState.complete:
          return NativeTestPhase.success;
        case CreatedJobNativeUiState.incomplete:
        case CreatedJobNativeUiState.error:
        case CreatedJobNativeUiState.unknown:
          return NativeTestPhase.failed;
        case CreatedJobNativeUiState.idle:
          break;
      }
    }
    return NativeTestPhase.values.byName(view.phase.name);
  }

  void requireSnapshotSafe() {
    _require(!_createdMode || createdStage != _CreatedJobStage.cancelling);
    if (_createdMode && reconnect && !finished && pageMounted) {
      _require(
        syncUiState != CreatedJobNativeUiState.pending &&
            syncUiState != CreatedJobNativeUiState.unknown,
      );
    }
  }

  Map<String, Object?> get header => {
    'format': 1,
    'run': _run,
    'role': _roleName,
    'pid': pid,
    'sourceRevision': _revision,
    'sourceTree': _tree,
    'productRevision': productRevision,
    if (_createdMode) 'mode': 'created-jobs',
    'adapterSha256': _adapter,
    'platform': Platform.operatingSystem,
    'root': workspace.root.path,
    'namespace': namespace,
  };
  void writeOnce(String name, Map<String, Object?> value) {
    final file = File(p.join(workspace.root.path, name));
    _require(
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.notFound,
    );
    file.createSync(exclusive: true);
    file.writeAsStringSync(jsonEncode({...header, ...value}), flush: true);
  }

  Map<String, Object?> _lifecycleDetails(AppLifecycleState state) => {
    'state': state.name,
    'stage': stage,
    'elapsedMillis': clock.elapsedMilliseconds,
    'controllerPhase': controller?.state.phase.name,
    'lifecycleCancelled': lifecycleCancelled,
    'pid': pid,
    'run': _run,
    'role': _roleName,
    'sourceRevision': _revision,
    'sourceTree': _tree,
    'productRevision': productRevision,
    'adapterSha256': _adapter,
  };

  void writeLifecycleBaseline(AppLifecycleState state) {
    try {
      final file = File(
        p.join(workspace.root.path, 'join-$phase-lifecycle-baseline-$pid.json'),
      );
      file.createSync(exclusive: true);
      file.writeAsStringSync(
        jsonEncode({'format': 1, 'startup': _lifecycleDetails(state)}),
        flush: true,
      );
    } catch (_) {
      // Diagnostics must not affect lifecycle cancellation or startup guards.
    }
  }

  void writeStartupLifecycleEvidence(Map<String, Object?> evidence) {
    try {
      writeOnce('join-$phase-lifecycle-startup-$pid.json', {
        'stage': stage,
        'elapsedMillis': clock.elapsedMilliseconds,
        ...evidence,
      });
    } catch (_) {
      // Diagnostics must not affect lifecycle cancellation or startup guards.
    }
  }

  void _writeLifecycleEvent(
    int event,
    Map<String, Object?>? before,
    AppLifecycleState state,
  ) {
    try {
      final file = File(
        p.join(workspace.root.path, 'join-$phase-lifecycle-$pid-$event.json'),
      );
      file.createSync(exclusive: true);
      file.writeAsStringSync(
        jsonEncode({
          'format': 1,
          'event': event,
          'before': before,
          'after': _lifecycleDetails(state),
        }),
        flush: true,
      );
    } catch (_) {
      // Diagnostics must not affect lifecycle cancellation or startup guards.
    }
  }

  Future<void> wait(bool Function() ready) async {
    final deadline = clock.elapsed + const Duration(minutes: 3);
    while (!ready() &&
        clock.elapsed < deadline &&
        (activeCommand == null ||
            clock.elapsedMilliseconds < activeCommand!.deadlineMillis)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    _require(ready());
  }

  bool effectCurrent() =>
      !lifecycleCancelled &&
      !closed &&
      !exitRequested &&
      (activeCommand == null ||
          clock.elapsedMilliseconds < activeCommand!.deadlineMillis);
  void requireBeforeEffect() {
    _require(!lifecycleCancelled && !closed && !exitRequested);
    final command = activeCommand;
    if (command != null) {
      validateJoinNativeDeadline(
        clock.elapsedMilliseconds,
        command.deadlineMillis,
      );
    }
  }

  Future<void> tap(Finder finder) async {
    requireBeforeEffect();
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    _require(finder.evaluate().length == 1);
    requireBeforeEffect();
    await tester.runAsync(
      () => guardedNativeTap(tester, finder, isStillCurrent: effectCurrent),
    );
    await tester.pump();
  }

  Future<void> enter(String key, String value) async {
    await tester.enterText(find.byKey(Key(key)), value);
    await tester.pump();
  }

  Future<void> mountGate() async {
    await tester.pumpWidget(
      WiredPartsApp(
        key: ValueKey('join-native-gate-${clock.elapsedMicroseconds}'),
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: await db.settingsDao.ensureDeviceId(),
        installation: security,
        enableCompanyBootstrap: true,
        pickCompanyRecoveryPath: owner
            ? () async => p.join(workspace.root.path, 'authority.wpca')
            : () async => null,
        pickCompanySourcePath: () async => null,
        reset: LocalDataReset(
          supportDir: workspace.support,
          documentsDir: workspace.documents,
          photosDir: workspace.photos,
        ),
      ),
    );
    await wait(
      () =>
          find.byKey(const Key('company-name')).evaluate().isNotEmpty ||
          find.byKey(const Key('company-signin-pin')).evaluate().isNotEmpty,
    );
  }

  Future<void> signInUi() async {
    _require(find.text('Company locked').evaluate().length == 1);
    await enter('company-signin-pin', _pin);
    await tap(find.byKey(const Key('company-signin')));
    await waitForJoinNativeSignInReady(waitUntilReady: wait);
  }

  Future<void> signOutUi() async {
    await tap(find.byKey(const Key('company-signout')));
    await wait(() => find.text('Company locked').evaluate().length == 1);
  }

  Future<void> createJobUi() async {
    final name = owner
        ? 'Synthetic original Join Job $_run'
        : 'Synthetic member Join Job $_run';
    await tester.scrollUntilVisible(
      find.byKey(const Key('company-job-name')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await enter('company-job-name', name);
    await tap(find.byKey(const Key('company-create-job')));
    await wait(() {
      final list = find.byKey(const Key('company-jobs-list'));
      final input = find.byKey(const Key('company-job-name'));
      final create = find.byKey(const Key('company-create-job'));
      return list.evaluate().length == 1 &&
          find
                  .descendant(of: list, matching: find.text(name))
                  .evaluate()
                  .length ==
              1 &&
          input.evaluate().length == 1 &&
          tester.widget<TextField>(input).controller!.text.isEmpty &&
          create.evaluate().length == 1 &&
          tester.widget<FilledButton>(create).onPressed != null;
    });
  }

  Future<void> assertCreatedJobsUi(int expected) async {
    final jobs = await CompanyJobCommands(enrollment: enrollment)
        .listJobs(ownerSession: adapterSession!);
    _require(jobs.length == expected);
    final list = find.byKey(const Key('company-jobs-list'));
    await wait(
      () =>
          list.evaluate().length == 1 &&
          find.text('Loading company Jobs...').evaluate().isEmpty &&
          find.byKey(const Key('company-job-error')).evaluate().isEmpty &&
          find
                  .descendant(of: list, matching: find.byType(ListTile))
                  .evaluate()
                  .length ==
              expected &&
          jobs.every((job) {
            final row = find.descendant(
              of: list,
              matching: find.byKey(Key('company-job-${job.id}')),
            );
            return row.evaluate().length == 1 &&
                find
                        .descendant(of: row, matching: find.text(job.name))
                        .evaluate()
                        .length ==
                    1;
          }),
    );
  }

  Future<void> captureOriginalCreatedJob() async {
    final records = await db.select(db.companyJobs).get();
    _require(records.length == 1 && records.single.outgoing);
    writeOnce('created-local-job.json', {
      'identity': await identity(),
      'record': records.single.toJson(),
      'jobHistorySha256': await jobHash(),
      'createdThroughProductionUi': true,
      'offlineBeforeRetainedPeerPair': true,
    });
  }

  Future<void> mountJoinPage() async {
    stage = 'join-page';
    savedPair = null;
    final pageEpoch = ++joinPageEpoch;
    routeReturned = false;
    CompanyJoinPage page() => CompanyJoinPage(
      enrollment: enrollment,
      approver: adapterSession,
      reconnect: reconnect,
      createController: (alias) => controller = NearbyController(
        deviceId: alias,
        deviceName: 'Nearby ${alias.substring(0, 6)}',
        discovery: LanNearbyDiscovery(),
        companyJoin: true,
      ),
    );
    if (_createdMode) {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey('join-native-page-$pageEpoch'),
          home: const Scaffold(),
        ),
      );
      final navigator = Navigator.of(tester.element(find.byType(Scaffold)));
      unawaited(
        navigator.push<bool>(MaterialPageRoute(builder: (_) => page())).then((
          _,
        ) {
          if (joinPageEpoch == pageEpoch) routeReturned = true;
        }),
      );
      await tester.pump();
    } else {
      await tester.pumpWidget(
        MaterialApp(key: ValueKey('join-native-page-$pageEpoch'), home: page()),
      );
    }
    stage = 'join-page-wait-build';
    _pageState = await captureJoinNativePageState(
      tester: tester,
      page: find.byType(CompanyJoinPage),
      waitUntilReady: wait,
    );
    stage = 'join-page-wait-controller';
    await wait(() => controller != null && view.running);
    stage = 'join-page-ready';
  }

  Future<String> sqlHash() async => _hash({
    for (final table in db.allTables)
      table.actualTableName:
          (await db
                  .customSelect('SELECT * FROM "${table.actualTableName}"')
                  .get())
              .map((row) => _canonical(row.data))
              .toList()
            ..sort(),
  });

  Future<String> jobHash() async => _hash({
    'jobs': (await db.select(db.jobs).get())
        .map((row) => row.toJson())
        .toList(),
    'records': (await db.select(db.companyJobs).get())
        .map((row) => row.toJson())
        .toList(),
  });
  Future<Map<String, Object?>> identity() async {
    final company = (await enrollment.readIdentity())!;
    return {
      'installation': security.identity!.id.value,
      'generation': security.identity!.generation.value,
      'publicKeySha256': sha256
          .convert(security.identity!.publicKey)
          .toString(),
      'storeGeneration': security.receivingStoreGeneration!.value,
      'company': company.companyId,
      'shop': company.shopId,
      'user': company.userId,
      'device': company.deviceId,
    };
  }

  Future<void> initialize() async {
    _require(db.schemaVersion == (_createdMode ? 8 : 7));
    if (restart) {
      final prior = _readOwnedJson(
        File(p.join(workspace.root.path, 'join-exercise.json')),
      );
      initialIdentity = await identity();
      _require(_canonical(initialIdentity) == _canonical(prior['identity']));
    }
    await mountGate();
    if (!restart && owner) {
      stage = 'owner-ui-create';
      await enter('company-name', 'Synthetic Join company $_run');
      await enter('company-pin', _pin);
      await enter('recovery-passphrase', _phrase);
      await enter('recovery-passphrase-confirm', _phrase);
      await tap(find.byKey(const Key('local-continuity-consent')));
      await tap(find.byKey(const Key('authority-only-consent')));
      await tap(find.text('Choose encrypted recovery file'));
      await tap(find.byKey(const Key('create-company')));
      await wait(
        () => find.byKey(const Key('company-peer-open')).evaluate().isNotEmpty,
      );
      await createJobUi();
      originalJobHash = await jobHash();
    } else if (restart) {
      stage = 'cold-locked-ui';
      _require(find.text('Company locked').evaluate().length == 1);
      _require(find.byKey(const Key('company-enroll-open')).evaluate().isEmpty);
      initialIdentity = await identity();
      final prior = _readOwnedJson(
        File(p.join(workspace.root.path, 'join-exercise.json')),
      );
      _require(_canonical(initialIdentity) == _canonical(prior['identity']));
      _require(await jobHash() == prior['jobHistorySha256']);
      originalJobHash = prior['jobHistorySha256'] as String;
      await signInUi();
      if (!owner) {
        _require(
          find.byKey(const Key('company-enroll-open')).evaluate().isEmpty,
        );
      }
    } else {
      _require(
        await enrollment.readStatus() == CompanyBootstrapStatus.unjoined,
      );
      _require((await db.select(db.jobs).get()).isEmpty);
      initialFreshSqlHash = await sqlHash();
      initialFreshBase = await _nativeStore.readState(namespace);
      _require(initialFreshBase != null);
    }
    // The adapter mounts the real page with a captured real LAN controller.
    // This extra legitimate kernel PIN sign-in is NOT production-main navigation evidence.
    if (owner || restart) {
      adapterSession = await tester.runAsync(() => enrollment.signIn(_pin));
    }
    if (_createdMode && owner && !restart) {
      await assertCreatedJobsUi(1);
      await captureOriginalCreatedJob();
    }
    if (_createdMode && restart) await assertCreatedJobsUi(2);
    await mountJoinPage();
    _rpc = NativeTestResidentRpc(
      appPid: pid,
      run: workspace.run,
      role: role,
      deviceId: workspace.deviceId,
      peerId: peerId,
      clockMillis: () => clock.elapsedMilliseconds,
      readInfoInLoop: () => NativeTestResidentViewInfo(
        phase: reportedPhase,
        sameNearbyState: pageMounted,
        discovered: view.peers.length == 1,
        codePresent: view.verifyCode != null,
      ),
    );
    rpc.refreshInfoInLoop();
    writeOnce('join-$phase-ready-$pid.json', {
      'phase': phase,
      'encounterAlias': controller!.deviceId,
      'controlDeviceId': workspace.deviceId,
      'controlPeerId': peerId,
      'extraKernelSignin': owner || restart,
      'productionMainNavigationTested': false,
      if (originalJobHash != null) 'originalJobHistorySha256': originalJobHash,
    });
    register();
  }

  bool params(Map<String, String> values, Set<String> expected) {
    final keys = values.keys.where((key) => key != 'isolateId').toSet();
    return keys.length == expected.length && keys.containsAll(expected);
  }

  developer.ServiceExtensionResponse response(Map<String, Object> value) =>
      developer.ServiceExtensionResponse.result(jsonEncode(value));
  void register() {
    developer.registerExtension(
      'ext.wired_parts.nearbyTest.info',
      (_, values) async => response(
        params(values, {}) ? rpc.info() : {'version': 1, 'outcome': 'rejected'},
      ),
    );
    developer.registerExtension(
      'ext.wired_parts.nearbyTest.configure',
      (_, values) async => response(
        params(values, {'data'})
            ? await rpc.configure(values['data']!)
            : {'version': 1, 'outcome': 'rejected'},
      ),
    );
    developer.registerExtension(
      'ext.wired_parts.nearbyTest.command',
      (_, values) async => response(
        !params(values, {'data'})
            ? {'version': 1, 'outcome': 'rejected'}
            : cache
                      ?.submitJson(
                        values['data']!,
                        allowedActions: {
                          NativeTestAction.observe,
                          NativeTestAction.pair,
                          NativeTestAction.matchWithGrant,
                          NativeTestAction.send,
                          NativeTestAction.accept,
                          NativeTestAction.snapshot,
                          NativeTestAction.finish,
                          if (!_createdMode) NativeTestAction.normalExit,
                        },
                      )
                      .toJson() ??
                  {'version': 1, 'outcome': 'not-configured'},
      ),
    );
  }

  String renderedCode() {
    final code = view.verifyCode;
    _require(
      code != null &&
          RegExp(r'^\d{6}$').hasMatch(code) &&
          find.byKey(const Key('company-join-code')).evaluate().length == 1 &&
          tester
                  .widget<Text>(find.byKey(const Key('company-join-code')))
                  .data ==
              code,
    );
    return code!;
  }

  Future<NativeTestCommandResult> finishCreatedJobs() async {
    _require(_createdMode && !finished);
    if (createdStage == _CreatedJobStage.cancelling) {
      _require(cancellationDrained);
      if (cancelReason == _CreatedJobCancelReason.incomingInterruption) {
        interruptionDrains++;
      }
      writeOnce('created-cancel-drained-$pid-$cancelStarts.json', {
        'reason': cancelReason!.name,
        'actualUiRouteReturned': routeReturned,
        'controllerRunning': view.running,
        'lifecycleCurrent': effectCurrent(),
        'databaseRead': false,
      });
      await enrollment.signOut();
      adapterSession = null;
      await mountGate();
      await signInUi();
      adapterSession = await tester.runAsync(() => enrollment.signIn(_pin));
      createdStage = _CreatedJobStage.retainedPeer;
      await mountJoinPage();
      writeOnce('created-retry-ready-$pid-$cancelStarts.json', {
        'encounterAlias': controller!.deviceId,
        'freshPairRequired': true,
        'interruptionStarts': interruptionStarts,
        'interruptionDrains': interruptionDrains,
        'historyReverification': 'next full snapshot required',
      });
      return const NativeTestCommandResult.effect();
    }
    if (createdStage == _CreatedJobStage.retainedPeer &&
        (incomingSyncPending ||
            syncUiState == CreatedJobNativeUiState.incomplete ||
            syncUiState == CreatedJobNativeUiState.error)) {
      requireBeforeEffect();
      final close = find.byKey(const Key('company-join-close'));
      _require(
        close.evaluate().length == 1 &&
            tester.widget<TextButton>(close).onPressed != null,
      );
      cancelReason = incomingSyncPending
          ? _CreatedJobCancelReason.incomingInterruption
          : _CreatedJobCancelReason.retryIncomplete;
      cancelStarts++;
      if (cancelReason == _CreatedJobCancelReason.incomingInterruption) {
        interruptionStarts++;
      }
      writeOnce('created-cancel-start-$pid-$cancelStarts.json', {
        'reason': cancelReason!.name,
        'status': joinStatus,
        'databaseRead': false,
        'effect': 'possible-until-actual-route-return-and-controller-stop',
      });
      createdStage = _CreatedJobStage.cancelling;
      savedPair = null;
      await tap(close);
      return waitForCreatedJobNativeCloseDrain(
        waitUntilReady: wait,
        isDrained: () => cancellationDrained,
      );
    }
    requireSnapshotSafe();
    if (createdStage == _CreatedJobStage.enrollment) {
      _require(
        !restart &&
            (owner
                ? joinStatus == 'The other installation confirmed activation.'
                : joinStatus.startsWith(
                    'Joined. Sign in with the existing company PIN.',
                  )),
      );
      await controller!.dispose();
      await enrollment.signOut();
      adapterSession = null;
      await mountGate();
      await signInUi();
      if (!owner) {
        _require((await db.select(db.jobs).get()).isEmpty);
        await createJobUi();
      }
      adapterSession = await tester.runAsync(() => enrollment.signIn(_pin));
      await assertCreatedJobsUi(1);
      if (!owner) await captureOriginalCreatedJob();
      originalJobHash = await jobHash();
      writeOnce('created-before-retained-pair-$pid.json', await snapshot());
      createdStage = _CreatedJobStage.retainedPeer;
      await mountJoinPage();
      writeOnce('created-retained-ready-$pid.json', {
        'encounterAlias': controller!.deviceId,
        'originalJobHistorySha256': originalJobHash,
        'freshPairRequired': true,
      });
      return const NativeTestCommandResult.effect();
    }
    _require(restart || syncUiState == CreatedJobNativeUiState.complete);
    await controller!.dispose();
    await enrollment.signOut();
    adapterSession = null;
    await mountGate();
    await signInUi();
    adapterSession = await tester.runAsync(() => enrollment.signIn(_pin));
    await assertCreatedJobsUi(2);
    final verified = await snapshot();
    _require(verified['receiptCountVerified'] == 2);
    writeOnce('created-$phase-production-list-$pid.json', {
      ...verified,
      'productionMainNavigationTested': false,
      'productionJobsPanelRendered': true,
      'bothJobsRendered': true,
    });
    await enrollment.signOut();
    adapterSession = null;
    await signOutUi();
    final evidence = await snapshot();
    writeOnce('join-$phase.json', {
      ...evidence,
      'phase': phase,
      'passed': true,
      'locked': true,
      'createdJobsComplete': true,
      'productionMainNavigationTested': false,
      'productionJobsPanelRendered': true,
      'bothJobsRendered': true,
      'receiptCountVerifiedBeforeLock': 2,
      'interruptionStarts': interruptionStarts,
      'interruptionDrains': interruptionDrains,
      'nativeInterruptionAcceptance':
          interruptionStarts > 0 && interruptionStarts == interruptionDrains
          ? 'actual-receiver-Cancel-drained-and-history-reverified; peer retry evidence required'
          : 'NOT_RUN locally; paired-device evidence required',
      'normalExit':
          'external normal UI quit and cold readback evidence required',
    });
    finished = true;
    return const NativeTestCommandResult.effect();
  }

  Future<NativeTestCommandResult> perform(NativeTestCommand command) async {
    _require(!exitRequested);
    if (!finished) {
      _require(
        pageMounted ||
            (_createdMode && createdStage == _CreatedJobStage.cancelling),
      );
    }
    if (_createdMode && createdStage == _CreatedJobStage.cancelling) {
      _require(
        command.action == NativeTestAction.observe ||
            command.action == NativeTestAction.finish,
      );
    }
    switch (command.action) {
      case NativeTestAction.observe:
        if (_createdMode) {
          writeOnce('created-observe-$pid-${++snapshotOrdinal}.json', {
            'phase': reportedPhase.name,
            'createdStage': createdStage.name,
            'syncState': syncUiState.name,
            'status': joinStatus,
            'syncStarts': syncStarts,
            'routeReturned': routeReturned,
            'cancellationDrained': cancellationDrained,
            'availabilityButtonVisible': find
                .byKey(const Key('company-jobs-enable-sync'))
                .evaluate()
                .isNotEmpty,
            'syncButtonEnabled': buttonEnabled('company-jobs-sync-now'),
            'databaseRead': false,
          });
        }
        SealedObservation? sealed;
        if (command.comparison != null) {
          _require(!finished && view.phase == NearbyPhase.pairing);
          final plain = RenderedObservation(
            renderedCode: renderedCode(),
            attemptId: view.verificationAttemptId!,
            localExpiresAtMillis:
                view.verificationExpiresAt!.millisecondsSinceEpoch,
            remainingMillis:
                view.verificationExpiresAt!.millisecondsSinceEpoch -
                DateTime.now().millisecondsSinceEpoch,
            deviceId: session!.deviceId,
            peerId: session!.peerId,
          );
          final captured = clock.elapsedMilliseconds;
          sealed = await sealRenderedObservation(
            session: session!,
            challenge: command.comparison!,
            observation: plain,
          );
          savedPair = _SavedPair(sealed, plain, captured);
        }
        return NativeTestCommandResult.observation(
          NativeTestObservationResult(
            session: session!,
            phase: reportedPhase,
            sameNearbyState: pageMounted,
            discovered: !finished && view.peers.length == 1,
            codePresent: !finished && view.verifyCode != null,
            sealedObservation: sealed,
          ),
        );
      case NativeTestAction.pair:
        _require(
          !finished &&
              view.phase == NearbyPhase.looking &&
              view.peers.length == 1,
        );
        await tap(
          find.byKey(
            ValueKey('company-join-pair-${view.peers.single.deviceId}'),
          ),
        );
        return const NativeTestCommandResult.effect();
      case NativeTestAction.matchWithGrant:
        final saved = savedPair;
        _require(saved != null);
        bool current() =>
            effectCurrent() &&
            pageMounted &&
            view.phase == NearbyPhase.pairing &&
            view.verificationAttemptId == saved!.plain.attemptId &&
            view.verificationExpiresAt!.millisecondsSinceEpoch ==
                saved.plain.localExpiresAtMillis &&
            renderedCode() == saved.plain.renderedCode &&
            joinNativeMatchWindow(
              elapsed: clock.elapsedMilliseconds,
              captured: saved.captured,
              ttl: command.grant!.ttlMillis,
              remaining: saved.plain.remainingMillis,
              now: DateTime.now().millisecondsSinceEpoch,
              expires: saved.plain.localExpiresAtMillis,
            );
        await verifier!.consume(
          grant: command.grant!,
          savedObservation: saved!.sealed,
          challenge: saved.sealed.challenge,
          savedPlaintext: saved.plain,
          activeAttemptId: view.verificationAttemptId!,
          currentRenderedCode: renderedCode(),
          localExpiresAtMillis:
              view.verificationExpiresAt!.millisecondsSinceEpoch,
          observationCapturedElapsedMillis: saved.captured,
          nowElapsedMillis: clock.elapsedMilliseconds,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
          isStillCurrent: current,
        );
        await guardedNativeTap(
          tester,
          find.byKey(const Key('company-join-match')),
          isStillCurrent: current,
        );
        return const NativeTestCommandResult.effect();
      case NativeTestAction.send:
        _require(!finished && view.phase == NearbyPhase.paired);
        if (reconnect) {
          _require(_createdMode || !owner);
          // Explicit command selects the sole already-retained proof, then Verify.
          final peers = find
              .byType(ListTile)
              .evaluate()
              .where(
                (e) =>
                    e.widget.key is ValueKey<String> &&
                    ((e.widget.key as ValueKey<String>).value).startsWith(
                      'company-peer-',
                    ),
              )
              .toList();
          _require(peers.length == 1);
          await tap(find.byKey(peers.single.widget.key!));
          await tap(find.byKey(const Key('company-peer-verify')));
          await wait(
            () =>
                find
                    .text(
                      _createdMode
                          ? 'Trusted peer authenticated. Verification alone does not exchange Jobs.'
                          : 'Trusted peer authenticated for this live connection. Job catch-up remains unavailable.',
                    )
                    .evaluate()
                    .length ==
                1,
          );
        } else {
          _require(!owner);
          await tap(find.byKey(const Key('company-join-request')));
          await wait(
            () =>
                find
                    .text(
                      'Waiting for explicit approval on the company device.',
                    )
                    .evaluate()
                    .length ==
                1,
          );
        }
        return const NativeTestCommandResult.effect();
      case NativeTestAction.accept:
        if (_createdMode && reconnect) {
          _require(!finished && view.phase == NearbyPhase.paired);
          requireSnapshotSafe();
          if (buttonEnabled('company-jobs-enable-sync')) {
            await tap(find.byKey(const Key('company-jobs-enable-sync')));
            await wait(() => buttonEnabled('company-jobs-sync-now'));
            return const NativeTestCommandResult.effect();
          }
          _require(owner && buttonEnabled('company-jobs-sync-now'));
          requireBeforeEffect();
          syncStarts++;
          final syncPage = _pageState;
          await tap(find.byKey(const Key('company-jobs-sync-now')));
          return waitForCreatedJobNativeSyncTerminal(
            waitUntilReady: wait,
            readState: () => syncUiState,
            isStillCurrent: () =>
                effectCurrent() &&
                pageMounted &&
                identical(_pageState, syncPage),
          );
        }
        _require(!restart && !finished && view.phase == NearbyPhase.paired);
        await tap(
          find.byKey(
            Key(owner ? 'company-join-approve' : 'company-join-consent'),
          ),
        );
        await wait(() {
          if (find
              .byKey(const Key('company-join-error'))
              .evaluate()
              .isNotEmpty) {
            return false;
          }
          if (!owner) {
            return find
                    .text(
                      _createdMode
                          ? 'Joined. Sign in with the existing company PIN. Reconnect to the trusted peer and enable Job availability to use Sync Now.'
                          : 'Joined. Sign in with the existing company PIN. Jobs arrive only through a later catch-up feature.',
                    )
                    .evaluate()
                    .length ==
                1;
          }
          final approve = find.byKey(const Key('company-join-approve'));
          return approve.evaluate().length == 1 &&
              tester.widget<FilledButton>(approve).onPressed != null &&
              find
                      .text(
                        'Provision prepared locally. Waiting for the other installation to consent.',
                      )
                      .evaluate()
                      .length ==
                  1;
        });
        return const NativeTestCommandResult.effect();
      case NativeTestAction.snapshot:
        final evidence = await snapshot();
        writeOnce(
          'join-$phase-snapshot-$pid-${++snapshotOrdinal}.json',
          evidence,
        );
        final counts = evidence['counts'] as Map<String, int>;
        return NativeTestCommandResult.snapshot(
          NativeTestSnapshotResult(
            digest: _hash(evidence),
            assetsDigest: _hash([]),
            sharedSettingsDigest: _hash([]),
            profileDigest: _hash(workspace.deviceId),
            schemaVersion: _createdMode ? 8 : 7,
            tableCount: counts.length,
            rowCount: counts.values.fold(0, (a, b) => a + b),
            assetCount: 0,
            integrityValid: true,
            referencesValid: true,
            profileEqual: false,
            assetsEqual: false,
            settingsEqual: false,
            ownershipEqual: false,
          ),
        );
      case NativeTestAction.finish:
        if (_createdMode) return finishCreatedJobs();
        _require(!finished);
        final status = find.byKey(const Key('company-join-status'));
        _require(status.evaluate().length == 1);
        final text = tester.widget<Text>(status).data!;
        _require(
          restart
              ? text.startsWith('Trusted peer authenticated')
              : owner
              ? text == 'The other installation confirmed activation.'
              : text.startsWith(
                  'Joined. Sign in with the existing company PIN.',
                ),
        );
        await controller!.dispose();
        await enrollment.signOut();
        adapterSession = null;
        await mountGate();
        await signInUi();
        if (!owner && !restart) {
          _require((await db.select(db.jobs).get()).isEmpty);
          writeOnce('join-exercise-member-empty.json', await snapshot());
          await createJobUi();
        }
        if (owner || restart) {
          _require(await jobHash() == originalJobHash);
        }
        await signOutUi();
        final evidence = await snapshot();
        writeOnce('join-$phase.json', {
          'phase': phase,
          'passed': true,
          'locked': true,
          ...evidence,
          'extraKernelSignin': owner || restart,
          'productionMainNavigationTested': false,
          'normalExit': 'external process evidence required',
        });
        finished = true;
        return const NativeTestCommandResult.effect();
      case NativeTestAction.normalExit:
        _require(!_createdMode);
        requireBeforeEffect();
        _require(
          finished && find.text('Company locked').evaluate().length == 1,
        );
        exitRequested = true;
        writeOnce('join-$phase-normal-exit-$pid.json', {
          'requested': true,
          'closed': false,
        });
        await requestNativeTestExit();
        return const NativeTestCommandResult.effect(
          effect: NativeTestEffect.possible,
        );
      case NativeTestAction.markReceivedDatabase:
        rejectNativeTest('copy-forbidden');
    }
  }

  Future<Map<String, Object?>> snapshot() async {
    requireSnapshotSafe();
    final counts = <String, int>{};
    for (final table in db.allTables) {
      counts[table.actualTableName] =
          (await db
                  .customSelect(
                    'SELECT COUNT(*) AS n FROM "${table.actualTableName}"',
                  )
                  .getSingle())
              .read<int>('n');
    }
    _require(counts.length == (_createdMode ? 28 : 27));
    final schema = (await db.customSelect('PRAGMA user_version').getSingle())
        .data
        .values
        .single;
    _require(schema == (_createdMode ? 8 : 7));
    _require(
      (await db.customSelect('PRAGMA integrity_check').getSingle())
              .data
              .values
              .single ==
          'ok',
    );
    _require((await db.customSelect('PRAGMA foreign_key_check').get()).isEmpty);
    final active =
        await enrollment.readStatus() == CompanyBootstrapStatus.active;
    final evidence = <String, Object?>{
      'counts': counts,
      'schema': schema,
      'integrityValid': true,
      'referencesValid': true,
      'jobHistorySha256': await jobHash(),
      'locked': enrollment.currentSession == null,
      'phase': phase,
      'ui': {
        'approveVisible': find
            .byKey(const Key('company-join-approve'))
            .evaluate()
            .isNotEmpty,
        'consentVisible': find
            .byKey(const Key('company-join-consent'))
            .evaluate()
            .isNotEmpty,
        'errorVisible': find
            .byKey(const Key('company-join-error'))
            .evaluate()
            .isNotEmpty,
        'lockedVisible': find.text('Company locked').evaluate().length == 1,
      },
      'snapshotSemantics': 'Join public evidence; copy-comparison booleans are false/not asserted',
    };
    if (_createdMode) {
      evidence.addAll({
        'mode': 'created-jobs',
        'createdStage': createdStage.name,
        'syncState': syncUiState.name,
        'status': joinStatus,
        'syncStarts': syncStarts,
        'interruptionStarts': interruptionStarts,
        'interruptionDrains': interruptionDrains,
        'sqlSha256': await sqlHash(),
        'snapshotSemantics': 'Scoped created-Job records, original bytes, local receipts and peer ACKs; no mesh, edit, deletion, asset or general-copy assertion',
      });
    }
    if (!active && !owner && !restart) {
      final current = (await _nativeStore.readState(namespace))!;
      _require(
        await sqlHash() == initialFreshSqlHash &&
            current.revision == initialFreshBase!.revision &&
            base64Encode(current.bytes) ==
                base64Encode(initialFreshBase!.bytes) &&
            await _nativeStore.readState(companyCustodyNamespace(namespace)) ==
                null,
      );
      evidence['preconsentSqlAndProtectedUnchanged'] = true;
    }
    if (active) {
      evidence['identity'] = await identity();
      final base = (await _nativeStore.readState(namespace))!;
      final custody = (await _nativeStore.readState(
        companyCustodyNamespace(namespace),
      ))!;
      final body = jsonDecode(utf8.decode(custody.bytes)) as Map;
      _require(
        base.bytes.length <= kInstallationStateLimit &&
            custody.bytes.length <= kInstallationStateLimit,
      );
      _require(
        body['status'] == 'active' &&
            body['recoverySeed'] == null &&
            body['attempts'] == 8,
      );
      if (!owner) {
        _require(
          body['v'] == 2 &&
              !body.containsKey('rootSeed') &&
              !body.containsKey('recoverySeed') &&
              !body.containsKey('digest'),
        );
        _require(
          !File(p.join(workspace.root.path, 'authority.wpca')).existsSync(),
        );
      }
      final records = await db.select(db.companyJobs).get();
      var verifiedCount = 0;
      if (_createdMode) {
        final ownerSession = adapterSession;
        if (ownerSession != null && ownerSession.isValid) {
          final commands = CompanyJobCommands(enrollment: enrollment);
          final jobs = await commands.listJobs(ownerSession: ownerSession);
          _require(jobs.length == records.length);
          for (final record in records) {
            final verified = await commands.verifySyncRecord(
              record.jobId,
              ownerSession,
            );
            _require(
              _canonical(verified.toJson()) == _canonical(record.toJson()),
            );
            verifiedCount++;
          }
          evidence['confirmedPeerCounts'] =
              await CompanyCreatedJobSync.confirmedPeerCounts(
                enrollment,
                ownerSession,
              );
        }
        final originalFile = File(
          p.join(workspace.root.path, 'created-local-job.json'),
        );
        if (originalFile.existsSync()) {
          final original = _readOwnedJson(originalFile);
          _require(
            original['mode'] == 'created-jobs' &&
                original['run'] == _run &&
                original['role'] == _roleName &&
                original['namespace'] == namespace &&
                original['sourceRevision'] == _revision &&
                original['sourceTree'] == _tree &&
                original['adapterSha256'] == _adapter &&
                original['productRevision'] == productRevision &&
                _canonical(original['identity']) ==
                    _canonical(await identity()),
          );
          final savedRecord = original['record'] as Map;
          final local = records
              .where((r) => r.jobId == savedRecord['jobId'])
              .toList();
          _require(
            local.length == 1 &&
                _canonical(local.single.toJson()) == _canonical(savedRecord),
          );
          evidence['originalLocalRecordUnchanged'] = true;
        }
        final acks = await db.select(db.companyJobPeerAcks).get();
        evidence.addAll({
          'baseProtectedRevision': base.revision,
          'baseProtectedSha256': sha256.convert(base.bytes).toString(),
          'custodyProtectedRevision': custody.revision,
          'custodyProtectedSha256': sha256.convert(custody.bytes).toString(),
          'records':
              records.map((record) {
                final operation = jsonDecode(record.operationBytes) as Map;
                final body = operation['body'] as Map;
                return {
                  ...record.toJson(),
                  'operationSha256': sha256
                      .convert(utf8.encode(record.operationBytes))
                      .toString(),
                  'projectionSha256': sha256
                      .convert(utf8.encode(record.projectionBytes))
                      .toString(),
                  'receiptSha256': sha256
                      .convert(utf8.encode(record.receiptBytes))
                      .toString(),
                  'originalUser': body['user'],
                  'originalDevice': body['device'],
                  'originalInstallation': body['installation'],
                  'originalGeneration': body['generation'],
                };
              }).toList()..sort(
                (a, b) =>
                    (a['jobId'] as String).compareTo(b['jobId'] as String),
              ),
          'receiptSha256': _hash(
            records.map((r) => r.receiptBytes).toList()..sort(),
          ),
          'ackCount': acks.length,
          'ackSha256': _hash(
            acks.map((r) => _canonical(r.toJson())).toList()..sort(),
          ),
          'acks': acks.map((r) => r.toJson()).toList(),
          'receiptVerification': verifiedCount == records.length
              ? 'typed-public-verifier'
              : 'locked-not-performed',
          'ackVerification': adapterSession?.isValid == true
              ? 'confirmedPeerCounts'
              : 'locked-not-performed',
        });
      } else {
        for (final record in records) {
          await JobLineCommandReceipt.verifyAdmissionSeal(
            record.receiptBytes,
            security.identity!,
            security.receivingStoreGeneration!.value,
            expectedFamily: CompanyCommandFamily.jobCreate,
          );
          verifiedCount++;
        }
      }
      evidence.addAll({
        'nativeCustodyActive': true,
        'rootless': !owner,
        'noAuthoritySeedExport': true,
        'nativeRecordsWithinCapacity': true,
        'baseProtectedBytes': base.bytes.length,
        'custodyProtectedBytes': custody.bytes.length,
        'receiptCountVerified': verifiedCount,
      });
    }
    requireSnapshotSafe();
    return evidence;
  }

  Future<void> run() async {
    while (!closed && clock.elapsed < const Duration(minutes: 30)) {
      rpc.markLoopStarted();
      rpc.processConfigurationInLoop((next) {
        _require(session == null && pageMounted && !finished);
        session = next;
        cache = NativeTestCommandCache(
          session: next,
          clockMillis: () => clock.elapsedMilliseconds,
        );
        verifier = MatchGrantVerifier(next);
      });
      cache?.tick();
      final command = cache?.takeNext();
      NativeTestCommandResult? result;
      if (command != null) {
        activeCommand = command;
        stage = 'command-${command.action.name}';
        try {
          result = await perform(command);
        } on CreatedJobNativeTerminalFailure catch (failure) {
          cache!.fail(
            command,
            failure.error,
            effect: NativeTestEffect.completed,
          );
        } catch (_) {
          cache!.fail(
            command,
            NativeTestCommandError.harnessFailed,
            effect: NativeTestEffect.possible,
          );
        }
      }
      activeCommand = null;
      if (!finished && !pageMounted) {
        await enrollment.signOut();
        adapterSession = null;
      }
      rpc.markPumpStarted();
      try {
        await tester.pump(const Duration(milliseconds: 100));
      } finally {
        rpc.markPumpSettled();
      }
      rpc.refreshInfoInLoop();
      if (command != null && result != null) cache!.complete(command, result);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    _require(closed);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    _rpc?.close();
    await controller?.dispose();
    await enrollment.signOut();
    await db.close();
    workspace.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final event = ++lifecycleEvent;
    Map<String, Object?>? before;
    try {
      before = _lifecycleDetails(state);
    } catch (_) {
      // The existing safety response must run even when diagnostics fail.
    }
    if (state != AppLifecycleState.resumed) {
      lifecycleCancelled = true;
      adapterSession = null;
      unawaited(enrollment.signOut());
      unawaited(controller?.stop());
    }
    _writeLifecycleEvent(event, before, state);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await close();
    return AppExitResponse.exit;
  }
}

void main() {
  validateJoinNativeDefines(
    enabled: _enabled,
    run: _run,
    role: _roleName,
    platform: Platform.operatingSystem,
    revision: _revision,
    tree: _tree,
    adapter: _adapter,
    createdMode: _createdMode,
    productRevision: _createdMode
        ? _createdProductRevision
        : joinNativeProductRevision,
  );
  _require(kAppSchemaVersion == (_createdMode ? 8 : 7));
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('isolated native authorized Join resident', (tester) async {
    _JoinNative? resident;
    ValidationWorkspace? openedWorkspace;
    AppDatabase? openedDb;
    final priorError = FlutterError.onError;
    FlutterError.onError = (_) => priorError?.call(
      FlutterErrorDetails(
        exception: const NativeTestFailure('framework-failed'),
      ),
    );
    tester.testTextInput.register();
    try {
      final role = _roleName == 'owner'
          ? ValidationRole.sender
          : ValidationRole.receiver;
      final workspaceRun = 'company-$_run';
      final root = Directory(
        p.join(
          Directory.systemTemp.resolveSymbolicLinksSync(),
          'wired-parts-lan-$workspaceRun-${role.name}',
        ),
      );
      final restart = validateJoinNativeExistingRoot(
        root,
        run: _run,
        role: _roleName,
        revision: _revision,
        tree: _tree,
        adapter: _adapter,
        createdMode: _createdMode,
        productRevision: _createdMode
            ? _createdProductRevision
            : joinNativeProductRevision,
      );
      final workspace = openedWorkspace = ValidationWorkspace.open(
        run: workspaceRun,
        role: role,
        requireExisting: restart,
      );
      final namespace = joinNativeNamespace(
        _run,
        _roleName,
        createdMode: _createdMode,
      );
      if (!restart) {
        _require(!workspace.initialized);
        _require(
          await _nativeStore.readState(namespace) == null &&
              await _nativeStore.readState(
                    companyCustodyNamespace(namespace),
                  ) ==
                  null,
        );
      }
      final db = openedDb = AppDatabase.forTesting(
        NativeDatabase(File(p.join(workspace.support.path, kSqliteFileName))),
      );
      final security = InstallationSecurity(
        store: _nativeStore,
        namespace: namespace,
      );
      await security.start(db);
      _require(security.readiness == InstallationReadiness.ready);
      if (!restart) workspace.markInitialized();
      resident = _JoinNative(tester, workspace, db, security, restart);
      resident.stage = 'awaiting-startup-resumed';
      final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
      final lifecycleEvidence = captureJoinNativeStartupLifecycle(
        binding: binding,
        readNativeInitialLifecycleState: () =>
            PlatformDispatcher.instance.initialLifecycleState,
      );
      resident.writeStartupLifecycleEvidence(lifecycleEvidence);
      await resident.wait(
        () => binding.lifecycleState == AppLifecycleState.resumed,
      );
      final startupState = binding.lifecycleState;
      if (startupState != AppLifecycleState.resumed) {
        throw const NativeTestFailure('startup-lifecycle-not-resumed');
      }
      resident.stage = 'startup-resumed';
      resident.writeLifecycleBaseline(AppLifecycleState.resumed);
      WidgetsBinding.instance.addObserver(resident);
      await resident.initialize();
      await resident.run();
    } catch (_) {
      if (resident != null && !resident.closed) {
        resident.writeOnce('join-failure-$pid.json', {
          'passed': false,
          'stage': resident.stage,
        });
      }
      throw const NativeTestFailure('join-native-failed');
    } finally {
      if (resident != null) {
        WidgetsBinding.instance.removeObserver(resident);
        await resident.close();
      }
      if (resident == null) {
        await openedDb?.close();
        openedWorkspace?.close();
      }
      tester.testTextInput.unregister();
      FlutterError.onError = priorError;
    }
  }, timeout: const Timeout(Duration(minutes: 32)));
}
