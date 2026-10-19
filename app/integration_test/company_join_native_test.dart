// Opt-in native acceptance adapter for isolated #60 and #61 exercises.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;
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
const createdJobNativeRun = 'j61-created-v19';
const _createdMode = bool.fromEnvironment('COMPANY_CREATED_JOB_NATIVE_MODE');
const _jobNameMode = bool.fromEnvironment('COMPANY_JOB_NAME_NATIVE_MODE');
const jobDetailsNativeRun = 'j116-details-v3';
const _detailsMode = bool.fromEnvironment('COMPANY_JOB_DETAILS_NATIVE_MODE');
const _detailsManifestPath = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_MANIFEST',
);
const _detailsManifestSha256 = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_MANIFEST_SHA256',
);
const _detailsCheckpointPath = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_CHECKPOINT',
);
const _detailsCheckpointSha256 = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_CHECKPOINT_SHA256',
);

const _detailsBaselineRecoveryPath = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_BASELINE_RECOVERY',
);
const _detailsBaselineRecoverySha256 = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_BASELINE_RECOVERY_SHA256',
);
const _detailsPendingRecoveryPath = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_PENDING_RECOVERY',
);
const _detailsPendingRecoverySha256 = String.fromEnvironment(
  'COMPANY_JOB_DETAILS_NATIVE_PENDING_RECOVERY_SHA256',
);
const _detailsSavedOrigin = <String, String>{
  'revision': 'f3a061e064bdc83585434dbaf479b42b06753ee0',
  'tree': 'ad1c7a95d6901ff40bf0e949d7b6f7af8de9f933',
  'adapterSha256':
      'a7eca4365c2d9018d5beb2af0c551ec83d08bfc1ab959813830e581857129511',
  'productRevision': 'f3a061e064bdc83585434dbaf479b42b06753ee0',
  'manifestSha256':
      '7eae1b69e9eb5663feb971623cadf0173b3c42a6ddd8a79768a088e091fcc809',
};
const _detailsBaselineOrigin = <String, String>{
  'revision': '6a417521bb80ed6614ef5a5ef71f7158c6e0f929',
  'tree': 'a3f403d4d8dfa4bcb630d481e006a722e5d9a3cd',
  'adapterSha256':
      'ae534fe3996ff64de481bf5364a9adbb1575b70f066c85a53bccde41929be8dd',
  'productRevision': '6a417521bb80ed6614ef5a5ef71f7158c6e0f929',
  'manifestSha256':
      '188758e654d61748851a82f7800ba02225f364d089e3b7f1308343d5fc196c39',
};

void validateDetailsBaselineRecoveryOrigin(Map<String, dynamic> origin) {
  _require(
    _canonical(_recoveryObject(origin, _detailsBaselineOrigin.keys.toSet())) ==
        _canonical(_detailsBaselineOrigin),
  );
}

const _recoveryManifestPath = String.fromEnvironment(
  'COMPANY_JOB_NAME_NATIVE_RECOVERY_MANIFEST',
);
const _recoveryManifestSha256 = String.fromEnvironment(
  'COMPANY_JOB_NAME_NATIVE_RECOVERY_SHA256',
);
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

Future<void> completeJobDetailsNativeUiReturn({
  required bool Function() isStillCurrent,
  required Future<void> Function(
    Future<void> Function(bool Function()) waitUntilReady,
  )
  mountPage,
  required Future<void> Function(bool Function()) waitForCompletion,
}) async {
  _require(isStillCurrent());
  await mountPage(waitForCompletion);
  _require(isStillCurrent());
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

Future<void> saveJobNameThroughNativeUi({
  required WidgetTester tester,
  required String jobId,
  required String name,
  String? candidateOperationId,
  required Future<void> Function(Finder) tap,
  required Future<void> Function(bool Function()) waitUntilReady,
  required void Function() requireBeforeEffect,
}) async {
  final edit = candidateOperationId == null
      ? find.byKey(Key('company-job-edit-$jobId'))
      : find.byKey(Key('company-job-name-candidate-$candidateOperationId'));
  _require(edit.evaluate().length == 1);
  if (candidateOperationId == null) {
    _require(tester.widget<TextButton>(edit).onPressed != null);
  } else {
    _require(tester.widget<ListTile>(edit).onTap != null);
  }
  await tap(edit);
  final input = find.byKey(const Key('company-job-edit-name'));
  await waitUntilReady(() => input.evaluate().length == 1);
  requireBeforeEffect();
  _require(tester.widget<TextField>(input).enabled == true);
  await tester.enterText(input, name);
  await tester.pump();
  final save = find.byKey(const Key('company-job-save-name'));
  _require(save.evaluate().length == 1);
  _require(tester.widget<FilledButton>(save).onPressed != null);
  await tap(save);
  await waitUntilReady(
    () =>
        input.evaluate().isEmpty ||
        find.byKey(const Key('company-job-error')).evaluate().isNotEmpty,
  );
  _require(input.evaluate().isEmpty);
  _require(find.byKey(const Key('company-job-error')).evaluate().isEmpty);
}

void assertJobNameNativeViewUi(WidgetTester tester, List<CompanyJobView> jobs) {
  final list = find.byKey(const Key('company-jobs-list'));
  _require(list.evaluate().length == 1);
  for (final job in jobs) {
    final row = find.descendant(
      of: list,
      matching: find.byKey(Key('company-job-${job.baseJob.id}')),
    );
    _require(row.evaluate().length == 1);
    _require(
      (tester.widget<ListTile>(row).title as Text).data == job.displayName,
    );
    final conflict = find.byKey(
      Key('company-job-name-conflict-${job.baseJob.id}'),
    );
    _require(conflict.evaluate().length == (job.hasConflict ? 1 : 0));
    if (!job.hasConflict) continue;
    for (final candidate in job.candidates) {
      final item = find.descendant(
        of: conflict,
        matching: find.byKey(
          Key('company-job-name-candidate-${candidate.operationId}'),
        ),
      );
      _require(item.evaluate().length == 1);
      final tile = tester.widget<ListTile>(item);
      _require((tile.title as Text).data == candidate.name);
      final attribution = (tile.subtitle as Text).data!;
      _require(attribution.contains(candidate.originalUserId));
      _require(attribution.contains(candidate.originalDeviceId));
      _require(attribution.contains(candidate.operationId));
    }
  }
}

JobDetailValue<Object?> _nativeDetail(
  CompanyJobView job,
  JobDetailField field,
) => switch (field) {
  JobDetailField.customer => job.details.customer,
  JobDetailField.location => job.details.location,
  JobDetailField.jobNumber => job.details.jobNumber,
  JobDetailField.status => job.details.status,
  JobDetailField.notes => job.details.notes,
};

Object? _nativeDetailWire(Object? value) =>
    value is CompanyJobStatus ? value.name : value;

String _nativeDetailText(Object? value) =>
    value == null ? '(not set)' : _nativeDetailWire(value) as String;

const _nativeDetailLabels = {
  JobDetailField.customer: 'Customer',
  JobDetailField.location: 'Location',
  JobDetailField.jobNumber: 'Job number',
  JobDetailField.status: 'Status',
  JobDetailField.notes: 'Notes',
};

Future<void> saveJobDetailsThroughNativeUi({
  required WidgetTester tester,
  required String jobId,
  Map<JobDetailField, String?> text = const {},
  CompanyJobStatus? status,
  String? notesCandidateOperationId,
  required Future<void> Function(Finder) tap,
  required Future<void> Function(bool Function()) waitUntilReady,
  required void Function() requireBeforeEffect,
}) async {
  _require(!text.containsKey(JobDetailField.status));
  _require(
    notesCandidateOperationId == null || (text.isEmpty && status == null),
  );
  final section = find.byKey(Key('company-job-details-$jobId'));
  _require(section.evaluate().length == 1);
  Finder inside(String key) =>
      find.descendant(of: section, matching: find.byKey(Key(key)));
  final opener = inside(
    notesCandidateOperationId == null
        ? 'company-job-edit-details-$jobId'
        : 'company-job-details-candidate-notes-$notesCandidateOperationId',
  );
  _require(opener.evaluate().length == 1);
  if (notesCandidateOperationId == null) {
    _require(tester.widget<TextButton>(opener).onPressed != null);
  } else {
    _require(tester.widget<ListTile>(opener).onTap != null);
  }
  requireBeforeEffect();
  await tap(opener);
  final input = inside('company-job-details-notes');
  await waitUntilReady(() => input.evaluate().length == 1);
  for (final entry in text.entries) {
    final target = inside('company-job-details-${entry.key.name}');
    _require(target.evaluate().length == 1);
    requireBeforeEffect();
    if (entry.value == null) {
      final clear = inside('company-job-details-clear-${entry.key.name}');
      _require(tester.widget<CheckboxListTile>(clear).onChanged != null);
      await tap(clear);
    } else {
      _require(tester.widget<TextField>(target).enabled == true);
      await tester.ensureVisible(target);
      requireBeforeEffect();
      await tester.enterText(target, entry.value!);
      await tester.pump();
    }
  }
  if (status != null) {
    final dropdown = inside('company-job-details-status');
    _require(
      tester
              .widget<DropdownButtonFormField<CompanyJobStatus>>(dropdown)
              .onChanged !=
          null,
    );
    requireBeforeEffect();
    await tap(dropdown);
    final choice = find.text(status.name).last;
    await waitUntilReady(() => choice.evaluate().length == 1);
    requireBeforeEffect();
    await tap(choice);
  }
  final save = inside('company-job-save-details');
  _require(
    save.evaluate().length == 1 &&
        tester.widget<FilledButton>(save).onPressed != null,
  );
  requireBeforeEffect();
  await tap(save);
  await waitUntilReady(
    () =>
        input.evaluate().isEmpty ||
        inside('company-job-details-error').evaluate().isNotEmpty,
  );
  // An uncertain save remains evidence for a separate explicit retry, never an automatic retry.
  _require(
    input.evaluate().isEmpty &&
        inside('company-job-details-error').evaluate().isEmpty,
  );
}

void assertJobDetailsNativeViewUi(
  WidgetTester tester,
  List<CompanyJobView> jobs,
) {
  assertJobNameNativeViewUi(tester, jobs);
  for (final job in jobs) {
    final section = find.byKey(Key('company-job-details-${job.baseJob.id}'));
    _require(section.evaluate().length == 1);
    for (final field in JobDetailField.values) {
      final value = _nativeDetail(job, field);
      final summary = find.descendant(
        of: section,
        matching: find.byKey(
          Key('company-job-detail-${field.name}-${job.baseJob.id}'),
        ),
      );
      _require(summary.evaluate().length == 1);
      _require(
        tester.widget<Text>(summary).data ==
            '${_nativeDetailLabels[field]}: ${_nativeDetailText(value.value)}',
      );
      final conflict = find.descendant(
        of: section,
        matching: find.byKey(
          Key('company-job-details-conflict-${field.name}-${job.baseJob.id}'),
        ),
      );
      _require(conflict.evaluate().length == (value.hasConflict ? 1 : 0));
      if (!value.hasConflict) continue;
      _require(
        find
                .descendant(
                  of: conflict,
                  matching: find.text(
                    'Competing ${_nativeDetailLabels[field]!.toLowerCase()} values. Last agreed: ${_nativeDetailText(value.lastAgreedValue)}',
                  ),
                )
                .evaluate()
                .length ==
            1,
      );
      for (final candidate in value.candidates) {
        final item = find.descendant(
          of: conflict,
          matching: find.byKey(
            Key(
              'company-job-details-candidate-${field.name}-${candidate.operationId}',
            ),
          ),
        );
        _require(item.evaluate().length == 1);
        final tile = tester.widget<ListTile>(item);
        _require(
          (tile.title as Text).data == _nativeDetailText(candidate.value),
        );
        final attribution = (tile.subtitle as Text).data!;
        _require(
          attribution.contains(candidate.originalUserId) &&
              attribution.contains(candidate.originalDeviceId) &&
              attribution.contains(candidate.operationId),
        );
      }
    }
  }
}

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
  bool detailsMode = false,
  String productRevision = joinNativeProductRevision,
}) {
  _require(enabled && {'windows', 'macos'}.contains(platform));
  _require(role == (platform == 'windows' ? 'owner' : 'member'));
  _require(!detailsMode || createdMode);
  _require(
    run ==
        (detailsMode
            ? jobDetailsNativeRun
            : createdMode
            ? createdJobNativeRun
            : joinNativeRun),
  );
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
    joinNativeNamespace(
      run,
      nativeRole,
      createdMode: createdMode,
      detailsMode: detailsMode,
    );
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
  bool detailsMode = false,
}) {
  _require(!detailsMode || createdMode);
  _require(
    run ==
            (detailsMode
                ? jobDetailsNativeRun
                : createdMode
                ? createdJobNativeRun
                : joinNativeRun) &&
        {'owner', 'member'}.contains(role),
  );
  final family = detailsMode
      ? 'details'
      : createdMode
      ? 'created'
      : 'join';
  final namespace = 'synthetic.company.$family.$run.$role';
  validateInstallationNamespace(namespace);
  companyCustodyNamespace(namespace);
  return namespace;
}

void validateJoinNativeDeadline(int elapsed, int deadline) {
  _require(elapsed >= 0 && elapsed < deadline);
}

/// Completion observes an already-admitted effect; taps retain their deadline.
Future<void> waitForJoinNativeCompletion({
  required bool Function() ready,
  required int Function() elapsedMillis,
  required Future<void> Function() pump,
  required int? commandDeadlineMillis,
  bool enforceCommandDeadline = false,
}) async {
  final deadline = elapsedMillis() + const Duration(minutes: 3).inMilliseconds;
  while (!ready() &&
      elapsedMillis() < deadline &&
      (!enforceCommandDeadline ||
          commandDeadlineMillis == null ||
          elapsedMillis() < commandDeadlineMillis)) {
    await pump();
  }
  _require(ready());
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

Future<NativeTestCommandResult> performJoinNativePair({
  required bool createdMode,
  required bool finished,
  required NearbyPhase phase,
  required int peerCount,
  required Future<void> Function() tapPair,
}) async {
  _require(
    !finished &&
        (phase == NearbyPhase.looking ||
            (createdMode && phase == NearbyPhase.failed)) &&
        peerCount == 1,
  );
  await tapPair();
  return const NativeTestCommandResult.effect();
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

Map<String, dynamic> _readOwnedJson(
  File file, {
  String? expectedSha256,
  int? expectedBytes,
}) {
  _require(
    FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.file,
  );
  _require(file.lengthSync() > 0 && file.lengthSync() <= 65536);
  final bytes = file.readAsBytesSync();
  _require(
    bytes.isNotEmpty &&
        bytes.length <= 65536 &&
        (expectedBytes == null || bytes.length == expectedBytes) &&
        (expectedSha256 == null ||
            sha256.convert(bytes).toString() == expectedSha256),
  );
  final value = jsonDecode(utf8.decode(bytes));
  _require(value is Map<String, dynamic>);
  return value as Map<String, dynamic>;
}

const joinNativeInterruptedProductHashes = <String, String>{
  'app/lib/data/app_database.dart':
      'db22764807391314a109955ba076c15703bcd86f7e83fe15c09be17a8c4249e8',
  'app/lib/data/app_database.g.dart':
      'a776f3f3de353cab996ca00276dfd114817c58b227a223fb36a724f7b2ea6576',
  'app/lib/data/tables/company_jobs.dart':
      '3fdf3244c29cc3f9dc5ae5f58e06416e7ac5bcb892b6439dfa9a539a10c9b364',
  'app/lib/features/backup/backup_store.dart':
      '2c7597b5c575a36ed26894649578835030697e92e6484cbb8c7525b6ba115cc9',
  'app/lib/features/company/company_bootstrap.dart':
      'f8bda98008d884ff4246177a2b9f7ac5bbc2ad534ad99193ec0c458ebf30e5fc',
  'app/lib/features/company/company_created_job_sync.dart':
      '3c98ee5114f2041e268636c67c84d76414d8f5b51161d17c87465f2835bc868c',
  'app/lib/features/company/company_gate.dart':
      'b95dd327d6b213fe0910e426962a50c2b96f91722fc5b8a2972e3a33c533b4bf',
  'app/lib/features/company/company_jobs_panel.dart':
      '7111f4203a80e97d7131653ec9c5f8f26110a414204ad5b5df2f0b79ea68d210',
  'app/lib/features/company/company_join.dart':
      '8ab3d3a7ba6ebe4d2d05d287d9163517f1848ba7bf671d929932b4af4fe22f62',
  'app/lib/features/company/company_join_page.dart':
      'bdaf55a859223548b146b51489e1dd53284cff160710c5a5f5dcd1456c440baf',
  'app/lib/features/company/company_membership.dart':
      'e83fd5bc161a2ac342e73935431c7f82f8fcd6dc9b63f57f0d4a31077aedc6f8',
  'app/lib/features/company/company_peer_authentication.dart':
      '8ef01331649127307c78436e6b422feac4629c0bc8eaa6649f3dcdc262735273',
  'app/lib/features/company/company_protocol.dart':
      'ce88f18e1393faf3bbd95a087c0d06aac0070e312cf314be50d675513d985fe7',
  'app/lib/features/company/company_store_markers.dart':
      '5dc7cbaba499647ff456021e5d45f479ffb78a8a4f478c5c943064136a0cf5dd',
  'app/lib/features/installation/installation_security.dart':
      'c3c6587131c128b03c5bdc86349f51ed8798d81b4a21718f317b73b3ffe227de',
  'app/lib/features/job_line_commands/create_job.dart':
      'bcc041fa68e43e7332b78ca77d2e1fbdf7959a2acb34215611b5a283859e1c83',
  'app/lib/features/job_line_commands/create_job_sync.dart':
      'edb66f1f21161e59cfdef234ebac6ae360c123475221bf60910046c84d2ee0f8',
  'app/lib/features/job_line_commands/job_line_commands.dart':
      '42bd1784aba4a44a683fd522379dac8e34ad83e232e1fc9026a836ed079b7264',
  'app/lib/features/job_line_commands/rename_job.dart':
      '616420116caca3a8fec3b6cfd6754aab7b38f085aa5a9fb4a798487330480bac',
  'app/lib/features/nearby/nearby_controller.dart':
      '60f07194cf62f66da51bb8b408ccb64dd40e23cf6199a5eaded2a5da69318f16',
};

enum JoinNativeRootStage {
  fresh,
  interruptedNames,
  unresolvedConflict,
  completed,
  detailsCheckpoint,
  interruptedDetailsBaseline,
  interruptedDetailsPending,
}

final class JoinNativeRootAdmission {
  const JoinNativeRootAdmission(
    this.stage, {
    this.conflictCheckpoint,
    this.recoveryManifest,
    this.detailsCheckpoint,
    this.detailsBaselineRecovery,
    this.detailsPendingRecovery,
  });

  final JoinNativeRootStage stage;
  final Map<String, dynamic>? conflictCheckpoint;
  final Map<String, dynamic>? recoveryManifest;
  final Map<String, dynamic>? detailsCheckpoint;
  final Map<String, dynamic>? detailsBaselineRecovery;
  final Map<String, dynamic>? detailsPendingRecovery;
}

Map<String, dynamic> _recoveryObject(Object? value, Set<String> keys) {
  _require(
    value is Map<String, dynamic> &&
        value.length == keys.length &&
        value.keys.toSet().containsAll(keys),
  );
  return value as Map<String, dynamic>;
}

void validateJobDetailsNativeSourceManifest({
  required File manifest,
  required String manifestSha256,
  required String revision,
  required String tree,
  required String adapter,
  required String productRevision,
}) {
  _require(_sha256Pattern.hasMatch(manifestSha256));
  _require(
    p.isAbsolute(manifest.path) &&
        p.equals(
          p.normalize(manifest.parent.path),
          manifest.parent.resolveSymbolicLinksSync(),
        ),
  );
  final value = _readOwnedJson(manifest, expectedSha256: manifestSha256);
  _recoveryObject(value, {
    'format',
    'kind',
    'run',
    'revision',
    'tree',
    'adapterSha256',
    'productRevision',
    'sourceLfSha256',
  });
  _require(
    value['format'] == 1 &&
        value['kind'] == 'j116.details.source@1' &&
        value['run'] == jobDetailsNativeRun &&
        value['revision'] == revision &&
        value['tree'] == tree &&
        value['adapterSha256'] == adapter &&
        value['productRevision'] == productRevision &&
        productRevision == revision,
  );
  final hashes = value['sourceLfSha256'];
  _require(hashes is Map && hashes.isNotEmpty && hashes.length <= 512);
  final sources = (hashes as Map).cast<String, dynamic>();
  _require(
    sources.keys.toSet().containsAll({
      'app/lib/data/app_database.dart',
      'app/lib/data/app_database.g.dart',
      'app/lib/features/company/company_join.dart',
      'app/lib/features/company/company_protocol.dart',
      'app/lib/features/company/company_membership.dart',
      'app/lib/features/company/company_created_job_sync.dart',
      'app/lib/features/company/company_job_details_section.dart',
      'app/lib/features/installation/installation_security.dart',
      'app/lib/features/job_line_commands/job_details.dart',
      'app/tool/native_nearby_test_commands.dart',
      'app/tool/native_nearby_test_fixture.dart',
      'app/integration_test/company_join_native_test.dart',
      'app/pubspec.yaml',
      'app/pubspec.lock',
    }),
  );
  final bundle = Directory(p.join(p.dirname(manifest.path), 'source'));
  _require(
    FileSystemEntity.typeSync(bundle.path, followLinks: false) ==
        FileSystemEntityType.directory,
  );
  final present = <String>{};
  for (final entity in bundle.listSync(recursive: true, followLinks: false)) {
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    _require(
      type == FileSystemEntityType.directory ||
          type == FileSystemEntityType.file,
    );
    if (type == FileSystemEntityType.file) {
      present.add(
        p.relative(entity.path, from: bundle.path).replaceAll('\\', '/'),
      );
    }
  }
  _require(
    present.length == sources.length && present.containsAll(sources.keys),
  );
  for (final entry in sources.entries) {
    final path = entry.key;
    _require(
      !p.isAbsolute(path) &&
          !path.contains('\\') &&
          !path
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..'),
    );
    _require(
      (path.startsWith('app/lib/') ||
                  path.startsWith('app/tool/') ||
                  path ==
                      'app/integration_test/company_join_native_test.dart') &&
              path.endsWith('.dart') ||
          path == 'app/pubspec.yaml' ||
          path == 'app/pubspec.lock',
    );
    _require(
      entry.value is String && _sha256Pattern.hasMatch(entry.value as String),
    );
    final file = File(p.join(bundle.path, path));
    _require(file.lengthSync() <= 16 * 1024 * 1024);
    final bytes = utf8.encode(file.readAsStringSync().replaceAll('\r\n', '\n'));
    _require(sha256.convert(bytes).toString() == entry.value);
  }
  _require(
    sources['app/integration_test/company_join_native_test.dart'] == adapter,
  );
}

Map<String, dynamic> verifyDetailsBaselineInspection(
  Directory root,
  Map<String, dynamic> recovery,
) {
  final role = recovery['role'];
  _require({'owner', 'member'}.contains(role) && recovery['root'] == root.path);
  final originalPid = role == 'owner' ? 33960 : 87978;
  final inspectName = 'details-ui-$originalPid-20.json';
  final sharedName = 'details-shared-baseline-$role.json';
  final entries = (recovery['files'] as List).cast<Map>();
  final paths = entries.map((entry) => entry['path'] as String).toList();
  _require(
    paths.toSet().length == paths.length &&
        paths.contains(inspectName) &&
        paths.contains(sharedName) &&
        !paths.any((path) {
          final name = p.posix.basename(path);
          return name.startsWith('join-details-checkpoint-') ||
              ((name.startsWith('details-ui-') ||
                      name.startsWith('details-shared-baseline-')) &&
                  path != inspectName &&
                  path != sharedName);
        }),
  );
  Map<String, dynamic> read(String name) {
    final entry = _recoveryObject(
      entries.singleWhere((entry) => entry['path'] == name),
      {'path', 'bytes', 'sha256'},
    );
    return _readOwnedJson(
      File(p.join(root.path, name)),
      expectedBytes: entry['bytes'] as int,
      expectedSha256: entry['sha256'] as String,
    );
  }

  final inspect = read(inspectName);
  final shared = read(sharedName);
  for (final record in [inspect, shared]) {
    _require(
      record['format'] == 1 &&
          record['run'] == jobDetailsNativeRun &&
          record['role'] == role &&
          record['pid'] == originalPid &&
          record['root'] == root.path &&
          record['namespace'] == recovery['namespace'] &&
          record['namespace'] ==
              joinNativeNamespace(
                jobDetailsNativeRun,
                role as String,
                createdMode: true,
                detailsMode: true,
              ) &&
          record['mode'] == 'created-jobs' &&
          record['jobDetailsMode'] == true &&
          record['detailsBaselineRecoverySha256'] == null &&
          record['platform'] == (role == 'owner' ? 'windows' : 'macos') &&
          record['detailsManifestSha256'] ==
              _detailsBaselineOrigin['manifestSha256'],
    );
    verifyJoinNativeEvidenceProvenance(
      record,
      revision: _detailsBaselineOrigin['revision']!,
      tree: _detailsBaselineOrigin['tree']!,
      adapter: _detailsBaselineOrigin['adapterSha256']!,
      productRevision: _detailsBaselineOrigin['productRevision']!,
    );
  }
  _recoveryObject(shared, {
    'format',
    'run',
    'role',
    'pid',
    'root',
    'namespace',
    'sourceRevision',
    'sourceTree',
    'adapterSha256',
    'productRevision',
    'detailsManifestSha256',
    'jobDetailsMode',
    'mode',
    'platform',
    'selectedJob',
    'creationDigest',
    'creationHistorySha256',
    'nameRecordsSha256',
  });
  final expected = recovery['evidence'] as Map;
  _recoveryIdentity(inspect['identity']);
  _require(
    _canonical(inspect['identity']) == _canonical(expected['identity']) &&
        inspect['sqlSha256'] == expected['sqlSha256'] &&
        inspect['step'] == 'inspect' &&
        inspect['savedThroughProductionUi'] == false &&
        inspect['passed'] == false &&
        inspect['locked'] == false &&
        inspect['productionJobsPanelRendered'] == true &&
        inspect['companyControllerStoppedDuringUi'] == true &&
        inspect['schema'] == 10 &&
        inspect['integrityValid'] == true &&
        inspect['referencesValid'] == true &&
        inspect['originalLocalRecordUnchanged'] == true &&
        inspect['receiptCountVerified'] == 2 &&
        inspect['ackCount'] == 2 &&
        [
          'receiptVerification',
          'nameReceiptVerification',
          'detailsReceiptVerification',
        ].every((key) => inspect[key] == 'typed-public-verifier') &&
        inspect['ackVerification'] == 'confirmedPeerCounts',
  );
  for (final key in [
    'nameOperationCount',
    'nameReceiptCountVerified',
    'nameAckCount',
    'detailsOperationCount',
    'detailsReceiptCountVerified',
    'detailsAckCount',
  ]) {
    _require(inspect[key] == 0);
  }
  for (final key in ['nameRecords', 'detailsRecords']) {
    _require(inspect[key] is List && (inspect[key] as List).isEmpty);
  }
  for (final key in [
    'creationDigest',
    'creationHistorySha256',
    'nameRecordsSha256',
  ]) {
    _require(
      shared[key] is String && _sha256Pattern.hasMatch(shared[key] as String),
    );
  }
  _require(
    shared['selectedJob'] == inspect['selectedJob'] &&
        shared['creationHistorySha256'] == inspect['jobHistorySha256'] &&
        shared['nameRecordsSha256'] == inspect['nameRecordsSha256'],
  );
  final records = (inspect['records'] as List).cast<Map>();
  final confirmed = inspect['confirmedPeerCounts'] as Map;
  final jobs = records.map((record) => record['jobId'] as String).toList()
    ..sort();
  _require(
    records.length == 2 &&
        jobs.toSet().length == 2 &&
        shared['selectedJob'] == jobs.first &&
        confirmed.length == 2 &&
        confirmed.keys.toSet().containsAll(jobs) &&
        confirmed.values.every((count) => count == 1),
  );
  final selected = records.singleWhere(
    (record) => record['jobId'] == jobs.first,
  );
  _require(
    shared['creationDigest'] == selected['operationSha256'] &&
        shared['creationDigest'] ==
            sha256
                .convert(utf8.encode(selected['operationBytes'] as String))
                .toString(),
  );
  final views = (inspect['detailsViews'] as List).cast<Map>();
  _require(
    views.length == 2 &&
        views.map((view) => view['job']).toSet().containsAll(jobs),
  );
  for (final view in views) {
    final fields = _recoveryObject(
      view['fields'],
      JobDetailField.values.map((field) => field.name).toSet(),
    );
    for (final field in JobDetailField.values) {
      final value = fields[field.name] as Map;
      final initial = field == JobDetailField.status ? 'active' : null;
      _require(
        value['value'] == initial &&
            value['lastAgreedValue'] == initial &&
            value['hasConflict'] == false &&
            value['heads'] is List &&
            (value['heads'] as List).isEmpty &&
            value['candidates'] is List &&
            (value['candidates'] as List).isEmpty,
      );
    }
  }
  return shared;
}

Map<String, dynamic> _readDetailsBaselineRecovery(
  Directory root, {
  required String path,
  required String digest,
  required String role,
  required String revision,
  required String tree,
  required String adapter,
  required String productRevision,
  required String sourceManifestPath,
  required String sourceManifestSha256,
  required bool coldAdmission,
}) {
  _require(
    FileSystemEntity.typeSync(root.path, followLinks: false) ==
        FileSystemEntityType.directory,
  );
  _require(
    p.isAbsolute(path) &&
        p.normalize(path) == path &&
        !p.isWithin(root.path, path) &&
        path != root.path &&
        File(path).resolveSymbolicLinksSync() == path &&
        _sha256Pattern.hasMatch(digest),
  );
  final value = _readOwnedJson(File(path), expectedSha256: digest);
  _recoveryObject(value, {
    'format',
    'kind',
    'run',
    'role',
    'root',
    'namespace',
    'origin',
    'recovery',
    'originManifestPath',
    'coldArchive',
    'files',
    'originalFiles',
    'evidence',
    'retiredEpoch',
  });
  _require(
    value['format'] == 1 &&
        value['kind'] == 'j116.interrupted-baseline.recovery@1' &&
        value['run'] == jobDetailsNativeRun &&
        value['role'] == role &&
        value['root'] == root.path &&
        root.resolveSymbolicLinksSync() == root.path &&
        value['namespace'] ==
            joinNativeNamespace(
              jobDetailsNativeRun,
              role,
              createdMode: true,
              detailsMode: true,
            ),
  );
  validateDetailsBaselineRecoveryOrigin(
    _recoveryObject(value['origin'], _detailsBaselineOrigin.keys.toSet()),
  );
  _require(
    _canonical(
          _recoveryObject(
            value['recovery'],
            _detailsBaselineOrigin.keys.toSet(),
          ),
        ) ==
        _canonical({
          'revision': revision,
          'tree': tree,
          'adapterSha256': adapter,
          'productRevision': productRevision,
          'manifestSha256': sourceManifestSha256,
        }),
  );
  _require(
    value['originManifestPath'] is String &&
        p.isAbsolute(value['originManifestPath'] as String),
  );
  final originFile = File(value['originManifestPath'] as String);
  validateJobDetailsNativeSourceManifest(
    manifest: originFile,
    manifestSha256: _detailsBaselineOrigin['manifestSha256']!,
    revision: _detailsBaselineOrigin['revision']!,
    tree: _detailsBaselineOrigin['tree']!,
    adapter: _detailsBaselineOrigin['adapterSha256']!,
    productRevision: _detailsBaselineOrigin['productRevision']!,
  );
  final originalSource = _readOwnedJson(
    originFile,
    expectedSha256: _detailsBaselineOrigin['manifestSha256'],
  );
  final currentSource = _readOwnedJson(
    File(sourceManifestPath),
    expectedSha256: sourceManifestSha256,
  );
  final oldHashes = (originalSource['sourceLfSha256'] as Map)
      .cast<String, dynamic>();
  final newHashes = (currentSource['sourceLfSha256'] as Map)
      .cast<String, dynamic>();
  _require(
    oldHashes.length == 95 &&
        newHashes.length == 95 &&
        oldHashes.keys.toSet().containsAll(newHashes.keys),
  );
  for (final entry in oldHashes.entries) {
    if (entry.key == 'app/integration_test/company_join_native_test.dart') {
      continue;
    }
    _require(newHashes[entry.key] == entry.value);
  }
  _require(
    value['retiredEpoch'] is String &&
        (value['retiredEpoch'] as String).isNotEmpty &&
        (value['retiredEpoch'] as String).length <= 128,
  );
  final evidence = _recoveryObject(value['evidence'], {
    'identity',
    'sqlSha256',
    'bindingSha256',
    'companyJobCount',
    'createAckCount',
    'nameCount',
    'detailsCount',
    'nameAckCount',
    'detailsAckCount',
  });
  _recoveryIdentity(evidence['identity']);
  _require(
    evidence['companyJobCount'] == 2 &&
        evidence['createAckCount'] == 2 &&
        evidence['nameCount'] == 0 &&
        evidence['detailsCount'] == 0 &&
        evidence['nameAckCount'] == 0 &&
        evidence['detailsAckCount'] == 0,
  );
  for (final key in ['sqlSha256', 'bindingSha256']) {
    _require(
      evidence[key] is String &&
          _sha256Pattern.hasMatch(evidence[key] as String),
    );
  }
  final files = value['files'];
  _require(files is List && files.isNotEmpty && files.length <= 256);
  final entries = <String, Map<String, dynamic>>{};
  var totalBytes = 0;
  for (final rawFile in files as List) {
    final entry = _recoveryObject(rawFile, {'path', 'bytes', 'sha256'});
    final relative = _recoveryRelative(entry['path']);
    _require(
      !entries.containsKey(relative) &&
          entry['bytes'] is int &&
          (entry['bytes'] as int) >= 0 &&
          (entry['bytes'] as int) <= 64 * 1024 * 1024 &&
          entry['sha256'] is String &&
          _sha256Pattern.hasMatch(entry['sha256'] as String),
    );
    entries[relative] = entry;
    totalBytes += entry['bytes'] as int;
  }
  _require(
    totalBytes <= 256 * 1024 * 1024 &&
        entries.containsKey('support/$kSqliteFileName'),
  );
  verifyDetailsBaselineInspection(root, value);
  final pid = role == 'owner' ? 33960 : 87978;
  final origins = _recoveryObject(value['originalFiles'], {
    'owner',
    'ready',
    'localCreation',
    'priorSnapshot',
  });
  _require(
    _canonical(origins) ==
        _canonical({
          'owner': 'validation-owner.json',
          'ready': 'join-exercise-ready-$pid.json',
          'localCreation': 'created-local-job.json',
          'priorSnapshot': 'created-before-retained-pair-$pid.json',
        }),
  );
  final archivePath = value['coldArchive'];
  _require(
    archivePath is String &&
        p.isAbsolute(archivePath) &&
        p.normalize(archivePath) == archivePath &&
        !p.isWithin(root.path, archivePath) &&
        archivePath != root.path &&
        Directory(archivePath).resolveSymbolicLinksSync() == archivePath,
  );
  void verifyFiles(Directory directory) {
    _require(
      FileSystemEntity.typeSync(directory.path, followLinks: false) ==
          FileSystemEntityType.directory,
    );
    final seen = <String>{};
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      _require(
        type == FileSystemEntityType.directory ||
            type == FileSystemEntityType.file,
      );
      if (type != FileSystemEntityType.file) continue;
      final relative = p
          .relative(entity.path, from: directory.path)
          .replaceAll('\\', '/');
      final entry = entries[relative];
      _require(entry != null && seen.add(relative));
      final file = File(entity.path);
      _require(
        file.lengthSync() == entry!['bytes'] &&
            sha256.convert(file.readAsBytesSync()).toString() ==
                entry['sha256'],
      );
    }
    _require(seen.length == entries.length);
  }

  verifyFiles(Directory(archivePath as String));
  if (coldAdmission) verifyFiles(root);
  for (final entry in origins.entries) {
    final relative = _recoveryRelative(entry.value);
    final frozen = entries[relative];
    _require(frozen != null);
    final record = _readOwnedJson(
      File(p.join(root.path, relative)),
      expectedSha256: frozen!['sha256'] as String,
      expectedBytes: frozen['bytes'] as int,
    );
    if (entry.key == 'owner') {
      _recoveryObject(record, {'format', 'run', 'role', 'root', 'initialized'});
      _require(
        record['format'] == 1 &&
            record['run'] == 'company-$jobDetailsNativeRun' &&
            record['role'] == (role == 'owner' ? 'sender' : 'receiver') &&
            record['root'] == root.path &&
            record['initialized'] == true,
      );
    } else {
      _require(
        record['format'] == 1 &&
            record['run'] == jobDetailsNativeRun &&
            record['role'] == role &&
            record['pid'] == pid &&
            record['root'] == root.path &&
            record['namespace'] == value['namespace'] &&
            record['jobDetailsMode'] == true &&
            record['detailsManifestSha256'] ==
                _detailsBaselineOrigin['manifestSha256'],
      );
      verifyJoinNativeEvidenceProvenance(
        record,
        revision: _detailsBaselineOrigin['revision']!,
        tree: _detailsBaselineOrigin['tree']!,
        adapter: _detailsBaselineOrigin['adapterSha256']!,
        productRevision: _detailsBaselineOrigin['productRevision']!,
      );
      if (entry.key != 'ready') {
        _require(
          _canonical(record['identity']) == _canonical(evidence['identity']),
        );
      }
      if (entry.key == 'priorSnapshot') {
        _require(
          record['schema'] == 10 &&
              record['receiptCountVerified'] == 1 &&
              record['nameOperationCount'] == 0 &&
              record['detailsOperationCount'] == 0 &&
              record['ackCount'] == 0,
        );
      }
    }
  }
  if (coldAdmission) {
    final sqlite = File(p.join(root.path, 'support', kSqliteFileName));
    final existing = raw.sqlite3.open(sqlite.path, mode: raw.OpenMode.readOnly);
    try {
      _require(
        existing.select('PRAGMA user_version').single.values.single == 10 &&
            existing.select('PRAGMA integrity_check').single.values.single ==
                'ok' &&
            existing.select('PRAGMA foreign_key_check').isEmpty,
      );
      final tables = existing
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'] as String)
          .toList();
      _require(tables.length == 32);
      for (final entry in {
        'jobs': 2,
        'company_jobs': 2,
        'company_job_peer_acks': 2,
        'company_job_names': 0,
        'company_job_name_peer_acks': 0,
        'company_job_details': 0,
        'company_job_detail_peer_acks': 0,
      }.entries) {
        _require(
          tables.contains(entry.key) &&
              existing
                      .select('SELECT count(*) AS n FROM "${entry.key}"')
                      .single['n'] ==
                  entry.value,
        );
      }
      _require(
        _hash({
              for (final table in tables)
                table:
                    existing
                        .select('SELECT * FROM "$table"')
                        .map((r) => _canonical(Map<String, Object?>.from(r)))
                        .toList()
                      ..sort(),
            }) ==
            evidence['sqlSha256'],
      );
      final binding =
          existing.select('SELECT value FROM app_settings WHERE key = ?', [
                kInstallationBindingKey,
              ]).single['value']
              as String;
      _require(
        sha256.convert(utf8.encode(binding)).toString() ==
            evidence['bindingSha256'],
      );
    } finally {
      existing.dispose();
    }
  }
  return value;
}

Future<Map<String, Object?>> verifyDetailsBaselineNativeHeaders({
  required ProtectedInstallationState? base,
  required ProtectedInstallationState? custody,
  required String binding,
  required String databasePath,
  required Map<String, Object?> originalIdentity,
  required String originalReceipt,
  required Set<String> incomingOperations,
}) => _verifyDetailsNativeHeaders(
  base: base,
  custody: custody,
  binding: binding,
  databasePath: databasePath,
  originalIdentity: originalIdentity,
  originalReceipt: originalReceipt,
  incomingOperations: incomingOperations,
);

Future<Map<String, Object?>> verifyDetailsPendingNativeHeaders({
  required AppDatabase db,
  required ProtectedInstallationState? base,
  required ProtectedInstallationState? custody,
  required String binding,
  required String databasePath,
  required Map<String, Object?> originalIdentity,
  required String originalReceipt,
  required Set<String> incomingOperations,
}) async {
  final detail = (await db.select(db.companyJobDetails).get()).single;
  _require(detail.outgoing && base != null);
  final native = jsonDecode(utf8.decode(base!.bytes)) as Map;
  if (native['pendingCommand'] != null) {
    final intent = CompanyCommandIntent.decode(native['pendingCommand']);
    _require(
      intent.family == CompanyCommandFamily.jobDetails &&
          intent.companyId == detail.companyId &&
          intent.lineId == detail.jobId &&
          intent.receiptKey == detail.receiptKey &&
          intent.commandCommitment == detail.commandCommitment &&
          intent.operationCommitment == detail.operationCommitment &&
          intent.originGeneration == detail.originGeneration &&
          intent.requestId == detail.requestId &&
          intent.beforeWitness != null &&
          intent.afterWitness != null,
    );
    await validateJobDetailsCommit(db, intent);
  }
  return _verifyDetailsNativeHeaders(
    base: base,
    custody: custody,
    binding: binding,
    databasePath: databasePath,
    originalIdentity: originalIdentity,
    originalReceipt: originalReceipt,
    incomingOperations: incomingOperations,
    pendingDetail: detail,
  );
}

Future<Map<String, Object?>> _verifyDetailsNativeHeaders({
  required ProtectedInstallationState? base,
  required ProtectedInstallationState? custody,
  required String binding,
  required String databasePath,
  required Map<String, Object?> originalIdentity,
  required String originalReceipt,
  required Set<String> incomingOperations,
  CompanyJobDetail? pendingDetail,
}) async {
  _require(
    base != null &&
        custody != null &&
        base.bytes.length <= kInstallationStateLimit &&
        custody.bytes.length <= kInstallationStateLimit,
  );
  final publicBinding = _recoveryObject(jsonDecode(binding), {
    'v',
    'id',
    'generation',
    'key',
    'public',
    'store',
    'storePath',
  });
  final native = _recoveryObject(jsonDecode(utf8.decode(base!.bytes)), {
    'v',
    'id',
    'generation',
    'key',
    'public',
    'seed',
    'activation',
    'store',
    'floors',
    'previousStore',
    'companyTrust',
    'pendingCommand',
    'storePath',
  });
  final company = jsonDecode(utf8.decode(custody!.bytes)) as Map;
  _require(
    native['v'] == 2 &&
        native['activation'] == 'active' &&
        native['previousStore'] == null &&
        publicBinding['v'] == 1 &&
        company['status'] == 'active',
  );
  for (final key in [
    'id',
    'generation',
    'key',
    'public',
    'store',
    'storePath',
  ]) {
    _require(native[key] == publicBinding[key]);
  }
  final public = base64Decode(native['public'] as String);
  _require(
    public.length == 32 &&
        native['id'] == originalIdentity['installation'] &&
        native['generation'] == originalIdentity['generation'] &&
        native['store'] == originalIdentity['storeGeneration'] &&
        sha256.convert(public).toString() ==
            originalIdentity['publicKeySha256'],
  );
  final resolved = File(databasePath).resolveSymbolicLinksSync();
  _require(
    native['storePath'] ==
        sha256
            .convert(
              utf8.encode(
                p.normalize(
                  Platform.isWindows ? resolved.toLowerCase() : resolved,
                ),
              ),
            )
            .toString(),
  );
  for (final entry in {
    'installation': 'installation',
    'generation': 'generation',
    'store': 'storeGeneration',
    'company': 'company',
    'shop': 'shop',
    'user': 'user',
    'device': 'device',
  }.entries) {
    _require(company[entry.key] == originalIdentity[entry.value]);
  }
  final pending = native['pendingCommand'];
  if (pending != null) {
    final intent = CompanyCommandIntent.decode(pending);
    _require(
      (pendingDetail == null
              ? intent.family == CompanyCommandFamily.jobCreateIncoming &&
                    incomingOperations.contains(intent.operationCommitment)
              : intent.family == CompanyCommandFamily.jobDetails &&
                    intent.operationCommitment ==
                        pendingDetail.operationCommitment) &&
          intent.companyId == originalIdentity['company'] &&
          intent.storeGeneration == originalIdentity['storeGeneration'],
    );
  }
  await JobLineCommandReceipt.verifyAdmissionSeal(
    originalReceipt,
    InstallationIdentity(
      InstallationId(native['id'] as String),
      InstallationGeneration(native['generation'] as String),
      native['key'] as String,
      Uint8List.fromList(public),
    ),
    native['store'] as String,
    expectedFamily: CompanyCommandFamily.jobCreate,
  );
  if (pendingDetail != null) {
    await verifyJobDetailsReceipt(
      pendingDetail.receiptBytes,
      InstallationIdentity(
        InstallationId(native['id'] as String),
        InstallationGeneration(native['generation'] as String),
        native['key'] as String,
        Uint8List.fromList(public),
      ),
      native['store'] as String,
      CompanyCommandFamily.jobDetails,
    );
  }
  return {
    'baseProtectedRevision': base.revision,
    'baseProtectedSha256': sha256.convert(base.bytes).toString(),
    'custodyProtectedRevision': custody.revision,
    'custodyProtectedSha256': sha256.convert(custody.bytes).toString(),
    'pendingIncomingCreation': pendingDetail == null && pending != null,
    if (pendingDetail != null) 'pendingLocalDetails': pending != null,
    'hashesAreIndependentAnchor': false,
  };
}

Future<String> detailsNativeSqlHash(AppDatabase db) async => _hash({
  for (final table in db.allTables)
    table.actualTableName:
        (await db
                .customSelect('SELECT * FROM "${table.actualTableName}"')
                .get())
            .map((row) => _canonical(row.data))
            .toList()
          ..sort(),
});

Future<void> verifyDetailsBaselineRecoveryRecords({
  required CompanyEnrollment enrollment,
  required OwnerSession owner,
  required String sqlSha256,
  required Map<String, dynamic> localCreation,
}) async {
  final db = enrollment.db;
  _require(await detailsNativeSqlHash(db) == sqlSha256);
  final commands = CompanyJobCommands(enrollment: enrollment);
  final creates = await commands.syncHoldings(ownerSession: owner);
  _require(
    creates.length == 2 &&
        (await commands.nameSyncHoldings(ownerSession: owner)).isEmpty &&
        (await commands.detailsSyncHoldings(ownerSession: owner)).isEmpty,
  );
  final original = localCreation['record'] as Map;
  _require(
    creates
            .where((r) => _canonical(r.toJson()) == _canonical(original))
            .length ==
        1,
  );
  _require(
    (await db.select(db.companyJobPeerAcks).get()).length == 2 &&
        (await db.select(db.companyJobNamePeerAcks).get()).isEmpty &&
        (await db.select(db.companyJobDetailPeerAcks).get()).isEmpty,
  );
  final confirmed = await CompanyCreatedJobSync.confirmedPeerCounts(
    enrollment,
    owner,
  );
  _require(confirmed.length == 2 && confirmed.values.every((n) => n == 1));
  _require(await detailsNativeSqlHash(db) == sqlSha256);
}

Future<void> verifyDetailsPendingRecoveryRecords({
  required CompanyEnrollment enrollment,
  required OwnerSession owner,
  required String sqlSha256,
  required Map<String, dynamic> localCreation,
  required Map<String, dynamic> savedDetail,
  required String role,
}) async {
  _require({'owner', 'member'}.contains(role));
  final db = enrollment.db;
  _require(await detailsNativeSqlHash(db) == sqlSha256);
  final commands = CompanyJobCommands(enrollment: enrollment);
  final creates = await commands.syncHoldings(ownerSession: owner);
  _require(
    creates.length == 2 &&
        creates
                .where(
                  (r) =>
                      _canonical(r.toJson()) ==
                      _canonical(localCreation['record']),
                )
                .length ==
            1 &&
        (await commands.nameSyncHoldings(ownerSession: owner)).isEmpty,
  );
  final confirmed = await CompanyCreatedJobSync.confirmedPeerCounts(
    enrollment,
    owner,
  );
  final jobs = creates.map((r) => r.jobId).toList()..sort();
  final createAcks = await db.select(db.companyJobPeerAcks).get();
  _require(
    createAcks.length == 2 &&
        creates.every(
          (create) =>
              createAcks
                  .where(
                    (ack) =>
                        ack.companyId == create.companyId &&
                        ack.originGeneration == create.originGeneration &&
                        ack.requestId == create.requestId &&
                        ack.operationDigest ==
                            sha256
                                .convert(utf8.encode(create.operationBytes))
                                .toString(),
                  )
                  .length ==
              1,
        ) &&
        createAcks.map((ack) => ack.peerDeviceId).toSet().length == 1 &&
        confirmed.length == 2 &&
        confirmed[jobs.first] == 0 &&
        confirmed[jobs.last] == 1 &&
        (await db.select(db.companyJobNamePeerAcks).get()).isEmpty &&
        (await db.select(db.companyJobDetailPeerAcks).get()).isEmpty,
  );
  final detail = (await commands.detailsSyncHoldings(ownerSession: owner))
      .single;
  _require(
    detail.outgoing && _canonical(detail.toJson()) == _canonical(savedDetail),
  );
  final body = (jsonDecode(detail.operationBytes) as Map)['body'] as Map;
  final units = body['units'] as Map;
  final expected = role == 'owner'
      ? {'customer': 'Acme', 'status': 'archived'}
      : {'notes': 'Gate 3'};
  _require(
    detail.jobId == jobs.first &&
        body['user'] == owner.identity.userId &&
        body['device'] == owner.identity.deviceId &&
        _canonical(body['resolve']) == '[]' &&
        units.length == expected.length &&
        units.keys.toSet().containsAll(expected.keys),
  );
  for (final entry in expected.entries) {
    final unit = units[entry.key] as Map;
    _require(
      unit['value'] == entry.value && _canonical(unit['parents']) == '[]',
    );
  }
  _require(await detailsNativeSqlHash(db) == sqlSha256);
}

Map<String, dynamic> _detailsBaselineOriginRecord(
  Map<String, dynamic> recovery,
  String key,
) {
  final relative = (recovery['originalFiles'] as Map)[key] as String;
  final entry = (recovery['files'] as List).cast<Map>().singleWhere(
    (item) => item['path'] == relative,
  );
  return _readOwnedJson(
    File(p.join(recovery['root'] as String, relative)),
    expectedBytes: entry['bytes'] as int,
    expectedSha256: entry['sha256'] as String,
  );
}

void verifyDetailsPendingInventory(Directory directory, List<dynamic> files) {
  _require(
    files.isNotEmpty &&
        files.length <= 256 &&
        directory.resolveSymbolicLinksSync() == directory.path,
  );
  for (final name in [
    'support',
    'documents',
    'temporary',
    'cache',
    'library',
    'downloads',
    'receipts',
  ]) {
    _require(
      FileSystemEntity.typeSync(
            p.join(directory.path, name),
            followLinks: false,
          ) ==
          FileSystemEntityType.directory,
    );
  }
  for (final name in [
    kRestoreSwapMarkerName,
    kSqliteRestoreBakName,
    kPhotosRestoreBakName,
    kRestoreStagingName,
    kRestoreStagingNextName,
  ]) {
    _require(
      FileSystemEntity.typeSync(
            p.join(directory.path, 'support', name),
            followLinks: false,
          ) ==
          FileSystemEntityType.notFound,
    );
  }
  final expected = <String, Map<String, dynamic>>{};
  var total = 0;
  for (final raw in files) {
    final entry = _recoveryObject(raw, {'path', 'bytes', 'sha256'});
    final relative = _recoveryRelative(entry['path']);
    _require(
      !expected.containsKey(relative) &&
          entry['bytes'] is int &&
          (entry['bytes'] as int) >= 0 &&
          (entry['bytes'] as int) <= 64 * 1024 * 1024 &&
          entry['sha256'] is String &&
          _sha256Pattern.hasMatch(entry['sha256'] as String),
    );
    total += entry['bytes'] as int;
    expected[relative] = entry;
  }
  _require(
    total <= 256 * 1024 * 1024 &&
        expected.containsKey('support/$kSqliteFileName'),
  );
  final seen = <String>{};
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    _require(
      type == FileSystemEntityType.directory ||
          type == FileSystemEntityType.file,
    );
    if (type != FileSystemEntityType.file) continue;
    final relative = p
        .relative(entity.path, from: directory.path)
        .replaceAll('\\', '/');
    final entry = expected[relative];
    _require(entry != null && seen.add(relative));
    final file = File(entity.path);
    _require(
      file.lengthSync() == entry!['bytes'] &&
          sha256.convert(file.readAsBytesSync()).toString() == entry['sha256'],
    );
  }
  _require(seen.length == expected.length);
}

Map<String, dynamic> _readDetailsPendingRecovery(
  Directory root, {
  required String path,
  required String digest,
  required String role,
  required String revision,
  required String tree,
  required String adapter,
  required String productRevision,
  required String sourceManifestPath,
  required String sourceManifestSha256,
  required String baselineRecoverySha256,
  required bool coldAdmission,
}) {
  _require(
    p.isAbsolute(path) &&
        p.normalize(path) == path &&
        !p.isWithin(root.path, path) &&
        path != root.path &&
        File(path).resolveSymbolicLinksSync() == path &&
        _sha256Pattern.hasMatch(digest),
  );
  final value = _readOwnedJson(File(path), expectedSha256: digest);
  _recoveryObject(value, {
    'format',
    'kind',
    'run',
    'role',
    'root',
    'namespace',
    'creationOrigin',
    'savedOrigin',
    'recovery',
    'savedManifestPath',
    'baselineRecoverySha256',
    'coldArchive',
    'files',
    'savedFile',
    'evidence',
    'retiredEpoch',
  });
  _require(
    value['format'] == 1 &&
        value['kind'] == 'j116.interrupted-pending-details.recovery@1' &&
        value['run'] == jobDetailsNativeRun &&
        value['role'] == role &&
        value['root'] == root.path &&
        root.resolveSymbolicLinksSync() == root.path &&
        value['namespace'] ==
            joinNativeNamespace(
              jobDetailsNativeRun,
              role,
              createdMode: true,
              detailsMode: true,
            ) &&
        value['baselineRecoverySha256'] == baselineRecoverySha256 &&
        _sha256Pattern.hasMatch(baselineRecoverySha256),
  );
  validateDetailsBaselineRecoveryOrigin(
    _recoveryObject(
      value['creationOrigin'],
      _detailsBaselineOrigin.keys.toSet(),
    ),
  );
  _require(
    _canonical(
          _recoveryObject(
            value['savedOrigin'],
            _detailsSavedOrigin.keys.toSet(),
          ),
        ) ==
        _canonical(_detailsSavedOrigin),
  );
  _require(
    _canonical(
          _recoveryObject(value['recovery'], _detailsSavedOrigin.keys.toSet()),
        ) ==
        _canonical({
          'revision': revision,
          'tree': tree,
          'adapterSha256': adapter,
          'productRevision': productRevision,
          'manifestSha256': sourceManifestSha256,
        }),
  );
  final savedManifest = File(value['savedManifestPath'] as String);
  validateJobDetailsNativeSourceManifest(
    manifest: savedManifest,
    manifestSha256: _detailsSavedOrigin['manifestSha256']!,
    revision: _detailsSavedOrigin['revision']!,
    tree: _detailsSavedOrigin['tree']!,
    adapter: _detailsSavedOrigin['adapterSha256']!,
    productRevision: _detailsSavedOrigin['productRevision']!,
  );
  validateJobDetailsNativeSourceManifest(
    manifest: File(sourceManifestPath),
    manifestSha256: sourceManifestSha256,
    revision: revision,
    tree: tree,
    adapter: adapter,
    productRevision: productRevision,
  );
  final savedHashes =
      (_readOwnedJson(
            savedManifest,
            expectedSha256: _detailsSavedOrigin['manifestSha256'],
          )['sourceLfSha256']
          as Map);
  final nextHashes =
      (_readOwnedJson(
            File(sourceManifestPath),
            expectedSha256: sourceManifestSha256,
          )['sourceLfSha256']
          as Map);
  _require(
    savedHashes.length == 95 &&
        nextHashes.length == 95 &&
        savedHashes.keys.toSet().containsAll(nextHashes.keys),
  );
  for (final key in savedHashes.keys) {
    if (key != 'app/integration_test/company_join_native_test.dart') {
      _require(savedHashes[key] == nextHashes[key]);
    }
  }
  _require(
    value['retiredEpoch'] is String &&
        (value['retiredEpoch'] as String).isNotEmpty &&
        (value['retiredEpoch'] as String).length <= 128,
  );
  final evidence = _recoveryObject(value['evidence'], {
    'identity',
    'sqlSha256',
    'bindingSha256',
    'companyJobCount',
    'createAckCount',
    'nameCount',
    'detailsCount',
    'nameAckCount',
    'detailsAckCount',
  });
  _recoveryIdentity(evidence['identity']);
  _require(
    evidence['companyJobCount'] == 2 &&
        evidence['createAckCount'] == 2 &&
        evidence['nameCount'] == 0 &&
        evidence['detailsCount'] == 1 &&
        evidence['nameAckCount'] == 0 &&
        evidence['detailsAckCount'] == 0 &&
        ['sqlSha256', 'bindingSha256'].every(
          (key) =>
              evidence[key] is String &&
              _sha256Pattern.hasMatch(evidence[key] as String),
        ),
  );
  final archive = value['coldArchive'] as String;
  _require(
    p.isAbsolute(archive) &&
        p.normalize(archive) == archive &&
        archive != root.path &&
        !p.isWithin(root.path, archive) &&
        !p.isWithin(archive, root.path),
  );
  final files = value['files'] as List;
  verifyDetailsPendingInventory(Directory(archive), files);
  if (coldAdmission) verifyDetailsPendingInventory(root, files);
  final savedName = 'details-ui-${role == 'owner' ? 29804 : 21403}-1.json';
  _require(value['savedFile'] == savedName);
  final member = files.cast<Map>().singleWhere((f) => f['path'] == savedName);
  _require(
    member['sha256'] ==
        (role == 'owner'
            ? 'f4d3e91634535ca5059f2fb69ef202e6982178ad868269a12b9125c3aa843b91'
            : 'e13f6b77899035b1475bdfb621cec94e35919ec7838d5b33a0d42cec7b7c6cd1'),
  );
  final saved = _readOwnedJson(
    File(p.join(root.path, savedName)),
    expectedBytes: member['bytes'] as int,
    expectedSha256: member['sha256'] as String,
  );
  verifyJoinNativeEvidenceProvenance(
    saved,
    revision: _detailsSavedOrigin['revision']!,
    tree: _detailsSavedOrigin['tree']!,
    adapter: _detailsSavedOrigin['adapterSha256']!,
    productRevision: _detailsSavedOrigin['productRevision']!,
  );
  _require(
    saved['format'] == 1 &&
        saved['run'] == jobDetailsNativeRun &&
        saved['role'] == role &&
        saved['root'] == root.path &&
        saved['pid'] == (role == 'owner' ? 29804 : 21403) &&
        saved['namespace'] == value['namespace'] &&
        saved['jobDetailsMode'] == true &&
        saved['mode'] == 'created-jobs' &&
        saved['platform'] == (role == 'owner' ? 'windows' : 'macos') &&
        saved['detailsManifestSha256'] ==
            _detailsSavedOrigin['manifestSha256'] &&
        saved['detailsBaselineRecoverySha256'] == baselineRecoverySha256 &&
        saved['step'] == 'editMixedOffline' &&
        saved['savedThroughProductionUi'] == true &&
        saved['passed'] == false &&
        saved['locked'] == false &&
        saved['productionJobsPanelRendered'] == true &&
        saved['companyControllerStoppedDuringUi'] == true &&
        saved['schema'] == 10 &&
        saved['integrityValid'] == true &&
        saved['referencesValid'] == true &&
        saved['originalLocalRecordUnchanged'] == true &&
        _canonical(saved['identity']) == _canonical(evidence['identity']) &&
        saved['sqlSha256'] == evidence['sqlSha256'] &&
        saved['receiptCountVerified'] == 2 &&
        saved['ackCount'] == 2 &&
        saved['nameOperationCount'] == 0 &&
        saved['nameReceiptCountVerified'] == 0 &&
        saved['nameAckCount'] == 0 &&
        saved['detailsOperationCount'] == 1 &&
        saved['detailsReceiptCountVerified'] == 1 &&
        saved['detailsAckCount'] == 0 &&
        [
          'receiptVerification',
          'nameReceiptVerification',
          'detailsReceiptVerification',
        ].every((key) => saved[key] == 'typed-public-verifier') &&
        saved['ackVerification'] == 'confirmedPeerCounts' &&
        saved['detailsTerminals'] is List &&
        (saved['detailsTerminals'] as List).isEmpty,
  );
  if (coldAdmission) {
    final db = raw.sqlite3.open(
      p.join(root.path, 'support', kSqliteFileName),
      mode: raw.OpenMode.readOnly,
    );
    try {
      _require(
        db.select('PRAGMA user_version').single.values.single == 10 &&
            db.select('PRAGMA integrity_check').single.values.single == 'ok' &&
            db.select('PRAGMA foreign_key_check').isEmpty,
      );
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'] as String)
          .toList();
      _require(tables.length == 32);
      for (final entry in {
        'jobs': 2,
        'company_jobs': 2,
        'company_job_peer_acks': 2,
        'company_job_names': 0,
        'company_job_name_peer_acks': 0,
        'company_job_details': 1,
        'company_job_detail_peer_acks': 0,
      }.entries) {
        _require(
          db.select('SELECT count(*) AS n FROM "${entry.key}"').single['n'] ==
              entry.value,
        );
      }
      _require(
        _hash({
              for (final table in tables)
                table:
                    db
                        .select('SELECT * FROM "$table"')
                        .map((r) => _canonical(Map<String, Object?>.from(r)))
                        .toList()
                      ..sort(),
            }) ==
            evidence['sqlSha256'],
      );
      final binding =
          db.select('SELECT value FROM app_settings WHERE key = ?', [
                kInstallationBindingKey,
              ]).single['value']
              as String;
      _require(
        sha256.convert(utf8.encode(binding)).toString() ==
            evidence['bindingSha256'],
      );
    } finally {
      db.dispose();
    }
  }
  return {...value, 'savedEvidence': saved};
}

JoinNativeRootAdmission validateJobDetailsNativeRootAdmission(
  Directory root, {
  required String run,
  required String role,
  required String revision,
  required String tree,
  required String adapter,
  required String productRevision,
  required String manifestSha256,
  String checkpointPath = '',
  String checkpointSha256 = '',
  String baselineRecoveryPath = '',
  String baselineRecoverySha256 = '',
  String pendingRecoveryPath = '',
  String pendingRecoverySha256 = '',
  String sourceManifestPath = '',
  Directory? temporaryDirectory,
}) {
  _require(run == jobDetailsNativeRun && {'owner', 'member'}.contains(role));
  final temp = (temporaryDirectory ?? Directory.systemTemp)
      .resolveSymbolicLinksSync();
  _require(
    root.path ==
        p.join(
          temp,
          'wired-parts-lan-company-$run-${role == 'owner' ? 'sender' : 'receiver'}',
        ),
  );
  final type = FileSystemEntity.typeSync(root.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    _require(
      checkpointPath.isEmpty &&
          checkpointSha256.isEmpty &&
          baselineRecoveryPath.isEmpty &&
          baselineRecoverySha256.isEmpty &&
          pendingRecoveryPath.isEmpty &&
          pendingRecoverySha256.isEmpty,
    );
    return const JoinNativeRootAdmission(JoinNativeRootStage.fresh);
  }
  Map<String, dynamic>? baselineRecovery;
  Map<String, dynamic>? pendingRecovery;
  if (pendingRecoveryPath.isNotEmpty || pendingRecoverySha256.isNotEmpty) {
    _require(
      baselineRecoveryPath.isNotEmpty &&
          _sha256Pattern.hasMatch(baselineRecoverySha256),
    );
    pendingRecovery = _readDetailsPendingRecovery(
      root,
      path: pendingRecoveryPath,
      digest: pendingRecoverySha256,
      role: role,
      revision: revision,
      tree: tree,
      adapter: adapter,
      productRevision: productRevision,
      sourceManifestPath: sourceManifestPath,
      sourceManifestSha256: manifestSha256,
      baselineRecoverySha256: baselineRecoverySha256,
      coldAdmission: checkpointPath.isEmpty,
    );
  }
  if (baselineRecoveryPath.isNotEmpty || baselineRecoverySha256.isNotEmpty) {
    baselineRecovery = _readDetailsBaselineRecovery(
      root,
      path: baselineRecoveryPath,
      digest: baselineRecoverySha256,
      role: role,
      revision: pendingRecovery == null
          ? revision
          : _detailsSavedOrigin['revision']!,
      tree: pendingRecovery == null ? tree : _detailsSavedOrigin['tree']!,
      adapter: pendingRecovery == null
          ? adapter
          : _detailsSavedOrigin['adapterSha256']!,
      productRevision: pendingRecovery == null
          ? productRevision
          : _detailsSavedOrigin['productRevision']!,
      sourceManifestPath: pendingRecovery == null
          ? sourceManifestPath
          : pendingRecovery['savedManifestPath'] as String,
      sourceManifestSha256: pendingRecovery == null
          ? manifestSha256
          : _detailsSavedOrigin['manifestSha256']!,
      coldAdmission: checkpointPath.isEmpty && pendingRecovery == null,
    );
    if (pendingRecovery != null) {
      final shared = verifyDetailsBaselineInspection(root, baselineRecovery);
      final saved = pendingRecovery['savedEvidence'] as Map;
      _require(
        _canonical((baselineRecovery['evidence'] as Map)['identity']) ==
                _canonical((pendingRecovery['evidence'] as Map)['identity']) &&
            saved['selectedJob'] == shared['selectedJob'] &&
            saved['jobHistorySha256'] == shared['creationHistorySha256'] &&
            saved['nameRecordsSha256'] == shared['nameRecordsSha256'],
      );
    }
    if (checkpointPath.isEmpty) {
      _require(checkpointSha256.isEmpty);
      return JoinNativeRootAdmission(
        pendingRecovery == null
            ? JoinNativeRootStage.interruptedDetailsBaseline
            : JoinNativeRootStage.interruptedDetailsPending,
        detailsBaselineRecovery: baselineRecovery,
        detailsPendingRecovery: pendingRecovery,
      );
    }
  }
  _require(
    type == FileSystemEntityType.directory &&
        checkpointPath.isNotEmpty &&
        _sha256Pattern.hasMatch(checkpointSha256),
  );
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    _require(
      FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.link,
    );
  }
  _require(
    p.dirname(checkpointPath) == root.path &&
        RegExp(r'^join-details-checkpoint-\d+-\d+\.json$')
            .hasMatch(p.basename(checkpointPath)),
  );
  final checkpoint = _readOwnedJson(
    File(checkpointPath),
    expectedSha256: checkpointSha256,
  );
  _require(
    baselineRecovery == null
        ? checkpoint['detailsBaselineRecoverySha256'] == null
        : checkpoint['detailsBaselineRecoverySha256'] == baselineRecoverySha256,
  );
  _require(
    pendingRecovery == null
        ? checkpoint['detailsPendingRecoverySha256'] == null
        : checkpoint['detailsPendingRecoverySha256'] == pendingRecoverySha256,
  );
  _require(
    checkpoint['format'] == 1 &&
        checkpoint['run'] == run &&
        checkpoint['role'] == role &&
        checkpoint['root'] == root.path &&
        checkpoint['namespace'] ==
            joinNativeNamespace(
              run,
              role,
              createdMode: true,
              detailsMode: true,
            ) &&
        checkpoint['sourceRevision'] == revision &&
        checkpoint['sourceTree'] == tree &&
        checkpoint['adapterSha256'] == adapter &&
        checkpoint['productRevision'] == productRevision &&
        checkpoint['detailsManifestSha256'] == manifestSha256 &&
        checkpoint['jobDetailsMode'] == true &&
        checkpoint['schema'] == 10 &&
        checkpoint['locked'] == true &&
        checkpoint['nearbyControllerRunning'] == false &&
        checkpoint['passed'] == false &&
        {'mixed', 'conflict', 'resolved'}.contains(checkpoint['detailsStage']),
  );
  _recoveryIdentity(checkpoint['identity']);
  _require(
    checkpoint['lockedSqlSha256'] is String &&
        _sha256Pattern.hasMatch(checkpoint['lockedSqlSha256'] as String),
  );
  final evidence = checkpoint['detailsEvidence'];
  _require(evidence is Map<String, dynamic>);
  final expectedCount = switch (checkpoint['detailsStage']) {
    'mixed' => 2,
    'conflict' => 4,
    'resolved' => 5,
    _ => 0,
  };
  _require(
    (evidence as Map)['detailsOperationCount'] == expectedCount &&
        evidence['detailsReceiptCountVerified'] == expectedCount &&
        evidence['detailsAckCount'] == expectedCount &&
        evidence['detailsReceiptVerification'] == 'typed-public-verifier' &&
        evidence['ackVerification'] == 'confirmedPeerCounts',
  );
  final sqlite = File(p.join(root.path, 'support', kSqliteFileName));
  _require(
    FileSystemEntity.typeSync(sqlite.path, followLinks: false) ==
        FileSystemEntityType.file,
  );
  final existing = raw.sqlite3.open(sqlite.path, mode: raw.OpenMode.readOnly);
  try {
    _require(existing.select('PRAGMA user_version').single.values.single == 10);
    final tables = existing
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toList();
    _require(
      tables.length == 32 &&
          tables.contains('company_job_details') &&
          tables.contains('company_job_detail_peer_acks'),
    );
    _require(
      _hash({
            for (final table in tables)
              table:
                  existing
                      .select('SELECT * FROM "$table"')
                      .map((row) => _canonical(Map<String, Object?>.from(row)))
                      .toList()
                    ..sort(),
          }) ==
          checkpoint['lockedSqlSha256'],
    );
  } finally {
    existing.dispose();
  }
  return JoinNativeRootAdmission(
    JoinNativeRootStage.detailsCheckpoint,
    detailsCheckpoint: checkpoint,
    detailsBaselineRecovery: baselineRecovery,
    detailsPendingRecovery: pendingRecovery,
  );
}

void verifyJobDetailsNativeReadback(
  Map<String, dynamic> checkpoint,
  Map<String, Object?> actual,
) {
  final expected = (checkpoint['detailsEvidence'] as Map)
      .cast<String, Object?>();
  for (final key in [
    'identity',
    'counts',
    'schema',
    'jobHistorySha256',
    'receiptSha256',
    'ackCount',
    'ackSha256',
    'nameOperationCount',
    'nameReceiptCountVerified',
    'nameRecordsSha256',
    'nameAckCount',
    'nameAckSha256',
    'nameViews',
    'detailsOperationCount',
    'detailsReceiptCountVerified',
    'detailsRecordsSha256',
    'detailsAckCount',
    'detailsAckSha256',
    'detailsViews',
    'confirmedPeerCounts',
  ]) {
    _require(
      expected.containsKey(key) &&
          actual.containsKey(key) &&
          _canonical(expected[key]) == _canonical(actual[key]),
    );
  }
  _require(
    actual['detailsReceiptVerification'] == 'typed-public-verifier' &&
        actual['nameReceiptVerification'] == 'typed-public-verifier' &&
        actual['receiptVerification'] == 'typed-public-verifier' &&
        actual['ackVerification'] == 'confirmedPeerCounts',
  );
}

void validateJobDetailsNativeMixedRepeat(List<Map<String, Object?>> terminals) {
  _require(terminals.length >= 2);
  final first = terminals[terminals.length - 2], repeat = terminals.last;
  _require(
    first['complete'] == true &&
        first['sent'] == 1 &&
        first['received'] == 1 &&
        repeat['complete'] == true &&
        repeat['sent'] == 0 &&
        repeat['received'] == 0 &&
        first['pageEpoch'] == repeat['pageEpoch'],
  );
  final start = first['elapsedMillis'], end = repeat['elapsedMillis'];
  _require(start is int && end is int && end >= start && end - start <= 300000);
}

void _recoveryIdentity(Object? value) {
  final identity = _recoveryObject(value, {
    'installation',
    'generation',
    'publicKeySha256',
    'storeGeneration',
    'company',
    'shop',
    'user',
    'device',
  });
  _require(
    identity.values.every((v) => v is String && v.isNotEmpty && v.length <= 64),
  );
  _require(_sha256Pattern.hasMatch(identity['publicKeySha256'] as String));
}

String _recoveryRelative(Object? value) {
  _require(
    value is String &&
        value.isNotEmpty &&
        value.length <= 256 &&
        !value.contains('\\') &&
        !value.contains(':') &&
        !p.posix.isAbsolute(value) &&
        value.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..'),
  );
  return value as String;
}

Map<String, dynamic> _readInterruptedManifest(
  Directory root,
  String path,
  String digest, {
  required String run,
  required String role,
  required String revision,
  required String tree,
  required String adapter,
  required String productRevision,
}) {
  _require(
    _sha256Pattern.hasMatch(digest) &&
        p.isAbsolute(path) &&
        p.normalize(path) == path &&
        !p.isWithin(root.path, path) &&
        path != root.path,
  );
  final file = File(path);
  _require(file.resolveSymbolicLinksSync() == path);
  final value = _readOwnedJson(file, expectedSha256: digest);
  _recoveryObject(value, {
    'format',
    'kind',
    'run',
    'role',
    'root',
    'namespace',
    'origin',
    'recovery',
    'productFiles',
    'files',
    'originFiles',
    'evidence',
  });
  _require(
    value['format'] == 1 &&
        value['kind'] == 'j61.interrupted-names.recovery@1' &&
        run == createdJobNativeRun &&
        value['run'] == run &&
        value['role'] == role &&
        value['root'] == root.path &&
        root.resolveSymbolicLinksSync() == root.path &&
        value['namespace'] == joinNativeNamespace(run, role, createdMode: true),
  );
  final origin = _recoveryObject(value['origin'], {
    'revision',
    'tree',
    'adapterSha256',
    'productRevision',
  });
  _require(
    origin['revision'] == '079baa5b7982a2c1fef1b7b165773cfa73dc5e83' &&
        origin['tree'] == 'dd529f9b145c15d52fb46a1e0548f3c234580870' &&
        origin['adapterSha256'] ==
            'c7cd5a3438685b81d0d44f90e03e2bd50c52a6c44947d4b75334d0bf42b896d1' &&
        origin['productRevision'] == origin['revision'],
  );
  final recovery = _recoveryObject(value['recovery'], {
    'revision',
    'tree',
    'adapterSha256',
    'productRevision',
  });
  _require(
    recovery['revision'] == revision &&
        recovery['tree'] == tree &&
        recovery['adapterSha256'] == adapter &&
        recovery['productRevision'] == productRevision &&
        productRevision == revision,
  );
  final products = value['productFiles'];
  _require(products is List && products.length == 20);
  final seen = <String>{};
  for (final raw in products as List) {
    final product = _recoveryObject(raw, {
      'path',
      'originLfSha256',
      'recoveryLfSha256',
    });
    final path = product['path'];
    _require(
      path is String &&
          seen.add(path) &&
          joinNativeInterruptedProductHashes[path] != null &&
          product['originLfSha256'] ==
              joinNativeInterruptedProductHashes[path] &&
          product['recoveryLfSha256'] == product['originLfSha256'],
    );
  }
  final evidence = _recoveryObject(value['evidence'], {
    'identity',
    'peerIdentity',
    'selectedJob',
    'creationDigest',
    'jobHistorySha256',
    'nameOperationCount',
    'nameReceiptCountVerified',
    'nameAckCount',
    'nameRecordsSha256',
    'nameAckSha256',
    'nameViews',
    'sequentialOperation',
    'localOperation',
  });
  _recoveryIdentity(evidence['identity']);
  _recoveryIdentity(evidence['peerIdentity']);
  final identity = evidence['identity'] as Map;
  final peer = evidence['peerIdentity'] as Map;
  _require(
    identity['company'] == peer['company'] &&
        identity['shop'] == peer['shop'] &&
        identity['user'] == peer['user'] &&
        identity['installation'] != peer['installation'] &&
        identity['device'] != peer['device'] &&
        identity['storeGeneration'] != peer['storeGeneration'],
  );
  for (final key in [
    'creationDigest',
    'jobHistorySha256',
    'nameRecordsSha256',
    'nameAckSha256',
    'sequentialOperation',
    'localOperation',
  ]) {
    _require(
      evidence[key] is String &&
          _sha256Pattern.hasMatch(evidence[key] as String),
    );
  }
  _require(
    evidence['selectedJob'] is String &&
        (evidence['selectedJob'] as String).isNotEmpty &&
        evidence['sequentialOperation'] != evidence['localOperation'] &&
        evidence['nameOperationCount'] == 2 &&
        evidence['nameReceiptCountVerified'] == 2 &&
        evidence['nameAckCount'] == 1,
  );
  final files = value['files'];
  _require(files is List && files.isNotEmpty && files.length <= 256);
  final paths = <String>{};
  var bytes = 0;
  for (final raw in files as List) {
    final file = _recoveryObject(raw, {'path', 'bytes', 'sha256'});
    _require(
      paths.add(_recoveryRelative(file['path'])) &&
          file['bytes'] is int &&
          (file['bytes'] as int) >= 0 &&
          (file['bytes'] as int) <= 64 * 1024 * 1024 &&
          file['sha256'] is String &&
          _sha256Pattern.hasMatch(file['sha256'] as String),
    );
    bytes += file['bytes'] as int;
  }
  _require(
    bytes <= 256 * 1024 * 1024 &&
        paths.contains('validation-owner.json') &&
        paths.contains('support/wired_parts.sqlite') &&
        !paths.contains('join-exercise.json') &&
        !paths.contains('join-name-conflict.json'),
  );
  final origins = _recoveryObject(value['originFiles'], {
    'baseline',
    'nameUi',
    'priorSnapshot',
    'localCreation',
  });
  _require(
    origins.values.toSet().length == 4 &&
        origins['baseline'] == 'name-shared-baseline-$role.json' &&
        origins['localCreation'] == 'created-local-job.json',
  );
  final loaded = <String, Map<String, dynamic>>{};
  for (final entry in origins.entries) {
    final relative = _recoveryRelative(entry.value);
    _require(paths.contains(relative));
    final listed = (files).cast<Map>().singleWhere(
      (f) => f['path'] == relative,
    );
    final actual = _readOwnedJson(
      File(p.join(root.path, relative)),
      expectedSha256: listed['sha256'] as String,
      expectedBytes: listed['bytes'] as int,
    );
    _require(
      actual['format'] == 1 &&
          actual['run'] == run &&
          actual['role'] == role &&
          actual['root'] == root.path &&
          actual['namespace'] == value['namespace'] &&
          actual['sourceRevision'] == origin['revision'] &&
          actual['sourceTree'] == origin['tree'] &&
          actual['adapterSha256'] == origin['adapterSha256'] &&
          actual['productRevision'] == origin['productRevision'] &&
          actual['jobNameMode'] == true,
    );
    loaded[entry.key] = actual;
  }
  final baseline = loaded['baseline']!,
      ui = loaded['nameUi']!,
      prior = loaded['priorSnapshot']!;
  _require(
    baseline['selectedJob'] == evidence['selectedJob'] &&
        baseline['creationDigest'] == evidence['creationDigest'] &&
        baseline['creationHistorySha256'] == evidence['jobHistorySha256'] &&
        ui['step'] == 'renameConcurrent' &&
        ui['savedThroughProductionUi'] == true &&
        ui['companyControllerStoppedDuringUi'] == true &&
        ui['originalCreationBytesUnchanged'] == true &&
        ui['creationHistorySha256'] == evidence['jobHistorySha256'] &&
        _canonical(ui['observedHeadsBefore']) ==
            _canonical([evidence['sequentialOperation']]) &&
        prior['nameOperationCount'] == 1 &&
        prior['nameReceiptCountVerified'] == 1 &&
        prior['nameAckCount'] == 1 &&
        prior['ackVerification'] == 'confirmedPeerCounts' &&
        prior['nameReceiptVerification'] == 'typed-public-verifier' &&
        prior['nameAckSha256'] == evidence['nameAckSha256'] &&
        _canonical(prior['identity']) == _canonical(identity) &&
        _canonical(loaded['localCreation']!['identity']) ==
            _canonical(identity),
  );
  verifyJoinNativeInterruptedReadback(value, {
    ...ui,
    'identity': identity,
    'jobHistorySha256': ui['creationHistorySha256'],
    'ackVerification': prior['ackVerification'],
  });
  return value;
}

void verifyJoinNativeInterruptedFiles(
  Directory root,
  Map<String, dynamic> manifest,
) {
  final expected = {
    for (final raw in manifest['files'] as List)
      (raw as Map)['path'] as String: raw,
  };
  final seen = <String>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    _require(
      type == FileSystemEntityType.file ||
          type == FileSystemEntityType.directory,
    );
    if (type != FileSystemEntityType.file) continue;
    final relative = p
        .relative(entity.path, from: root.path)
        .replaceAll('\\', '/');
    final listed = expected[relative];
    _require(listed != null && seen.add(relative));
    final file = File(entity.path);
    _require(file.lengthSync() == listed!['bytes']);
    final bytes = file.readAsBytesSync();
    _require(
      bytes.length == listed['bytes'] &&
          sha256.convert(bytes).toString() == listed['sha256'],
    );
  }
  _require(seen.length == expected.length);
  final owner = _readOwnedJson(
    File(p.join(root.path, 'validation-owner.json')),
  );
  _require(
    owner['format'] == 1 &&
        owner['initialized'] == true &&
        owner['root'] == root.path &&
        owner['run'] == 'company-${manifest['run']}' &&
        owner['role'] == (manifest['role'] == 'owner' ? 'sender' : 'receiver'),
  );
}

void verifyJoinNativeInterruptedReadback(
  Map<String, dynamic> manifest,
  Map<String, Object?> actual,
) {
  final expected = manifest['evidence'] as Map;
  _require(
    actual['nameOperationCount'] == 2 &&
        actual['nameReceiptCountVerified'] == 2 &&
        actual['nameAckCount'] == 1 &&
        actual['nameReceiptVerification'] == 'typed-public-verifier' &&
        actual['ackVerification'] == 'confirmedPeerCounts',
  );
  for (final key in [
    'identity',
    'jobHistorySha256',
    'nameRecordsSha256',
    'nameAckSha256',
    'nameViews',
  ]) {
    _require(_canonical(actual[key]) == _canonical(expected[key]));
  }
  final records = (actual['nameRecords'] as List).cast<Map>();
  _require(records.length == 2);
  final sequential = records.singleWhere(
    (r) => r['operation'] == expected['sequentialOperation'],
  );
  final local = records.singleWhere(
    (r) => r['operation'] == expected['localOperation'],
  );
  final identity = expected['identity'] as Map;
  final owner = manifest['role'] == 'owner'
      ? identity
      : expected['peerIdentity'] as Map;
  for (final record in records) {
    _require(
      record['job'] == expected['selectedJob'] &&
          record['creationDigest'] == expected['creationDigest'],
    );
  }
  _require(
    _canonical(sequential['parents']) == '[]' &&
        _canonical(local['parents']) ==
            _canonical([expected['sequentialOperation']]) &&
        sequential['originalUser'] == owner['user'] &&
        sequential['originalDevice'] == owner['device'] &&
        local['originalUser'] == identity['user'] &&
        local['originalDevice'] == identity['device'] &&
        sequential['name'] == 'Synthetic sequential name ${manifest['run']}' &&
        local['name'] ==
            'Synthetic ${manifest['role']} concurrent name ${manifest['run']}',
  );
  final views = (actual['nameViews'] as List).cast<Map>();
  _require(views.length == 2 && views.every((v) => v['hasConflict'] == false));
  final selected = views.singleWhere(
    (v) => v['job'] == expected['selectedJob'],
  );
  _require(
    selected['creationDigest'] == expected['creationDigest'] &&
        _canonical(selected['heads']) ==
            _canonical([expected['localOperation']]) &&
        selected['resolvedName'] == local['name'],
  );
}

Future<void> verifyJoinNativeInterruptedAck(
  CompanyEnrollment enrollment,
  OwnerSession session,
  Map<String, dynamic> manifest,
) async {
  final expected = manifest['evidence'] as Map;
  final peer = expected['peerIdentity'] as Map;
  final retained = await CompanyPeerAuthentication(enrollment: enrollment)
      .retainedPeers(session: session);
  final matching = retained.where((p) => p.deviceId == peer['device']).toList();
  _require(
    matching.length == 1 &&
        matching.single.fingerprint == peer['publicKeySha256'] &&
        peer['user'] == session.identity.userId,
  );
  final rows = await enrollment.db
      .select(enrollment.db.companyJobNamePeerAcks)
      .get();
  _require(rows.length == 1 && rows.single.peerDeviceId == peer['device']);
  final body = (jsonDecode(rows.single.ackBytes) as Map)['body'] as Map;
  _require(
    body['receiver'] == peer['installation'] &&
        body['generation'] == peer['generation'] &&
        body['store'] == peer['storeGeneration'] &&
        body['kind'] == 'company.job.name.ack@1' &&
        (body['descriptor'] as Map)['operation'] ==
            expected['sequentialOperation'],
  );
  await CompanyCreatedJobSync.confirmedPeerCounts(enrollment, session);
}

void verifyJoinNativeEvidenceProvenance(
  Map<String, dynamic> evidence, {
  required String revision,
  required String tree,
  required String adapter,
  required String productRevision,
  Map<String, dynamic>? recoveryManifest,
}) {
  final origin = recoveryManifest?['origin'] as Map?;
  _require(
    evidence['sourceRevision'] == (origin?['revision'] ?? revision) &&
        evidence['sourceTree'] == (origin?['tree'] ?? tree) &&
        evidence['adapterSha256'] == (origin?['adapterSha256'] ?? adapter) &&
        evidence['productRevision'] ==
            (origin?['productRevision'] ?? productRevision),
  );
}

bool mayExerciseCreatedJobNameUi({
  required bool restart,
  required bool conflictResume,
  required bool interruptedResume,
  required bool interruptedReadbackVerified,
  required NativeJobNameUiStep step,
}) =>
    (!restart || conflictResume || interruptedResume) &&
    (!interruptedResume ||
        (interruptedReadbackVerified &&
            step == NativeJobNameUiStep.checkpointConflict));

Future<void> verifyJoinNativeRecoveryCustody(
  InstallationSecureStore store,
  String namespace,
) async {
  _require(
    await store.readState(namespace) != null &&
        await store.readState(companyCustodyNamespace(namespace)) != null,
  );
}

Future<void> verifyJoinNativeRecoveryBinding(AppDatabase db) async {
  _require(await db.settingsDao.getSetting(kInstallationBindingKey) != null);
}

/// Existing roots are admitted only as an exact unresolved checkpoint or a
/// completed exercise. This check precedes secure-store and database access.
JoinNativeRootAdmission validateJoinNativeRootAdmission(
  Directory root, {
  required String run,
  required String role,
  required String revision,
  required String tree,
  required String adapter,
  bool createdMode = false,
  bool jobNameMode = false,
  String productRevision = joinNativeProductRevision,
  String recoveryManifestPath = '',
  String recoveryManifestSha256 = '',
}) {
  final type = FileSystemEntity.typeSync(root.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    _require(recoveryManifestPath.isEmpty && recoveryManifestSha256.isEmpty);
    return const JoinNativeRootAdmission(JoinNativeRootStage.fresh);
  }
  _require(type == FileSystemEntityType.directory);
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    _require(
      FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.link,
    );
  }
  final exerciseFile = File(p.join(root.path, 'join-exercise.json'));
  final conflictFile = File(p.join(root.path, 'join-name-conflict.json'));
  Map<String, dynamic>? recovery;
  if (recoveryManifestPath.isNotEmpty || recoveryManifestSha256.isNotEmpty) {
    _require(
      createdMode &&
          jobNameMode &&
          recoveryManifestPath.isNotEmpty &&
          recoveryManifestSha256.isNotEmpty,
    );
    recovery = _readInterruptedManifest(
      root,
      recoveryManifestPath,
      recoveryManifestSha256,
      run: run,
      role: role,
      revision: revision,
      tree: tree,
      adapter: adapter,
      productRevision: productRevision,
    );
    if (!exerciseFile.existsSync() && !conflictFile.existsSync()) {
      verifyJoinNativeInterruptedFiles(root, recovery);
      return JoinNativeRootAdmission(
        JoinNativeRootStage.interruptedNames,
        recoveryManifest: recovery,
      );
    }
  }
  void verifyRecoveryMarker(Map<String, dynamic> marker) {
    _require(
      recovery == null
          ? marker['interruptedRecoverySha256'] == null
          : marker['interruptedRecoverySha256'] == recoveryManifestSha256,
    );
  }

  if (jobNameMode && !exerciseFile.existsSync() && conflictFile.existsSync()) {
    final checkpoint = _readOwnedJson(conflictFile);
    verifyRecoveryMarker(checkpoint);
    final identity = checkpoint['identity'];
    final evidence = checkpoint['nameEvidence'];
    _require(
      checkpoint['format'] == 1 &&
          checkpoint['stage'] == 'unresolved-name-conflict' &&
          checkpoint['passed'] == false &&
          checkpoint['run'] == run &&
          checkpoint['role'] == role &&
          checkpoint['namespace'] ==
              joinNativeNamespace(run, role, createdMode: true) &&
          checkpoint['sourceRevision'] == revision &&
          checkpoint['sourceTree'] == tree &&
          checkpoint['adapterSha256'] == adapter &&
          checkpoint['productRevision'] == productRevision &&
          checkpoint['root'] == root.path &&
          checkpoint['mode'] == 'created-jobs' &&
          checkpoint['schema'] == 9 &&
          checkpoint['jobNameMode'] == true &&
          checkpoint['createdJobsComplete'] == false &&
          checkpoint['jobNamesComplete'] == false &&
          checkpoint['locked'] == true &&
          checkpoint['syncCompleted'] == true &&
          checkpoint['syncStarts'] is int &&
          (checkpoint['syncStarts'] as int) > 0 &&
          checkpoint['nearbyControllerRunning'] == false &&
          checkpoint['productionJobsPanelRendered'] == true &&
          checkpoint['bothAttributedCandidatesRendered'] == true &&
          checkpoint['lockedSqlSha256'] is String &&
          _sha256Pattern.hasMatch(checkpoint['lockedSqlSha256'].toString()) &&
          productRevision == revision &&
          productRevision != joinNativeProductRevision &&
          identity is Map &&
          identity.length == 8 &&
          identity.values.every(
            (value) =>
                value is String && value.isNotEmpty && value.length <= 64,
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
          }) &&
          evidence is Map &&
          evidence['nameOperationCount'] == 3 &&
          evidence['nameReceiptCountVerified'] == 3 &&
          evidence['nameAckCount'] == 3 &&
          evidence['jobHistorySha256'] is String &&
          _sha256Pattern.hasMatch(evidence['jobHistorySha256'].toString()) &&
          evidence['nameRecordsSha256'] is String &&
          _sha256Pattern.hasMatch(evidence['nameRecordsSha256'].toString()) &&
          evidence['nameAckSha256'] is String &&
          _sha256Pattern.hasMatch(evidence['nameAckSha256'].toString()) &&
          evidence['nameReceiptVerification'] == 'typed-public-verifier' &&
          evidence['ackVerification'] == 'confirmedPeerCounts' &&
          evidence['nameViews'] is List,
    );
    final views = (evidence['nameViews'] as List).whereType<Map>().toList();
    _require(
      views.length == 2 && views.every((view) => view['candidates'] is List),
    );
    final conflictViews = views.where((view) => view['hasConflict'] == true);
    _require(conflictViews.length == 1);
    final candidates = (conflictViews.single['candidates'] as List)
        .whereType<Map>()
        .toList();
    _require(
      candidates.length == 2 &&
          candidates.every(
            (candidate) => ['operation', 'name', 'user', 'device'].every(
              (key) =>
                  candidate[key] is String &&
                  (candidate[key] as String).isNotEmpty,
            ),
          ) &&
          candidates
                  .map((candidate) => candidate['operation'])
                  .toSet()
                  .length ==
              2 &&
          candidates.map((candidate) => candidate['name']).toSet().length == 2,
    );
    return JoinNativeRootAdmission(
      JoinNativeRootStage.unresolvedConflict,
      conflictCheckpoint: checkpoint,
      recoveryManifest: recovery,
    );
  }
  _require(exerciseFile.existsSync());
  final receipt = _readOwnedJson(exerciseFile);
  verifyRecoveryMarker(receipt);
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
          receipt['schema'] == 9 &&
          receipt['createdJobsComplete'] == true &&
          receipt['bothJobsRendered'] == true &&
          receipt['receiptCountVerifiedBeforeLock'] == 2 &&
          productRevision == revision &&
          productRevision != joinNativeProductRevision,
    );
    _require(
      jobNameMode
          ? receipt['jobNameMode'] == true
          : receipt['jobNameMode'] == null,
    );
    if (jobNameMode) {
      _require(
        receipt['jobNamesComplete'] == true &&
            receipt['nameReceiptCountVerifiedBeforeLock'] == 4 &&
            receipt['nameOperationCount'] == 4 &&
            receipt['nameAckCount'] == 4,
      );
    }
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
  return JoinNativeRootAdmission(
    JoinNativeRootStage.completed,
    recoveryManifest: recovery,
  );
}

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

void verifyJoinNativeJobNameReadback(
  Map<String, dynamic> expectedReceipt,
  Map<String, Object?> actual,
) {
  final expected = expectedReceipt['nameEvidence'] is Map
      ? (expectedReceipt['nameEvidence'] as Map).cast<String, Object?>()
      : expectedReceipt.cast<String, Object?>();
  final count = expected['nameOperationCount'];
  _require(count == 3 || count == 4);
  _require(
    expected['nameReceiptCountVerified'] == count &&
        expected['nameAckCount'] == count &&
        actual['nameOperationCount'] == count &&
        actual['nameReceiptCountVerified'] == count &&
        actual['nameAckCount'] == count &&
        expected['nameReceiptVerification'] == 'typed-public-verifier' &&
        actual['nameReceiptVerification'] == 'typed-public-verifier' &&
        expected['ackVerification'] == 'confirmedPeerCounts' &&
        actual['ackVerification'] == 'confirmedPeerCounts' &&
        expected['jobHistorySha256'] is String &&
        _sha256Pattern.hasMatch(expected['jobHistorySha256'].toString()) &&
        expected['nameRecordsSha256'] is String &&
        _sha256Pattern.hasMatch(expected['nameRecordsSha256'].toString()) &&
        expected['nameAckSha256'] is String &&
        _sha256Pattern.hasMatch(expected['nameAckSha256'].toString()) &&
        expected['jobHistorySha256'] == actual['jobHistorySha256'] &&
        expected['nameRecordsSha256'] == actual['nameRecordsSha256'] &&
        expected['nameAckSha256'] == actual['nameAckSha256'] &&
        _canonical(expectedReceipt['identity']) ==
            _canonical(actual['identity']) &&
        _canonical(expected['nameViews']) == _canonical(actual['nameViews']),
  );
}

/// Called only after enrollment and cancellation-drain transitions have had
/// their existing finish handling. A final cold restart may skip Sync Now;
/// an unresolved-conflict resume must finish a fresh Sync after its verified
/// cold readback.
bool mayFinalizeCreatedJobNameStage({
  required bool restart,
  required bool conflictResume,
  required bool conflictReadbackVerified,
  required bool syncComplete,
  bool interruptedResume = false,
}) =>
    !interruptedResume &&
    (!conflictResume || conflictReadbackVerified) &&
    ((restart && !conflictResume) || syncComplete);

/// Final-only compatibility predicate used by older admission tests.
bool validateJoinNativeExistingRoot(
  Directory root, {
  required String run,
  required String role,
  required String revision,
  required String tree,
  required String adapter,
  bool createdMode = false,
  bool jobNameMode = false,
  String productRevision = joinNativeProductRevision,
}) =>
    validateJoinNativeRootAdmission(
      root,
      run: run,
      role: role,
      revision: revision,
      tree: tree,
      adapter: adapter,
      createdMode: createdMode,
      jobNameMode: jobNameMode,
      productRevision: productRevision,
    ).stage ==
    JoinNativeRootStage.completed;

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

bool mayStartCreatedJobNativeSync({
  required bool owner,
  required bool jobNameMode,
  required bool syncEnabled,
}) => (owner || jobNameMode) && syncEnabled;

const createdJobNativeDiagnosticLimit = 32;

final class CreatedJobNativeSyncDiagnostics {
  bool receiverCallbackReached = false;
  CreatedJobSyncResult? _result;
  final List<Map<String, Object?>> _terminals = [];
  int _droppedTerminals = 0;
  int _evidenceWriteAttempts = 0;
  int _droppedEvidence = 0;
  int get evidenceWriteAttempts => _evidenceWriteAttempts;

  void resetAttempt() {
    receiverCallbackReached = false;
    _result = null;
  }

  bool observe(CreatedJobSyncDiagnostic diagnostic) {
    final firstReceiverEntry =
        !receiverCallbackReached && diagnostic.receiverCallbackReached;
    if (diagnostic.kind == CreatedJobSyncDiagnosticKind.started) resetAttempt();
    receiverCallbackReached |= diagnostic.receiverCallbackReached;
    if (diagnostic.result case final result?) {
      _result = result;
      if (_terminals.length < createdJobNativeDiagnosticLimit) {
        _terminals.add(_current());
      } else {
        _droppedTerminals++;
      }
    }
    if (!firstReceiverEntry && diagnostic.result == null) return false;
    if (_evidenceWriteAttempts >= createdJobNativeDiagnosticLimit) {
      _droppedEvidence++;
      return false;
    }
    _evidenceWriteAttempts++;
    return true;
  }

  Map<String, Object?> _current() => {
    'receiverCallbackReached': receiverCallbackReached,
    'terminalObserved': _result != null,
    if (_result case final result?) ...{
      'complete': result.complete,
      'sent': result.sent,
      'received': result.received,
      'unsupported': result.unsupported,
      'failureStage': result.failure?.stage.name,
      'failureReason': result.failure?.reason.name,
    },
  };

  Map<String, Object?> get snapshot => {
    ..._current(),
    'terminals': [for (final terminal in _terminals) Map.of(terminal)],
    'droppedTerminals': _droppedTerminals,
    'evidenceWriteAttempts': _evidenceWriteAttempts,
    'droppedEvidence': _droppedEvidence,
  };
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

bool createdJobNativeUiBusy() =>
    find.byKey(const Key('company-jobs-sync-now')).evaluate().length == 1 &&
    find.byKey(const Key('company-join-busy')).evaluate().length == 1;

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
  if ((status.startsWith('Job sync incomplete. Confirmed sent ') &&
          status.contains('Pair again and retry Sync Now.')) ||
      (status.startsWith('Confirmed sent ') &&
          status.contains('More Jobs pending.'))) {
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
    this.conflictCheckpoint,
    this.recoveryManifest,
    this.interruptedResume,
    this.detailsCheckpoint,
    this.detailsBaselineRecovery,
    this.detailsPendingRecovery,
  );
  final WidgetTester tester;
  final ValidationWorkspace workspace;
  final AppDatabase db;
  final InstallationSecurity security;
  final bool restart;
  final Map<String, dynamic>? conflictCheckpoint;
  final Map<String, dynamic>? recoveryManifest;
  final bool interruptedResume;
  final Map<String, dynamic>? detailsCheckpoint;
  final Map<String, dynamic>? detailsBaselineRecovery;
  final Map<String, dynamic>? detailsPendingRecovery;
  bool get baselineResume =>
      detailsBaselineRecovery != null &&
      detailsCheckpoint == null &&
      detailsPendingRecovery == null;
  bool get pendingResume =>
      detailsPendingRecovery != null && detailsCheckpoint == null;
  bool get conflictResume => conflictCheckpoint != null;
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
  bool conflictReadbackVerified = false;
  bool interruptedReadbackVerified = false;
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
  final syncDiagnostics = CreatedJobNativeSyncDiagnostics();
  final detailsTerminals = <Map<String, Object?>>[];
  int cancelStarts = 0;
  int interruptionStarts = 0;
  int interruptionDrains = 0;
  int joinPageEpoch = 0;
  bool routeReturned = false;
  _CreatedJobCancelReason? cancelReason;
  bool get owner => _roleName == 'owner';
  TestRole get role => owner ? TestRole.sender : TestRole.receiver;
  String get peerId => 'lan-${workspace.run}-${owner ? 'receiver' : 'sender'}';
  String get phase => conflictResume
      ? 'conflict'
      : restart
      ? 'restart'
      : 'exercise';
  String get receiptPhase => conflictResume ? 'exercise' : phase;
  String get namespace => joinNativeNamespace(
    _run,
    _roleName,
    createdMode: _createdMode,
    detailsMode: _detailsMode,
  );
  String get productRevision =>
      _createdMode ? _createdProductRevision : joinNativeProductRevision;
  bool get reconnect =>
      restart || (_createdMode && createdStage != _CreatedJobStage.enrollment);
  bool get cancellationDrained =>
      createdStage == _CreatedJobStage.cancelling &&
      routeReturned &&
      !pageMounted &&
      !view.running &&
      lifecycleCurrent();
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
    busy: createdJobNativeUiBusy(),
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
    if (_jobNameMode) 'jobNameMode': true,
    if (_detailsMode) ...{
      'jobDetailsMode': true,
      'detailsManifestSha256': _detailsManifestSha256,
      if (detailsBaselineRecovery != null)
        'detailsBaselineRecoverySha256': _detailsBaselineRecoverySha256,
      if (detailsPendingRecovery != null)
        'detailsPendingRecoverySha256': _detailsPendingRecoverySha256,
    },
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

  Future<void> pumpReadiness() async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  Future<void> wait(bool Function() ready) => waitForJoinNativeCompletion(
    ready: ready,
    elapsedMillis: () => clock.elapsedMilliseconds,
    pump: pumpReadiness,
    commandDeadlineMillis: activeCommand?.deadlineMillis,
    enforceCommandDeadline: true,
  );

  Future<void> waitForPassiveCompletion(bool Function() ready) async {
    await waitForJoinNativeCompletion(
      ready: () => !lifecycleCurrent() || ready(),
      elapsedMillis: () => clock.elapsedMilliseconds,
      pump: pumpReadiness,
      commandDeadlineMillis: activeCommand?.deadlineMillis,
    );
    _require(lifecycleCurrent());
  }

  bool lifecycleCurrent() => !lifecycleCancelled && !closed && !exitRequested;
  bool effectCurrent() =>
      lifecycleCurrent() &&
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
    if (_jobNameMode || _detailsMode) {
      final jobs = await CompanyJobCommands(enrollment: enrollment)
          .listJobViews(ownerSession: adapterSession!);
      _require(jobs.length == expected);
      await wait(
        () =>
            find.byKey(const Key('company-jobs-list')).evaluate().length == 1 &&
            find.text('Loading company Jobs...').evaluate().isEmpty,
      );
      assertJobNameNativeViewUi(tester, jobs);
      if (_detailsMode) assertJobDetailsNativeViewUi(tester, jobs);
      return;
    }
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

  String get _sequentialName => 'Synthetic sequential name $_run';
  String _concurrentName(bool byOwner) =>
      'Synthetic ${byOwner ? 'owner' : 'member'} concurrent name $_run';

  Future<Map<String, Object?>> nameHistoryEvidence() async {
    final rows = await db.select(db.companyJobNames).get();
    final acks = await db.select(db.companyJobNamePeerAcks).get();
    var verified = 0;
    List<CompanyJobView>? views;
    final held = adapterSession;
    if (held != null && held.isValid) {
      final commands = CompanyJobCommands(enrollment: enrollment);
      final admitted = await commands.nameSyncHoldings(ownerSession: held);
      _require(admitted.length == rows.length);
      _require(
        _hash(admitted.map((r) => _canonical(r.toJson())).toList()..sort()) ==
            _hash(rows.map((r) => _canonical(r.toJson())).toList()..sort()),
      );
      verified = admitted.length;
      views = await commands.listJobViews(ownerSession: held);
    }
    return {
      'nameOperationCount': rows.length,
      'nameReceiptCountVerified': verified,
      'nameRecordsSha256': _hash(
        rows.map((r) => _canonical(r.toJson())).toList()..sort(),
      ),
      'nameAckCount': acks.length,
      'nameAckSha256': _hash(
        acks.map((r) => _canonical(r.toJson())).toList()..sort(),
      ),
      'nameRecords':
          rows.map((row) {
            final body = (jsonDecode(row.operationBytes) as Map)['body'] as Map;
            return {
              'job': row.jobId,
              'operation': row.operationCommitment,
              'origin': row.originGeneration,
              'request': row.requestId,
              'parents': body['parents'],
              'creationDigest': body['creation'],
              'originalUser': body['user'],
              'originalDevice': body['device'],
              'name': body['name'],
              'operationSha256': _hashBytes(row.operationBytes),
              'receiptSha256': _hashBytes(row.receiptBytes),
              'auditSha256': _hashBytes(row.auditBytes),
              'outgoing': row.outgoing,
            };
          }).toList()..sort(
            (a, b) =>
                (a['operation'] as String).compareTo(b['operation'] as String),
          ),
      if (views != null)
        'nameViews': views
            .map(
              (v) => {
                'job': v.baseJob.id,
                'creationDigest': v.creationDigest,
                'heads': v.nameHeads,
                'displayName': v.displayName,
                'resolvedName': v.resolvedName,
                'lastAgreedName': v.lastAgreedName,
                'hasConflict': v.hasConflict,
                'candidates': v.candidates
                    .map(
                      (c) => {
                        'operation': c.operationId,
                        'name': c.name,
                        'user': c.originalUserId,
                        'device': c.originalDeviceId,
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      'nameReceiptVerification': held?.isValid == true
          ? 'typed-public-verifier'
          : 'locked-not-performed',
    };
  }

  String _hashBytes(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  Future<Map<String, Object?>> detailsHistoryEvidence() async {
    final rows = await db.select(db.companyJobDetails).get();
    final acks = await db.select(db.companyJobDetailPeerAcks).get();
    final held = adapterSession;
    List<CompanyJobView>? views;
    var verified = 0;
    if (held != null && held.isValid) {
      final commands = CompanyJobCommands(enrollment: enrollment);
      final admitted = await commands.detailsSyncHoldings(ownerSession: held);
      _require(
        _hash(admitted.map((r) => _canonical(r.toJson())).toList()..sort()) ==
            _hash(rows.map((r) => _canonical(r.toJson())).toList()..sort()),
      );
      verified = admitted.length;
      views = await commands.listJobViews(ownerSession: held);
    }
    return {
      'detailsOperationCount': rows.length,
      'detailsReceiptCountVerified': verified,
      'detailsRecordsSha256': _hash(
        rows.map((r) => _canonical(r.toJson())).toList()..sort(),
      ),
      'detailsAckCount': acks.length,
      'detailsAckSha256': _hash(
        acks.map((r) => _canonical(r.toJson())).toList()..sort(),
      ),
      'detailsReceiptVerification': held?.isValid == true
          ? 'typed-public-verifier'
          : 'locked-not-performed',
      'detailsRecords':
          rows
              .map(
                (r) => {
                  'job': r.jobId,
                  'operation': r.operationCommitment,
                  'operationSha256': _hashBytes(r.operationBytes),
                  'receiptSha256': _hashBytes(r.receiptBytes),
                  'auditSha256': _hashBytes(r.auditBytes),
                  'outgoing': r.outgoing,
                  'originalUser':
                      ((jsonDecode(r.operationBytes) as Map)['body']
                          as Map)['user'],
                  'originalDevice':
                      ((jsonDecode(r.operationBytes) as Map)['body']
                          as Map)['device'],
                },
              )
              .toList()
            ..sort(
              (a, b) => (a['operation'] as String).compareTo(
                b['operation'] as String,
              ),
            ),
      if (views != null)
        'detailsViews': views
            .map(
              (v) => {
                'job': v.baseJob.id,
                'creationDigest': v.creationDigest,
                'fields': {
                  for (final field in JobDetailField.values)
                    field.name: {
                      'value': _nativeDetailWire(_nativeDetail(v, field).value),
                      'lastAgreedValue': _nativeDetailWire(
                        _nativeDetail(v, field).lastAgreedValue,
                      ),
                      'heads': _nativeDetail(v, field).heads,
                      'hasConflict': _nativeDetail(v, field).hasConflict,
                      'candidates': _nativeDetail(v, field).candidates
                          .map(
                            (c) => {
                              'value': _nativeDetailWire(c.value),
                              'operation': c.operationId,
                              'user': c.originalUserId,
                              'device': c.originalDeviceId,
                            },
                          )
                          .toList(),
                    },
                },
              },
            )
            .toList(),
    };
  }

  Future<NativeTestCommandResult> exerciseJobDetailsUi(
    NativeJobDetailsUiStep step,
  ) async {
    _require(
      _detailsMode &&
          _createdMode &&
          !_jobNameMode &&
          reconnect &&
          !finished &&
          createdStage == _CreatedJobStage.retainedPeer,
    );
    requireSnapshotSafe();
    final checkpointStage = switch (step) {
      NativeJobDetailsUiStep.checkpointMixed => 'mixed',
      NativeJobDetailsUiStep.checkpointConflict => 'conflict',
      NativeJobDetailsUiStep.checkpointResolved => 'resolved',
      _ => null,
    };
    final syncComplete = syncUiState == CreatedJobNativeUiState.complete;
    if (checkpointStage != null) {
      _require(
        syncComplete &&
            detailsTerminals.isNotEmpty &&
            detailsTerminals.last['complete'] == true,
      );
      if (checkpointStage == 'mixed') {
        validateJobDetailsNativeMixedRepeat(detailsTerminals);
      }
    }
    requireBeforeEffect();
    await controller!.dispose();
    _require(!view.running);
    await enrollment.signOut();
    adapterSession = null;
    await mountGate();
    await signInUi();
    adapterSession = await tester.runAsync(() => enrollment.signIn(_pin));
    final commands = CompanyJobCommands(enrollment: enrollment);
    _require(await commands.canEditJobDetails(adapterSession!));
    final before = await commands.listJobViews(ownerSession: adapterSession!);
    _require(before.length == 2);
    assertJobDetailsNativeViewUi(tester, before);
    final sorted = [...before]
      ..sort((a, b) => a.baseJob.id.compareTo(b.baseJob.id));
    final selected = sorted.first;
    final baselineFile = File(
      p.join(workspace.root.path, 'details-shared-baseline-$_roleName.json'),
    );
    final creationHash = await jobHash();
    final namesHash = _hash(
      (await db.select(db.companyJobNames).get())
          .map((r) => _canonical(r.toJson()))
          .toList()
        ..sort(),
    );
    final history = await commands.detailsSyncHoldings(
      ownerSession: adapterSession!,
    );
    final count = history.length;
    if (!baselineFile.existsSync()) {
      _require(step == NativeJobDetailsUiStep.inspect && count == 0);
      writeOnce(p.basename(baselineFile.path), {
        'selectedJob': selected.baseJob.id,
        'creationDigest': selected.creationDigest,
        'creationHistorySha256': creationHash,
        'nameRecordsSha256': namesHash,
      });
    }
    final baseline = detailsBaselineRecovery == null
        ? _readOwnedJson(baselineFile)
        : verifyDetailsBaselineInspection(
            workspace.root,
            detailsBaselineRecovery!,
          );
    if (detailsBaselineRecovery == null) {
      verifyJoinNativeEvidenceProvenance(
        baseline,
        revision: _revision,
        tree: _tree,
        adapter: _adapter,
        productRevision: productRevision,
      );
    }
    _require(
      baseline['run'] == _run &&
          baseline['role'] == _roleName &&
          baseline['namespace'] == namespace &&
          baseline['jobDetailsMode'] == true &&
          baseline['detailsManifestSha256'] ==
              (detailsBaselineRecovery == null
                  ? _detailsManifestSha256
                  : _detailsBaselineOrigin['manifestSha256']) &&
          baseline['selectedJob'] == selected.baseJob.id &&
          baseline['creationDigest'] == selected.creationDigest &&
          baseline['creationHistorySha256'] == creationHash &&
          baseline['nameRecordsSha256'] == namesHash,
    );
    final notes = selected.details.notes;
    final mixed = {
      NativeJobDetailsUiStep.inspectMixed,
      NativeJobDetailsUiStep.checkpointMixed,
      NativeJobDetailsUiStep.editNotesOffline,
    }.contains(step);
    final conflict = {
      NativeJobDetailsUiStep.inspectConflict,
      NativeJobDetailsUiStep.checkpointConflict,
      NativeJobDetailsUiStep.resolveNotes,
    }.contains(step);
    final resolved = {
      NativeJobDetailsUiStep.inspectResolved,
      NativeJobDetailsUiStep.checkpointResolved,
    }.contains(step);
    if (mixed || conflict || resolved) {
      _require(
        selected.details.customer.value == 'Acme' &&
            selected.details.status.value == CompanyJobStatus.archived &&
            !selected.details.customer.hasConflict &&
            !selected.details.status.hasConflict,
      );
    }
    if (mixed) {
      _require(count == 2 && !notes.hasConflict && notes.value == 'Gate 3');
    }
    if (conflict) {
      _require(
        count == 4 &&
            notes.hasConflict &&
            notes.lastAgreedValue == 'Gate 3' &&
            notes.heads.length == 2 &&
            notes.candidates.length == 2,
      );
      _require(
        notes.candidates.map((c) => c.value).toSet().containsAll({
          'Synthetic owner notes $_run',
          'Synthetic member notes $_run',
        }),
      );
      _require(
        notes.candidates.map((c) => c.originalDeviceId).toSet().length == 2,
      );
    }
    if (resolved) {
      _require(
        count == 5 &&
            !notes.hasConflict &&
            notes.heads.length == 1 &&
            {
              'Synthetic owner notes $_run',
              'Synthetic member notes $_run',
            }.contains(notes.value),
      );
    }
    final edits = <JobDetailField, String?>{};
    CompanyJobStatus? status;
    String? candidate;
    if (step == NativeJobDetailsUiStep.inspect) {
      _require(
        count == 0 &&
            JobDetailField.values.every(
              (f) => _nativeDetail(selected, f).heads.isEmpty,
            ),
      );
    }
    if (step == NativeJobDetailsUiStep.editMixedOffline) {
      _require(count == 0);
      if (owner) {
        edits[JobDetailField.customer] = 'Acme';
        status = CompanyJobStatus.archived;
      } else {
        edits[JobDetailField.notes] = 'Gate 3';
      }
    }
    if (step == NativeJobDetailsUiStep.editNotesOffline) {
      edits[JobDetailField.notes] = 'Synthetic $_roleName notes $_run';
    }
    if (step == NativeJobDetailsUiStep.resolveNotes) {
      _require(owner);
      candidate = notes.candidates.first.operationId;
    }
    final changed = edits.isNotEmpty || status != null || candidate != null;
    if (changed) {
      await saveJobDetailsThroughNativeUi(
        tester: tester,
        jobId: selected.baseJob.id,
        text: edits,
        status: status,
        notesCandidateOperationId: candidate,
        tap: tap,
        waitUntilReady: wait,
        requireBeforeEffect: requireBeforeEffect,
      );
    }
    final after = await commands.listJobViews(ownerSession: adapterSession!);
    assertJobDetailsNativeViewUi(tester, after);
    _require(await jobHash() == creationHash);
    _require(
      _hash(
            (await db.select(db.companyJobNames).get())
                .map((r) => _canonical(r.toJson()))
                .toList()
              ..sort(),
          ) ==
          namesHash,
    );
    final afterHistory = await commands.detailsSyncHoldings(
      ownerSession: adapterSession!,
    );
    _require(afterHistory.length == count + (changed ? 1 : 0));
    if (changed) {
      final added = afterHistory
          .where(
            (r) => !history.any(
              (old) => old.operationCommitment == r.operationCommitment,
            ),
          )
          .single;
      final body = (jsonDecode(added.operationBytes) as Map)['body'] as Map;
      final units = body['units'] as Map;
      final fields = candidate != null
          ? {JobDetailField.notes}
          : {...edits.keys, if (status != null) JobDetailField.status};
      _require(
        units.length == fields.length &&
            units.keys.toSet().containsAll(fields.map((f) => f.name)),
      );
      _require(
        _canonical(body['resolve']) ==
            _canonical(candidate == null ? <String>[] : ['notes']),
      );
      for (final field in fields) {
        final unit = units[field.name] as Map;
        _require(
          _canonical(unit['parents']) ==
              _canonical(_nativeDetail(selected, field).heads),
        );
        final expected = candidate != null
            ? notes.candidates.first.value
            : field == JobDetailField.status
            ? status!.name
            : edits[field];
        _require(unit['value'] == expected);
      }
      final next = after.singleWhere(
        (v) => v.baseJob.id == selected.baseJob.id,
      );
      for (final field in JobDetailField.values.where(
        (f) => !fields.contains(f),
      )) {
        _require(
          _canonical(_nativeDetail(next, field).heads) ==
              _canonical(_nativeDetail(selected, field).heads),
        );
      }
    }
    final evidence = await snapshot();
    writeOnce('details-ui-$pid-${activeCommand!.sequence}.json', {
      ...evidence,
      'step': step.name,
      'selectedJob': selected.baseJob.id,
      'savedThroughProductionUi': changed,
      'productionJobsPanelRendered': true,
      'companyControllerStoppedDuringUi': !view.running,
      'detailsTerminals': detailsTerminals,
      'passed': false,
    });
    if (checkpointStage != null) {
      _require(
        evidence['detailsAckCount'] == count &&
            evidence['detailsReceiptCountVerified'] == count &&
            evidence['ackCount'] == 2 &&
            evidence['nameOperationCount'] == 0 &&
            evidence['ackVerification'] == 'confirmedPeerCounts',
      );
      _require(
        (evidence['confirmedPeerCounts'] as Map).values.every((n) => n == 1),
      );
      await enrollment.signOut();
      adapterSession = null;
      await signOutUi();
      final locked = await snapshot();
      _require(
        locked['locked'] == true &&
            locked['detailsRecordsSha256'] == evidence['detailsRecordsSha256'],
      );
      writeOnce(
        'join-details-checkpoint-$pid-${activeCommand!.sequence}.json',
        {
          'passed': false,
          'schema': 10,
          'detailsStage': checkpointStage,
          'locked': true,
          'nearbyControllerRunning': view.running,
          'identity': evidence['identity'],
          'detailsEvidence': evidence,
          'detailsTerminals': detailsTerminals,
          'lockedSqlSha256': locked['sqlSha256'],
          'productionJobsPanelRendered': true,
          'coldReadbackRequired': true,
        },
      );
      finished = true;
      return const NativeTestCommandResult.effect();
    }
    await completeJobDetailsNativeUiReturn(
      isStillCurrent: lifecycleCurrent,
      mountPage: (waitUntilReady) =>
          mountJoinPage(waitUntilReady: waitUntilReady),
      waitForCompletion: waitForPassiveCompletion,
    );
    _require(savedPair == null && syncUiState == CreatedJobNativeUiState.idle);
    return const NativeTestCommandResult.effect();
  }

  Future<NativeTestCommandResult> exerciseJobNameUi(
    NativeJobNameUiStep step,
  ) async {
    _require(
      _jobNameMode &&
          _createdMode &&
          reconnect &&
          mayExerciseCreatedJobNameUi(
            restart: restart,
            conflictResume: conflictResume,
            interruptedResume: interruptedResume,
            interruptedReadbackVerified: interruptedReadbackVerified,
            step: step,
          ) &&
          !finished,
    );
    requireSnapshotSafe();
    _require(createdStage == _CreatedJobStage.retainedPeer);
    if (conflictResume) {
      _require(
        step ==
            (owner
                ? NativeJobNameUiStep.resolveFirst
                : NativeJobNameUiStep.inspectConflict),
      );
    } else if (step == NativeJobNameUiStep.resolveFirst) {
      _require(false);
    }
    final checkpointing = step == NativeJobNameUiStep.checkpointConflict;
    final syncCompletedBeforeUi =
        syncUiState == CreatedJobNativeUiState.complete;
    if (checkpointing) {
      _require(!conflictResume && syncCompletedBeforeUi && syncStarts > 0);
    }
    requireBeforeEffect();
    await controller!.dispose();
    _require(!view.running);
    await enrollment.signOut();
    adapterSession = null;
    await mountGate();
    await signInUi();
    adapterSession = await tester.runAsync(() => enrollment.signIn(_pin));
    final commands = CompanyJobCommands(enrollment: enrollment);
    final before = await commands.listJobViews(ownerSession: adapterSession!);
    _require(before.length == 2);
    assertJobNameNativeViewUi(tester, before);
    final sorted = [...before]
      ..sort((a, b) => a.baseJob.id.compareTo(b.baseJob.id));
    final selected = sorted.first;
    final baselineFile = File(
      p.join(workspace.root.path, 'name-shared-baseline-$_roleName.json'),
    );
    final creationHash = await jobHash();
    if (!baselineFile.existsSync()) {
      _require(
        step == NativeJobNameUiStep.inspect ||
            step == NativeJobNameUiStep.renameSequential,
      );
      _require(selected.nameHeads.isEmpty);
      writeOnce(p.basename(baselineFile.path), {
        'selectedJob': selected.baseJob.id,
        'creationDigest': selected.creationDigest,
        'creationHistorySha256': creationHash,
      });
    }
    final baseline = _readOwnedJson(baselineFile);
    verifyJoinNativeEvidenceProvenance(
      baseline,
      revision: _revision,
      tree: _tree,
      adapter: _adapter,
      productRevision: productRevision,
      recoveryManifest: recoveryManifest,
    );
    _require(
      baseline['run'] == _run &&
          baseline['role'] == _roleName &&
          baseline['namespace'] == namespace &&
          baseline['jobNameMode'] == true &&
          baseline['selectedJob'] == selected.baseJob.id &&
          baseline['creationDigest'] == selected.creationDigest &&
          baseline['creationHistorySha256'] == creationHash,
    );
    final history = await commands.nameSyncHoldings(
      ownerSession: adapterSession!,
    );
    final count = history.length;
    final isConflictStep =
        step == NativeJobNameUiStep.inspectConflict ||
        step == NativeJobNameUiStep.resolveFirst ||
        checkpointing;
    if (isConflictStep) {
      _require(
        count == 3 && selected.hasConflict && selected.nameHeads.length == 2,
      );
      _require(selected.lastAgreedName == _sequentialName);
      _require(
        selected.candidates.map((c) => c.name).toSet().containsAll({
          _concurrentName(true),
          _concurrentName(false),
        }),
      );
    }
    String? nextName;
    String? candidateId;
    switch (step) {
      case NativeJobNameUiStep.inspect:
        _require(
          count == 0 && !selected.hasConflict && selected.nameHeads.isEmpty,
        );
        break;
      case NativeJobNameUiStep.renameSequential:
        _require(owner && count == 0 && selected.nameHeads.isEmpty);
        nextName = _sequentialName;
        break;
      case NativeJobNameUiStep.renameConcurrent:
        _require(
          count == 1 &&
              !selected.hasConflict &&
              selected.resolvedName == _sequentialName &&
              selected.nameHeads.length == 1,
        );
        nextName = _concurrentName(owner);
        break;
      case NativeJobNameUiStep.inspectConflict:
        break;
      case NativeJobNameUiStep.checkpointConflict:
        _require(checkpointing && !conflictResume);
        break;
      case NativeJobNameUiStep.resolveFirst:
        _require(owner);
        final candidate = selected.candidates.first;
        nextName = candidate.name;
        candidateId = candidate.operationId;
        break;
      case NativeJobNameUiStep.inspectResolved:
        _require(
          count == 4 && !selected.hasConflict && selected.nameHeads.length == 1,
        );
        _require(
          {
            _concurrentName(true),
            _concurrentName(false),
          }.contains(selected.resolvedName),
        );
    }
    if (nextName != null) {
      await saveJobNameThroughNativeUi(
        tester: tester,
        jobId: selected.baseJob.id,
        name: nextName,
        candidateOperationId: candidateId,
        tap: tap,
        waitUntilReady: wait,
        requireBeforeEffect: requireBeforeEffect,
      );
    }
    final after = await commands.listJobViews(ownerSession: adapterSession!);
    assertJobNameNativeViewUi(tester, after);
    _require(await jobHash() == creationHash);
    if (nextName != null) {
      final next = after.singleWhere(
        (v) => v.baseJob.id == selected.baseJob.id,
      );
      _require(
        !next.hasConflict &&
            next.resolvedName == nextName &&
            next.nameHeads.length == 1,
      );
      final saved = await commands.verifyNameSyncRecord(
        next.nameHeads.single,
        adapterSession!,
      );
      final body = (jsonDecode(saved.operationBytes) as Map)['body'] as Map;
      _require(_canonical(body['parents']) == _canonical(selected.nameHeads));
      _require(
        (await commands.nameSyncHoldings(ownerSession: adapterSession!))
                .length ==
            count + 1,
      );
    }
    writeOnce('name-ui-$phase-$pid-${activeCommand!.sequence}.json', {
      'step': step.name,
      'selectedJob': selected.baseJob.id,
      'observedHeadsBefore': selected.nameHeads,
      'creationHistorySha256': creationHash,
      'originalCreationBytesUnchanged': true,
      'productionJobsPanelRendered': true,
      'savedThroughProductionUi': nextName != null,
      'companyControllerStoppedDuringUi': !view.running,
      ...await nameHistoryEvidence(),
    });
    if (checkpointing) {
      final activeEvidence = await snapshot();
      final baseline = _readOwnedJson(
        File(
          p.join(workspace.root.path, 'name-shared-baseline-$_roleName.json'),
        ),
      );
      final views = (activeEvidence['nameViews'] as List)
          .cast<Map<String, Object?>>();
      final conflictViews = views.where((view) => view['hasConflict'] == true);
      _require(
        syncCompletedBeforeUi &&
            activeEvidence['nameOperationCount'] == 3 &&
            activeEvidence['nameReceiptCountVerified'] == 3 &&
            activeEvidence['nameAckCount'] == 3 &&
            activeEvidence['nameReceiptVerification'] ==
                'typed-public-verifier' &&
            activeEvidence['ackVerification'] == 'confirmedPeerCounts' &&
            activeEvidence['jobHistorySha256'] ==
                baseline['creationHistorySha256'] &&
            activeEvidence['nameRecordsSha256'] is String &&
            activeEvidence['nameAckSha256'] is String &&
            conflictViews.length == 1 &&
            conflictViews.single['job'] == baseline['selectedJob'] &&
            (conflictViews.single['candidates'] as List).length == 2,
      );
      await enrollment.signOut();
      adapterSession = null;
      await signOutUi();
      final lockedEvidence = await snapshot();
      _require(
        lockedEvidence['locked'] == true &&
            lockedEvidence['jobHistorySha256'] ==
                activeEvidence['jobHistorySha256'],
      );
      writeOnce('join-name-conflict.json', {
        if (recoveryManifest != null)
          'interruptedRecoverySha256': _recoveryManifestSha256,
        'stage': 'unresolved-name-conflict',
        'passed': false,
        'mode': 'created-jobs',
        'schema': 9,
        'jobNameMode': true,
        'createdJobsComplete': false,
        'jobNamesComplete': false,
        'locked': true,
        'syncCompleted': true,
        'syncStarts': syncStarts,
        'nearbyControllerRunning': view.running,
        'productionJobsPanelRendered': true,
        'bothAttributedCandidatesRendered': true,
        'identity': activeEvidence['identity'],
        'nameEvidence': {
          for (final key in [
            'jobHistorySha256',
            'nameOperationCount',
            'nameReceiptCountVerified',
            'nameAckCount',
            'nameRecordsSha256',
            'nameAckSha256',
            'nameReceiptVerification',
            'ackVerification',
            'nameViews',
          ])
            key: activeEvidence[key],
        },
        'lockedSqlSha256': lockedEvidence['sqlSha256'],
      });
      finished = true;
      return const NativeTestCommandResult.effect();
    }
    await mountJoinPage();
    _require(savedPair == null && syncUiState == CreatedJobNativeUiState.idle);
    return const NativeTestCommandResult.effect();
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

  Future<void> mountJoinPage({
    Future<void> Function(bool Function())? waitUntilReady,
  }) async {
    final waitForReady = waitUntilReady ?? wait;
    stage = 'join-page';
    savedPair = null;
    final pageEpoch = ++joinPageEpoch;
    routeReturned = false;
    syncDiagnostics.resetAttempt();
    CompanyJoinPage page() => CompanyJoinPage(
      enrollment: enrollment,
      approver: adapterSession,
      reconnect: reconnect,
      onJobSyncDiagnostic: _createdMode
          ? (diagnostic) {
              if (_detailsMode && diagnostic.result != null) {
                _require(
                  detailsTerminals.length < createdJobNativeDiagnosticLimit,
                );
                detailsTerminals.add({
                  'elapsedMillis': clock.elapsedMilliseconds,
                  'pageEpoch': pageEpoch,
                  'complete': diagnostic.result!.complete,
                  'sent': diagnostic.result!.sent,
                  'received': diagnostic.result!.received,
                  'failureStage': diagnostic.result!.failure?.stage.name,
                });
              }
              if (syncDiagnostics.observe(diagnostic)) {
                writeOnce(
                  'created-sync-diagnostic-$pid-${syncDiagnostics.evidenceWriteAttempts}.json',
                  {
                    'observation': diagnostic.kind.name,
                    'pageEpoch': pageEpoch,
                    ...syncDiagnostics.snapshot,
                  },
                );
              }
            }
          : null,
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
      if (waitUntilReady != null) _require(lifecycleCurrent());
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
      waitUntilReady: waitForReady,
    );
    stage = 'join-page-wait-controller';
    await waitForReady(() => controller != null && view.running);
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
    _require(
      db.schemaVersion ==
          (_detailsMode
              ? 10
              : _createdMode
              ? 9
              : 7),
    );
    if (restart) {
      final prior = _detailsMode
          ? (detailsCheckpoint ??
                detailsPendingRecovery?['evidence'] as Map? ??
                detailsBaselineRecovery!['evidence'] as Map)
          : interruptedResume
          ? recoveryManifest!['evidence'] as Map
          : conflictResume
          ? conflictCheckpoint!
          : _readOwnedJson(
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
      final prior = _detailsMode
          ? (detailsCheckpoint ??
                detailsPendingRecovery?['evidence'] as Map? ??
                detailsBaselineRecovery!['evidence'] as Map)
          : interruptedResume
          ? recoveryManifest!['evidence'] as Map
          : conflictResume
          ? conflictCheckpoint!
          : _readOwnedJson(
              File(p.join(workspace.root.path, 'join-exercise.json')),
            );
      _require(_canonical(initialIdentity) == _canonical(prior['identity']));
      if (_detailsMode) {
        _require(
          await sqlHash() ==
              (baselineResume || pendingResume
                  ? prior['sqlSha256']
                  : prior['lockedSqlSha256']),
        );
      }
      final priorJobHash = pendingResume
          ? (detailsPendingRecovery!['savedEvidence']
                as Map)['jobHistorySha256']
          : baselineResume
          ? await jobHash()
          : _detailsMode
          ? (prior['detailsEvidence'] as Map)['jobHistorySha256']
          : conflictResume
          ? (prior['nameEvidence'] as Map)['jobHistorySha256']
          : prior['jobHistorySha256'];
      _require(await jobHash() == priorJobHash);
      originalJobHash = priorJobHash as String;
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
    if (_createdMode && restart) {
      _require(controller == null);
      await assertCreatedJobsUi(2);
      if (_detailsMode) {
        final actual = await snapshot();
        if (pendingResume) {
          final saved =
              detailsPendingRecovery!['savedEvidence'] as Map<String, dynamic>;
          await verifyDetailsPendingRecoveryRecords(
            enrollment: enrollment,
            owner: adapterSession!,
            sqlSha256:
                (detailsPendingRecovery!['evidence'] as Map)['sqlSha256']
                    as String,
            localCreation: _detailsBaselineOriginRecord(
              detailsBaselineRecovery!,
              'localCreation',
            ),
            savedDetail: (await db.select(db.companyJobDetails).get()).single
                .toJson(),
            role: _roleName,
          );
          verifyJobDetailsNativeReadback({'detailsEvidence': saved}, actual);
        } else if (baselineResume) {
          await verifyDetailsBaselineRecoveryRecords(
            enrollment: enrollment,
            owner: adapterSession!,
            sqlSha256:
                (detailsBaselineRecovery!['evidence'] as Map)['sqlSha256']
                    as String,
            localCreation: _detailsBaselineOriginRecord(
              detailsBaselineRecovery!,
              'localCreation',
            ),
          );
        } else {
          verifyJobDetailsNativeReadback(detailsCheckpoint!, actual);
        }
        writeOnce('join-details-cold-readback-$pid.json', {
          'detailsStage': pendingResume
              ? 'interrupted-pending-details'
              : baselineResume
              ? 'interrupted-baseline'
              : detailsCheckpoint!['detailsStage'],
          'beforeNearbyControllerCreated': true,
          'protectedBytesVerifiedBeforeSignIn':
              !baselineResume && !pendingResume,
          if (baselineResume || pendingResume) ...{
            'preKernelIdentityPathAndCreationSealVerified': true,
            'protectedHashesAreIndependentAnchor': false,
            'priorCommandOutcome': 'not adjudicated by recovery; original command evidence retained',
            'freshEpochAndPairRequired': true,
          },
          'productionJobsPanelRendered': true,
          'passed': false,
          ...actual,
        });
      }
      if (_jobNameMode) {
        final actual = await snapshot();
        final expected = interruptedResume
            ? recoveryManifest!
            : conflictResume
            ? conflictCheckpoint!
            : _readOwnedJson(
                File(p.join(workspace.root.path, 'join-exercise.json')),
              );
        if (interruptedResume) {
          verifyJoinNativeInterruptedReadback(expected, actual);
          _require(
            actual['receiptCountVerified'] == 2 &&
                actual['schema'] == 9 &&
                actual['integrityValid'] == true &&
                actual['referencesValid'] == true,
          );
          await verifyJoinNativeInterruptedAck(
            enrollment,
            adapterSession!,
            expected,
          );
          interruptedReadbackVerified = true;
        } else {
          verifyJoinNativeJobNameReadback(expected, actual);
        }
        if (conflictResume) conflictReadbackVerified = true;
        writeOnce(
          interruptedResume
              ? 'join-interrupted-cold-readback-$pid.json'
              : conflictResume
              ? 'join-conflict-cold-readback-$pid.json'
              : 'join-final-cold-readback-$pid.json',
          {
            if (interruptedResume) 'passed': false,
            if (recoveryManifest != null)
              'interruptedRecoverySha256': _recoveryManifestSha256,
            'stage': interruptedResume
                ? 'interrupted-two-name-readback'
                : conflictResume
                ? 'unresolved-conflict-readback'
                : 'resolved-exercise-readback',
            'beforeNearbyControllerCreated': true,
            'bothJobsRendered': true,
            'bothAttributedCandidatesRendered': conflictResume,
            ...actual,
          },
        );
      }
    }
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
                          if (_jobNameMode && _createdMode)
                            NativeTestAction.jobNameUi,
                          if (_detailsMode && _createdMode)
                            NativeTestAction.jobDetailsUi,
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
      requireBeforeEffect();
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
        waitUntilReady: waitForPassiveCompletion,
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
    _require(!_detailsMode);
    if (_jobNameMode) {
      _require(
        mayFinalizeCreatedJobNameStage(
          restart: restart,
          conflictResume: conflictResume,
          conflictReadbackVerified: conflictReadbackVerified,
          syncComplete: syncUiState == CreatedJobNativeUiState.complete,
          interruptedResume: interruptedResume,
        ),
      );
    } else {
      _require(restart || syncUiState == CreatedJobNativeUiState.complete);
    }
    await controller!.dispose();
    await enrollment.signOut();
    adapterSession = null;
    await mountGate();
    await signInUi();
    adapterSession = await tester.runAsync(() => enrollment.signIn(_pin));
    await assertCreatedJobsUi(2);
    final verified = await snapshot();
    _require(verified['receiptCountVerified'] == 2);
    if (_jobNameMode) {
      final baseline = _readOwnedJson(
        File(
          p.join(workspace.root.path, 'name-shared-baseline-$_roleName.json'),
        ),
      );
      _require(
        verified['nameOperationCount'] == 4 &&
            verified['nameReceiptCountVerified'] == 4 &&
            verified['nameAckCount'] == 4 &&
            verified['jobHistorySha256'] == baseline['creationHistorySha256'],
      );
      final names = (verified['nameViews'] as List)
          .cast<Map<String, Object?>>();
      final selected = names.singleWhere(
        (v) => v['job'] == baseline['selectedJob'],
      );
      _require(
        selected['hasConflict'] == false &&
            (selected['heads'] as List).length == 1 &&
            {
              _concurrentName(true),
              _concurrentName(false),
            }.contains(selected['resolvedName']),
      );
      _require(names.where((v) => (v['heads'] as List).isNotEmpty).length == 1);
    }
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
    writeOnce('join-$receiptPhase.json', {
      if (recoveryManifest != null)
        'interruptedRecoverySha256': _recoveryManifestSha256,
      ...evidence,
      'phase': receiptPhase,
      'passed': true,
      'locked': true,
      'createdJobsComplete': true,
      'productionMainNavigationTested': false,
      'productionJobsPanelRendered': true,
      'bothJobsRendered': true,
      'receiptCountVerifiedBeforeLock': 2,
      if (_jobNameMode) ...{
        'jobNamesComplete': true,
        'nameReceiptCountVerifiedBeforeLock':
            verified['nameReceiptCountVerified'],
        'nameReceiptCountVerified': verified['nameReceiptCountVerified'],
        'nameRecordsSha256': verified['nameRecordsSha256'],
        'nameAckSha256': verified['nameAckSha256'],
        'nameReceiptVerification': verified['nameReceiptVerification'],
        'ackVerification': verified['ackVerification'],
        'nameViews': verified['nameViews'],
        'identity': verified['identity'],
        'nameEvidence': {
          'phase': 'active-before-lock',
          'nameOperationCount': verified['nameOperationCount'],
          'nameReceiptCountVerified': verified['nameReceiptCountVerified'],
          'nameAckCount': verified['nameAckCount'],
          'nameRecordsSha256': verified['nameRecordsSha256'],
          'nameAckSha256': verified['nameAckSha256'],
          'nameReceiptVerification': verified['nameReceiptVerification'],
          'ackVerification': verified['ackVerification'],
          'nameViews': verified['nameViews'],
          'jobHistorySha256': verified['jobHistorySha256'],
          'identity': verified['identity'],
        },
        'nativeUnresolvedConflictColdRestart': conflictResume
            ? 'passed; exact unresolved hashes, identity, receipts and attributed candidates checked before controller creation'
            : 'not repeated during resolved-state final cold readback',
      },
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
        return performJoinNativePair(
          createdMode: _createdMode,
          finished: finished,
          phase: view.phase,
          peerCount: view.peers.length,
          tapPair: () => tap(
            find.byKey(
              ValueKey('company-join-pair-${view.peers.single.deviceId}'),
            ),
          ),
        );
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
          _require(
            mayStartCreatedJobNativeSync(
              owner: owner,
              jobNameMode: _jobNameMode || _detailsMode,
              syncEnabled: buttonEnabled('company-jobs-sync-now'),
            ),
          );
          requireBeforeEffect();
          syncStarts++;
          final syncPage = _pageState;
          await tap(find.byKey(const Key('company-jobs-sync-now')));
          return waitForCreatedJobNativeSyncTerminal(
            waitUntilReady: waitForPassiveCompletion,
            readState: () => syncUiState,
            isStillCurrent: () =>
                lifecycleCurrent() &&
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
            schemaVersion: _detailsMode
                ? 10
                : _createdMode
                ? 9
                : 7,
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
      case NativeTestAction.jobNameUi:
        return exerciseJobNameUi(command.jobNameStep!);
      case NativeTestAction.jobDetailsUi:
        return exerciseJobDetailsUi(command.jobDetailsStep!);
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
    _require(
      counts.length ==
          (_detailsMode
              ? 32
              : _createdMode
              ? 30
              : 27),
    );
    final schema = (await db.customSelect('PRAGMA user_version').getSingle())
        .data
        .values
        .single;
    _require(
      schema ==
          (_detailsMode
              ? 10
              : _createdMode
              ? 9
              : 7),
    );
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
        'syncDiagnostics': syncDiagnostics.snapshot,
        'interruptionStarts': interruptionStarts,
        'interruptionDrains': interruptionDrains,
        'sqlSha256': await sqlHash(),
        'snapshotSemantics': _detailsMode
            ? 'Scoped creation/name bytes, typed details receipts, per-field attributed alternatives and three distinct family ACKs; native process readback only'
            : _jobNameMode
            ? 'Scoped original creation bytes plus signed name edits, causal heads, attributed conflicts, local receipts and peer ACKs; no mesh, deletion, asset or general-copy assertion'
            : 'Scoped created-Job records, original bytes, local receipts and peer ACKs; no mesh, edit, deletion, asset or general-copy assertion',
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
        if (_jobNameMode || _detailsMode) {
          evidence.addAll(await nameHistoryEvidence());
        }
        if (_detailsMode) evidence.addAll(await detailsHistoryEvidence());
        final originalFile = File(
          p.join(workspace.root.path, 'created-local-job.json'),
        );
        if (originalFile.existsSync()) {
          final original = _readOwnedJson(originalFile);
          verifyJoinNativeEvidenceProvenance(
            original,
            revision: _revision,
            tree: _tree,
            adapter: _adapter,
            productRevision: productRevision,
            recoveryManifest: recoveryManifest ?? detailsBaselineRecovery,
          );
          _require(
            original['mode'] == 'created-jobs' &&
                original['run'] == _run &&
                original['role'] == _roleName &&
                original['namespace'] == namespace &&
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
        if (detailsBaselineRecovery != null) {
          _require(next.epoch != detailsBaselineRecovery!['retiredEpoch']);
        }
        if (detailsPendingRecovery != null) {
          _require(next.epoch != detailsPendingRecovery!['retiredEpoch']);
        }
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
  _require(!_jobNameMode || _createdMode);
  _require(
    !_detailsMode ||
        (_createdMode &&
            !_jobNameMode &&
            _recoveryManifestPath.isEmpty &&
            _recoveryManifestSha256.isEmpty),
  );
  _require(
    _detailsMode ||
        (_detailsManifestPath.isEmpty &&
            _detailsManifestSha256.isEmpty &&
            _detailsCheckpointPath.isEmpty &&
            _detailsCheckpointSha256.isEmpty &&
            _detailsBaselineRecoveryPath.isEmpty &&
            _detailsBaselineRecoverySha256.isEmpty &&
            _detailsPendingRecoveryPath.isEmpty &&
            _detailsPendingRecoverySha256.isEmpty),
  );
  validateJoinNativeDefines(
    enabled: _enabled,
    run: _run,
    role: _roleName,
    platform: Platform.operatingSystem,
    revision: _revision,
    tree: _tree,
    adapter: _adapter,
    createdMode: _createdMode,
    detailsMode: _detailsMode,
    productRevision: _createdMode
        ? _createdProductRevision
        : joinNativeProductRevision,
  );
  _require(
    kAppSchemaVersion ==
        (_detailsMode
            ? 10
            : _createdMode
            ? 9
            : 7),
  );
  if (_detailsMode) {
    validateJobDetailsNativeSourceManifest(
      manifest: File(_detailsManifestPath),
      manifestSha256: _detailsManifestSha256,
      revision: _revision,
      tree: _tree,
      adapter: _adapter,
      productRevision: _createdProductRevision,
    );
  }
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
      final admission = _detailsMode
          ? validateJobDetailsNativeRootAdmission(
              root,
              run: _run,
              role: _roleName,
              revision: _revision,
              tree: _tree,
              adapter: _adapter,
              productRevision: _createdProductRevision,
              manifestSha256: _detailsManifestSha256,
              checkpointPath: _detailsCheckpointPath,
              checkpointSha256: _detailsCheckpointSha256,
              baselineRecoveryPath: _detailsBaselineRecoveryPath,
              baselineRecoverySha256: _detailsBaselineRecoverySha256,
              pendingRecoveryPath: _detailsPendingRecoveryPath,
              pendingRecoverySha256: _detailsPendingRecoverySha256,
              sourceManifestPath: _detailsManifestPath,
            )
          : validateJoinNativeRootAdmission(
              root,
              run: _run,
              role: _roleName,
              revision: _revision,
              tree: _tree,
              adapter: _adapter,
              createdMode: _createdMode,
              jobNameMode: _jobNameMode,
              productRevision: _createdMode
                  ? _createdProductRevision
                  : joinNativeProductRevision,
              recoveryManifestPath: _recoveryManifestPath,
              recoveryManifestSha256: _recoveryManifestSha256,
            );
      final restart = admission.stage != JoinNativeRootStage.fresh;
      final conflictCheckpoint =
          admission.stage == JoinNativeRootStage.unresolvedConflict
          ? admission.conflictCheckpoint
          : null;
      final workspace = openedWorkspace = ValidationWorkspace.open(
        run: workspaceRun,
        role: role,
        requireExisting: restart,
      );
      final interruptedResume =
          admission.stage == JoinNativeRootStage.interruptedNames;
      if (interruptedResume) {
        verifyJoinNativeInterruptedFiles(root, admission.recoveryManifest!);
      }
      final namespace = joinNativeNamespace(
        _run,
        _roleName,
        createdMode: _createdMode,
        detailsMode: _detailsMode,
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
      if (admission.recoveryManifest != null || (_detailsMode && restart)) {
        await verifyJoinNativeRecoveryCustody(_nativeStore, namespace);
      }
      if (_detailsMode && admission.detailsCheckpoint != null) {
        final expected = admission.detailsCheckpoint!['detailsEvidence'] as Map;
        final base = (await _nativeStore.readState(namespace))!;
        final custody = (await _nativeStore.readState(
          companyCustodyNamespace(namespace),
        ))!;
        _require(
          base.revision == expected['baseProtectedRevision'] &&
              sha256.convert(base.bytes).toString() ==
                  expected['baseProtectedSha256'] &&
              custody.revision == expected['custodyProtectedRevision'] &&
              sha256.convert(custody.bytes).toString() ==
                  expected['custodyProtectedSha256'],
        );
      }
      final db = openedDb = AppDatabase.forTesting(
        _detailsMode && restart
            ? NativeDatabase.opened(
                raw.sqlite3.open(
                  p.join(workspace.support.path, kSqliteFileName),
                ),
                enableMigrations: false,
              )
            : NativeDatabase(
                File(p.join(workspace.support.path, kSqliteFileName)),
              ),
      );
      final security = InstallationSecurity(
        store: _nativeStore,
        namespace: namespace,
      );
      if (admission.recoveryManifest != null || (_detailsMode && restart)) {
        await verifyJoinNativeRecoveryBinding(db);
      }
      if (admission.stage == JoinNativeRootStage.interruptedDetailsBaseline ||
          admission.stage == JoinNativeRootStage.interruptedDetailsPending) {
        final pending = admission.detailsPendingRecovery;
        final recovery = pending ?? admission.detailsBaselineRecovery!;
        final expected = (recovery['evidence'] as Map).cast<String, Object?>();
        final localCreation = _detailsBaselineOriginRecord(
          admission.detailsBaselineRecovery!,
          'localCreation',
        );
        final binding = (await db.settingsDao.getSetting(
          kInstallationBindingKey,
        ))!;
        _require(
          sha256.convert(utf8.encode(binding)).toString() ==
              expected['bindingSha256'],
        );
        final incoming = (await db.select(db.companyJobs).get())
            .where((row) => !row.outgoing)
            .map((row) => row.operationCommitment)
            .toSet();
        final observation = pending == null
            ? await verifyDetailsBaselineNativeHeaders(
                base: await _nativeStore.readState(namespace),
                custody: await _nativeStore.readState(
                  companyCustodyNamespace(namespace),
                ),
                binding: binding,
                databasePath: p.join(workspace.support.path, kSqliteFileName),
                originalIdentity: (expected['identity'] as Map)
                    .cast<String, Object?>(),
                originalReceipt:
                    (localCreation['record'] as Map)['receiptBytes'] as String,
                incomingOperations: incoming,
              )
            : await verifyDetailsPendingNativeHeaders(
                db: db,
                base: await _nativeStore.readState(namespace),
                custody: await _nativeStore.readState(
                  companyCustodyNamespace(namespace),
                ),
                binding: binding,
                databasePath: p.join(workspace.support.path, kSqliteFileName),
                originalIdentity: (expected['identity'] as Map)
                    .cast<String, Object?>(),
                originalReceipt:
                    (localCreation['record'] as Map)['receiptBytes'] as String,
                incomingOperations: incoming,
              );
        final observationFile = File(
          p.join(root.path, 'join-details-baseline-pre-kernel-$pid.json'),
        );
        observationFile.createSync(exclusive: true);
        observationFile.writeAsStringSync(
          jsonEncode({
            'format': 1,
            'run': _run,
            'role': _roleName,
            'sourceRevision': _revision,
            'detailsBaselineRecoverySha256': _detailsBaselineRecoverySha256,
            if (pending != null)
              'detailsPendingRecoverySha256': _detailsPendingRecoverySha256,
            'beforeProductionReconcile': true,
            ...observation,
          }),
          flush: true,
        );
      }
      await security.start(db);
      _require(security.readiness == InstallationReadiness.ready);
      if (!restart) workspace.markInitialized();
      resident = _JoinNative(
        tester,
        workspace,
        db,
        security,
        restart,
        conflictCheckpoint,
        admission.recoveryManifest,
        interruptedResume,
        admission.detailsCheckpoint,
        admission.detailsBaselineRecovery,
        admission.detailsPendingRecovery,
      );
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
