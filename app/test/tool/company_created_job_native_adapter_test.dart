import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/features/company/company_gate.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/company/company_join_page.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_commands.dart';
import '../../tool/native_nearby_test_crypto.dart' show NativeTestFailure;
import 'native_nearby_test_commands_test.dart' as command_test show Fixture;
import '../features/company/company_join_test.dart'
    show JoinFixture, JoinTestDiscovery, activateFixtureB;
import '../features/company/company_created_job_sync_test.dart'
    show openSyncPair;
import '../features/company/company_join_widget_test.dart'
    show joinWidgetSignal;

final _revision = List.filled(40, 'a').join();
final _tree = List.filled(40, 'b').join();
final _adapterHash = List.filled(64, 'c').join();

final class _LoopbackHttpOverrides extends HttpOverrides {}

final class _InterruptedFixture {
  _InterruptedFixture() {
    parent = Directory(
      Directory.systemTemp
          .createTempSync('j61-interrupted-')
          .resolveSymbolicLinksSync(),
    );
    root = Directory(p.join(parent.path, 'fixture'))..createSync();
    manifestFile = File(p.join(parent.path, 'recovery.json'));
    addTearDown(() => parent.deleteSync(recursive: true));
    final header = <String, Object?>{
      'format': 1,
      'run': adapter.createdJobNativeRun,
      'role': 'owner',
      'root': root.path,
      'namespace': namespace,
      'mode': 'created-jobs',
      'jobNameMode': true,
      'sourceRevision': origin['revision'],
      'sourceTree': origin['tree'],
      'adapterSha256': origin['adapterSha256'],
      'productRevision': origin['productRevision'],
    };
    final views = <Map<String, Object?>>[
      {
        'job': job,
        'creationDigest': 'f' * 64,
        'heads': [local],
        'displayName':
            'Synthetic owner concurrent name ${adapter.createdJobNativeRun}',
        'resolvedName':
            'Synthetic owner concurrent name ${adapter.createdJobNativeRun}',
        'lastAgreedName': 'Original',
        'hasConflict': false,
        'candidates': [
          {
            'operation': local,
            'name':
                'Synthetic owner concurrent name ${adapter.createdJobNativeRun}',
            'user': identity['user'],
            'device': identity['device'],
          },
        ],
      },
      {'job': 'other-job', 'hasConflict': false, 'heads': [], 'candidates': []},
    ];
    evidence = <String, Object?>{
      'identity': identity,
      'peerIdentity': peerIdentity,
      'selectedJob': job,
      'creationDigest': 'f' * 64,
      'jobHistorySha256': '1' * 64,
      'nameOperationCount': 2,
      'nameReceiptCountVerified': 2,
      'nameAckCount': 1,
      'nameRecordsSha256': '2' * 64,
      'nameAckSha256': '3' * 64,
      'nameViews': views,
      'sequentialOperation': sequential,
      'localOperation': local,
    };
    records = [
      {
        'job': job,
        'operation': sequential,
        'parents': <String>[],
        'creationDigest': 'f' * 64,
        'originalUser': identity['user'],
        'originalDevice': identity['device'],
        'name': 'Synthetic sequential name ${adapter.createdJobNativeRun}',
      },
      {
        'job': job,
        'operation': local,
        'parents': [sequential],
        'creationDigest': 'f' * 64,
        'originalUser': identity['user'],
        'originalDevice': identity['device'],
        'name':
            'Synthetic owner concurrent name ${adapter.createdJobNativeRun}',
      },
    ];
    write('name-shared-baseline-owner.json', {
      ...header,
      'selectedJob': job,
      'creationDigest': 'f' * 64,
      'creationHistorySha256': '1' * 64,
    });
    write('name-ui-exercise-1-24.json', {
      ...header,
      ...evidence,
      'step': 'renameConcurrent',
      'observedHeadsBefore': [sequential],
      'originalCreationBytesUnchanged': true,
      'savedThroughProductionUi': true,
      'companyControllerStoppedDuringUi': true,
      'nameRecords': records,
      'nameReceiptVerification': 'typed-public-verifier',
      'creationHistorySha256': '1' * 64,
    });
    write('join-exercise-snapshot-1-6.json', {
      ...header,
      'identity': identity,
      'nameOperationCount': 1,
      'nameReceiptCountVerified': 1,
      'nameAckCount': 1,
      'nameReceiptVerification': 'typed-public-verifier',
      'ackVerification': 'confirmedPeerCounts',
      'nameAckSha256': '3' * 64,
    });
    write('created-local-job.json', {...header, 'identity': identity});
    write('validation-owner.json', {
      'format': 1,
      'run': 'company-${adapter.createdJobNativeRun}',
      'role': 'sender',
      'root': root.path,
      'initialized': true,
    });
    Directory(p.join(root.path, 'support')).createSync();
    File(p.join(root.path, 'support', 'wired_parts.sqlite'))
        .writeAsBytesSync([1, 2, 3]);
    manifest = <String, Object?>{
      'format': 1,
      'kind': 'j61.interrupted-names.recovery@1',
      'run': adapter.createdJobNativeRun,
      'role': 'owner',
      'root': root.path,
      'namespace': namespace,
      'origin': origin,
      'recovery': {
        'revision': _revision,
        'tree': _tree,
        'adapterSha256': _adapterHash,
        'productRevision': _revision,
      },
      'productFiles': adapter.joinNativeInterruptedProductHashes.entries
          .map(
            (e) => {
              'path': e.key,
              'originLfSha256': e.value,
              'recoveryLfSha256': e.value,
            },
          )
          .toList(),
      'files': root
          .listSync(recursive: true)
          .whereType<File>()
          .map(
            (f) => {
              'path': p.relative(f.path, from: root.path).replaceAll('\\', '/'),
              'bytes': f.lengthSync(),
              'sha256': hashes.sha256.convert(f.readAsBytesSync()).toString(),
            },
          )
          .toList(),
      'originFiles': {
        'baseline': 'name-shared-baseline-owner.json',
        'nameUi': 'name-ui-exercise-1-24.json',
        'priorSnapshot': 'join-exercise-snapshot-1-6.json',
        'localCreation': 'created-local-job.json',
      },
      'evidence': evidence,
    };
    saveManifest();
  }
  late final Directory parent, root;
  late final File manifestFile;
  late final Map<String, Object?> manifest, evidence;
  late final List<Map<String, Object?>> records;
  static final sequential = 'd' * 64, local = 'e' * 64;
  static const job = 'selected-job';
  static final identity = {
    for (final key in [
      'installation',
      'generation',
      'publicKeySha256',
      'storeGeneration',
      'company',
      'shop',
      'user',
      'device',
    ])
      key: key == 'publicKeySha256' ? 'a' * 64 : 'own-$key',
  };
  static final peerIdentity = {
    ...identity,
    'installation': 'peer-installation',
    'generation': 'peer-generation',
    'storeGeneration': 'peer-store',
    'device': 'peer-device',
    'user': identity['user']!,
    'publicKeySha256': 'b' * 64,
  };
  static final origin = <String, Object?>{
    'revision': '079baa5b7982a2c1fef1b7b165773cfa73dc5e83',
    'tree': 'dd529f9b145c15d52fb46a1e0548f3c234580870',
    'adapterSha256':
        'c7cd5a3438685b81d0d44f90e03e2bd50c52a6c44947d4b75334d0bf42b896d1',
    'productRevision': '079baa5b7982a2c1fef1b7b165773cfa73dc5e83',
  };
  String get namespace => adapter.joinNativeNamespace(
    adapter.createdJobNativeRun,
    'owner',
    createdMode: true,
  );
  void write(String path, Object value) =>
      File(p.join(root.path, path)).writeAsStringSync(jsonEncode(value));
  void saveManifest() => manifestFile.writeAsStringSync(jsonEncode(manifest));
  String get digest =>
      hashes.sha256.convert(manifestFile.readAsBytesSync()).toString();
  adapter.JoinNativeRootAdmission admit({
    bool enabled = true,
    String? digest,
  }) => adapter.validateJoinNativeRootAdmission(
    root,
    run: adapter.createdJobNativeRun,
    role: 'owner',
    revision: _revision,
    tree: _tree,
    adapter: _adapterHash,
    productRevision: _revision,
    createdMode: true,
    jobNameMode: true,
    recoveryManifestPath: enabled ? manifestFile.path : '',
    recoveryManifestSha256: enabled ? digest ?? this.digest : '',
  );
}

final class _HeldStopDiscovery implements NearbyDiscovery {
  final delegate = JoinTestDiscovery();
  final entered = Completer<void>();
  final release = Completer<void>();
  bool hold = false;
  @override
  Stream<List<NearbyPeer>> get peers => delegate.peers;
  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) => delegate.start(deviceId: deviceId, name: name, port: port, ips: ips);
  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) => delegate.updateAdvertisement(name: name, port: port, ips: ips);
  @override
  Future<void> stop() async {
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await delegate.stop();
  }
}

Future<NativeTestCommandReply> _settleNativeCommand(
  command_test.Fixture cache,
  NativeTestCommand command,
  Future<NativeTestCommandResult> operation,
) async {
  try {
    return cache.cache.complete(command, await operation);
  } on adapter.CreatedJobNativeTerminalFailure catch (failure) {
    return cache.cache.fail(
      command,
      failure.error,
      effect: NativeTestEffect.completed,
    );
  } catch (_) {
    return cache.cache.fail(
      command,
      NativeTestCommandError.harnessFailed,
      effect: NativeTestEffect.possible,
    );
  }
}

void _validate({
  bool createdMode = true,
  String? run,
  String? revision,
  String? productRevision,
  String role = 'owner',
  String platform = 'windows',
}) => adapter.validateJoinNativeDefines(
  enabled: true,
  run: run ?? adapter.createdJobNativeRun,
  role: role,
  platform: platform,
  revision: revision ?? _revision,
  tree: _tree,
  adapter: _adapterHash,
  createdMode: createdMode,
  productRevision: productRevision ?? _revision,
);

void main() {
  test(
    'interrupted V19 exact opt-in admits verification without completion',
    () {
      final f = _InterruptedFixture();
      expect(f.admit().stage.name, 'interruptedNames');
      expect(() => f.admit(enabled: false), throwsA(anything));
      expect(
        File(p.join(f.root.path, 'join-exercise.json')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(f.root.path, 'join-name-conflict.json')).existsSync(),
        isFalse,
      );
    },
  );
  test(
    'interrupted manifest rejects pins, provenance, products and file changes',
    () {
      final f = _InterruptedFixture();
      expect(() => f.admit(digest: '0' * 64), throwsA(anything));
      final original = jsonEncode(f.manifest);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (m) => m['role'] = 'member',
        (m) => (m['origin'] as Map)['revision'] = _revision,
        (m) => (m['recovery'] as Map)['adapterSha256'] = '0' * 64,
        (m) => ((m['productFiles'] as List).first as Map)['recoveryLfSha256'] =
            '0' * 64,
        (m) => (m['productFiles'] as List).removeLast(),
        (m) => ((m['files'] as List).first as Map)['path'] = '../escape',
        (m) => (m['evidence'] as Map)['nameOperationCount'] = 3,
        (m) => ((m['evidence'] as Map)['peerIdentity'] as Map)['user'] =
            'wrong-user',
        (m) => m['secret'] = 'forbidden-extra-field',
      ]) {
        final changed = jsonDecode(original) as Map<String, dynamic>;
        mutate(changed);
        f.manifestFile.writeAsStringSync(jsonEncode(changed));
        expect(() => f.admit(), throwsA(anything));
      }
      f.manifestFile.writeAsStringSync(original);
      final admitted = f.admit();
      File(p.join(f.root.path, 'support', 'wired_parts.sqlite'))
          .writeAsBytesSync([4, 5, 6]);
      expect(() => f.admit(), throwsA(anything));
      expect(
        () => adapter.verifyJoinNativeInterruptedFiles(
          f.root,
          admitted.recoveryManifest!,
        ),
        throwsA(anything),
      );
      File(p.join(f.root.path, 'support', 'wired_parts.sqlite'))
          .writeAsBytesSync([1, 2, 3]);
      f.write('unexpected.json', {'unapproved': true});
      expect(() => f.admit(), throwsA(anything));
    },
  );
  test('interrupted readback rejects identity, typed counts, ACK and graph mismatch', () {
    final f = _InterruptedFixture();
    final manifest = Map<String, dynamic>.from(f.manifest);
    final actual = <String, Object?>{
      ...f.evidence,
      'nameReceiptVerification': 'typed-public-verifier',
      'ackVerification': 'confirmedPeerCounts',
      'nameRecords': f.records,
    };
    adapter.verifyJoinNativeInterruptedReadback(manifest, actual);
    final original = jsonEncode(actual);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (m) => (m['identity'] as Map)['installation'] = 'changed',
      (m) => m['jobHistorySha256'] = '0' * 64,
      (m) => m['nameReceiptCountVerified'] = 1,
      (m) => m['nameAckCount'] = 0,
      (m) => m['ackVerification'] = null,
      (m) => ((m['nameRecords'] as List).last as Map)['parents'] = ['0' * 64],
    ]) {
      final changed = jsonDecode(original) as Map<String, dynamic>;
      mutate(changed);
      expect(
        () => adapter.verifyJoinNativeInterruptedReadback(manifest, changed),
        throwsA(anything),
      );
    }
  });
  test('recovery preserves original creation provenance and only permits real checkpoint', () {
    final f = _InterruptedFixture();
    final oldHeader = jsonDecode(
      File(p.join(f.root.path, 'created-local-job.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    void verify({bool recovery = true}) =>
        adapter.verifyJoinNativeEvidenceProvenance(
          oldHeader,
          revision: _revision,
          tree: _tree,
          adapter: _adapterHash,
          productRevision: _revision,
          recoveryManifest: recovery
              ? Map<String, dynamic>.from(f.manifest)
              : null,
        );
    verify();
    expect(() => verify(recovery: false), throwsA(anything));
    for (final step in NativeJobNameUiStep.values) {
      expect(
        adapter.mayExerciseCreatedJobNameUi(
          restart: true,
          conflictResume: false,
          interruptedResume: true,
          interruptedReadbackVerified: true,
          step: step,
        ),
        step == NativeJobNameUiStep.checkpointConflict,
      );
    }
    expect(
      adapter.mayExerciseCreatedJobNameUi(
        restart: true,
        conflictResume: false,
        interruptedResume: true,
        interruptedReadbackVerified: false,
        step: NativeJobNameUiStep.checkpointConflict,
      ),
      isFalse,
    );
    expect(
      adapter.mayFinalizeCreatedJobNameStage(
        restart: true,
        conflictResume: false,
        conflictReadbackVerified: false,
        syncComplete: true,
        interruptedResume: true,
      ),
      isFalse,
    );
  });
  test('interrupted cold checkpoint retains pinned origin context', () {
    final f = _InterruptedFixture();
    final identity = _InterruptedFixture.identity;
    final conflictViews = [
      {
        'job': 'selected-job',
        'hasConflict': true,
        'heads': ['A', 'B'],
        'candidates': [
          {'operation': 'A', 'name': 'A', 'user': 'u', 'device': 'a'},
          {'operation': 'B', 'name': 'B', 'user': 'u', 'device': 'b'},
        ],
      },
      {'job': 'other-job', 'hasConflict': false, 'heads': [], 'candidates': []},
    ];
    f.write('join-name-conflict.json', {
      'format': 1,
      'stage': 'unresolved-name-conflict',
      'passed': false,
      'run': adapter.createdJobNativeRun,
      'role': 'owner',
      'root': f.root.path,
      'namespace': f.namespace,
      'sourceRevision': _revision,
      'sourceTree': _tree,
      'adapterSha256': _adapterHash,
      'productRevision': _revision,
      'mode': 'created-jobs',
      'schema': 9,
      'jobNameMode': true,
      'createdJobsComplete': false,
      'jobNamesComplete': false,
      'locked': true,
      'syncCompleted': true,
      'syncStarts': 1,
      'nearbyControllerRunning': false,
      'productionJobsPanelRendered': true,
      'bothAttributedCandidatesRendered': true,
      'lockedSqlSha256': '4' * 64,
      'identity': identity,
      'interruptedRecoverySha256': f.digest,
      'nameEvidence': {
        'nameOperationCount': 3,
        'nameReceiptCountVerified': 3,
        'nameAckCount': 3,
        'jobHistorySha256': '1' * 64,
        'nameRecordsSha256': '2' * 64,
        'nameAckSha256': '3' * 64,
        'nameReceiptVerification': 'typed-public-verifier',
        'ackVerification': 'confirmedPeerCounts',
        'nameViews': conflictViews,
      },
    });
    final admitted = f.admit();
    expect(admitted.stage, adapter.JoinNativeRootStage.unresolvedConflict);
    expect(admitted.recoveryManifest, isNotNull);
    expect(() => f.admit(enabled: false), throwsA(anything));
  });
  test(
    'interrupted ACK verifier binds real receipt peer key store and signature',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final f = await JoinFixture.create(allowOwnerAdditions: true);
      await activateFixtureB(f);
      final pair = await openSyncPair(f);
      try {
        expect((await pair.a.syncNow()).complete, isTrue);
        final commands = CompanyJobCommands(enrollment: f.aEnrollment);
        final view = (await commands.listJobViews(ownerSession: f.owner))
            .single;
        final receipt = await commands.renameJob(
          RenameJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: view.baseJob.id,
            requestId: '10000000-0000-4000-8000-000000000001',
            creationDigest: view.creationDigest,
            observedHeads: [],
            name: 'Sequential',
          ),
          ownerSession: f.owner,
        );
        expect((await pair.a.syncNow()).complete, isTrue);
        final bo = pair.ownerB;
        await commands.renameJob(
          RenameJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: view.baseJob.id,
            requestId: '10000000-0000-4000-8000-000000000002',
            creationDigest: view.creationDigest,
            observedHeads: [receipt.operationId],
            name: 'Unacknowledged concurrent name',
          ),
          ownerSession: f.owner,
        );
        expect(
          await commands.nameSyncHoldings(ownerSession: f.owner),
          hasLength(2),
        );
        expect(
          (await CompanyCreatedJobSync.confirmedPeerCounts(
            f.aEnrollment,
            f.owner,
          ))[view.baseJob.id],
          0,
        );
        final peer = <String, Object?>{
          'device': bo.identity.deviceId,
          'user': bo.identity.userId,
          'installation': f.b.identity!.id.value,
          'generation': f.b.identity!.generation.value,
          'storeGeneration': f.b.receivingStoreGeneration!.value,
          'publicKeySha256': hashes.sha256
              .convert(f.b.identity!.publicKey)
              .toString(),
        };
        Map<String, dynamic> manifest(Map<String, Object?> p) => {
          'evidence': {
            'peerIdentity': p,
            'sequentialOperation': receipt.operationId,
          },
        };
        await adapter.verifyJoinNativeInterruptedAck(
          f.aEnrollment,
          f.owner,
          manifest(peer),
        );
        for (final key in ['publicKeySha256', 'user', 'storeGeneration']) {
          await expectLater(
            adapter.verifyJoinNativeInterruptedAck(
              f.aEnrollment,
              f.owner,
              manifest({...peer, key: 'wrong'}),
            ),
            throwsA(anything),
          );
        }
        await adapter.verifyJoinNativeRecoveryCustody(f.aStore, f.a.namespace);
        final state = f.aStore.states.remove(f.a.namespace)!;
        await expectLater(
          adapter.verifyJoinNativeRecoveryCustody(f.aStore, f.a.namespace),
          throwsA(anything),
        );
        f.aStore.states[f.a.namespace] = state;
        await adapter.verifyJoinNativeRecoveryBinding(f.aDb);
        final original =
            (await f.aDb.select(f.aDb.companyJobNamePeerAcks).get()).single;
        final signed = jsonDecode(original.ackBytes) as Map<String, dynamic>;
        signed['signature'] = base64Encode(List.filled(64, 0));
        await f.aDb.customStatement(
          'UPDATE company_job_name_peer_acks SET ack_bytes = ?',
          [jsonEncode(signed)],
        );
        await expectLater(
          adapter.verifyJoinNativeInterruptedAck(
            f.aEnrollment,
            f.owner,
            manifest(peer),
          ),
          throwsA(anything),
        );
        await f.aDb.customStatement(
          'UPDATE company_job_name_peer_acks SET ack_bytes = ?',
          [original.ackBytes],
        );
      } finally {
        await pair.a.closeAndDrain();
        await pair.b.closeAndDrain();
      }
    }, _LoopbackHttpOverrides()),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'Job-name native sync admits either enrolled role only with enabled UI',
    () {
      expect(
        adapter.mayStartCreatedJobNativeSync(
          owner: false,
          jobNameMode: true,
          syncEnabled: true,
        ),
        isTrue,
      );
      expect(
        adapter.mayStartCreatedJobNativeSync(
          owner: false,
          jobNameMode: false,
          syncEnabled: true,
        ),
        isFalse,
      );
      expect(
        adapter.mayStartCreatedJobNativeSync(
          owner: true,
          jobNameMode: false,
          syncEnabled: true,
        ),
        isTrue,
      );
      for (final owner in [false, true]) {
        for (final jobNameMode in [false, true]) {
          expect(
            adapter.mayStartCreatedJobNativeSync(
              owner: owner,
              jobNameMode: jobNameMode,
              syncEnabled: false,
            ),
            isFalse,
          );
        }
      }
    },
  );
  test('native diagnostic retention and evidence writes stay bounded across remounts', () {
    final diagnostics = adapter.CreatedJobNativeSyncDiagnostics();
    var writes = 0;
    for (var i = 0; i < 35; i++) {
      if (diagnostics.observe(
        const CreatedJobSyncDiagnostic.terminal(
          CreatedJobSyncResult(0, 0, false, 0),
        ),
      )) {
        writes++;
      }
    }
    expect(writes, 32);
    expect(diagnostics.snapshot['terminals'], hasLength(32));
    expect(diagnostics.snapshot['droppedTerminals'], 3);
    expect(diagnostics.snapshot['evidenceWriteAttempts'], 32);
    expect(diagnostics.snapshot['droppedEvidence'], 3);
    diagnostics.resetAttempt();
    expect(
      diagnostics.observe(const CreatedJobSyncDiagnostic.receiverEntered()),
      isFalse,
    );
    expect(diagnostics.snapshot['evidenceWriteAttempts'], 32);
    expect(diagnostics.snapshot['droppedEvidence'], 4);
  });
  test(
    'native terminal capture survives remount and resets the next attempt',
    () {
      final diagnostics = adapter.CreatedJobNativeSyncDiagnostics();
      const failure = CreatedJobSyncResult(
        0,
        0,
        false,
        0,
        failure: CreatedJobSyncFailure(
          CreatedJobSyncStage.preflight,
          CreatedJobSyncReason.unavailable,
        ),
      );
      diagnostics.observe(const CreatedJobSyncDiagnostic.started());
      diagnostics.observe(const CreatedJobSyncDiagnostic.terminal(failure));
      final terminal = diagnostics.snapshot;
      expect(terminal['receiverCallbackReached'], isFalse);
      expect(terminal['failureStage'], 'preflight');
      expect(terminal['failureReason'], 'unavailable');
      diagnostics.resetAttempt();
      expect(diagnostics.snapshot['terminalObserved'], isFalse);
      expect(diagnostics.snapshot['receiverCallbackReached'], isFalse);
      expect((diagnostics.snapshot['terminals'] as List).single, {
        'receiverCallbackReached': false,
        'terminalObserved': true,
        'complete': false,
        'sent': 0,
        'received': 0,
        'unsupported': 0,
        'failureStage': 'preflight',
        'failureReason': 'unavailable',
      });
      expect(
        diagnostics.observe(const CreatedJobSyncDiagnostic.receiverEntered()),
        isTrue,
      );
      expect(diagnostics.snapshot['receiverCallbackReached'], isTrue);
      diagnostics.observe(
        const CreatedJobSyncDiagnostic.started(receiverCallbackReached: true),
      );
      diagnostics.observe(
        const CreatedJobSyncDiagnostic.terminal(
          CreatedJobSyncResult(0, 1, true, 0),
          receiverCallbackReached: true,
        ),
      );
      expect(diagnostics.snapshot['complete'], isTrue);
      expect(diagnostics.snapshot['failureReason'], isNull);
      expect(diagnostics.snapshot['receiverCallbackReached'], isTrue);
      diagnostics.observe(const CreatedJobSyncDiagnostic.started());
      expect(diagnostics.snapshot['terminalObserved'], isFalse);
      expect(diagnostics.snapshot['receiverCallbackReached'], isFalse);
      expect(diagnostics.snapshot['terminals'], hasLength(2));
      expect(jsonEncode(terminal), contains('unavailable'));
    },
  );
  for (final beforeEffect in [false, true]) {
    test(
      'native readiness keeps ${beforeEffect ? 'effect deadline' : 'three-minute passive bound'}',
      () async {
        var elapsed = 0;
        var pumps = 0;
        await expectLater(
          adapter.waitForJoinNativeCompletion(
            ready: () => false,
            elapsedMillis: () => elapsed,
            commandDeadlineMillis: 15000,
            enforceCommandDeadline: beforeEffect,
            pump: () async {
              pumps++;
              elapsed = beforeEffect ? 15000 : 180000;
            },
          ),
          throwsA(anything),
        );
        expect(pumps, 1);
        expect(elapsed, beforeEffect ? 15000 : 180000);
      },
    );
  }
  testWidgets(
    'stale disabled Sync Now is not busy without actual busy indicator',
    (tester) async {
      Widget page({required bool busy}) => MaterialApp(
        home: Column(
          children: [
            const FilledButton(
              key: Key('company-jobs-sync-now'),
              onPressed: null,
              child: Text('Sync Now'),
            ),
            if (busy)
              const CircularProgressIndicator(key: Key('company-join-busy')),
          ],
        ),
      );
      await tester.pumpWidget(page(busy: false));
      expect(adapter.createdJobNativeUiBusy(), isFalse);
      expect(
        adapter.createdJobNativeUiState(
          status: 'Job snapshot synced. Sent 1, received 1.',
          errorVisible: false,
          busy: adapter.createdJobNativeUiBusy(),
        ),
        adapter.CreatedJobNativeUiState.complete,
      );
      await tester.pumpWidget(page(busy: true));
      expect(adapter.createdJobNativeUiBusy(), isTrue);
      expect(
        adapter.createdJobNativeUiState(
          status: 'Job snapshot synced. Sent 1, received 1.',
          errorVisible: false,
          busy: adapter.createdJobNativeUiBusy(),
        ),
        adapter.CreatedJobNativeUiState.pending,
      );
    },
  );
  test(
    'admitted Sync resolves original UNKNOWN command after late terminal UI',
    () async {
      final cache = command_test.Fixture();
      final wire = cache.request(
        1,
        action: NativeTestAction.accept,
        deadline: 15000,
      );
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var state = adapter.CreatedJobNativeUiState.pending;
      var pumps = 0;
      var taps = 0;
      adapter.validateJoinNativeDeadline(cache.now, command.deadlineMillis);
      taps++;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.waitForCreatedJobNativeSyncTerminal(
          waitUntilReady: (ready) => adapter.waitForJoinNativeCompletion(
            ready: ready,
            elapsedMillis: () => cache.now,
            commandDeadlineMillis: command.deadlineMillis,
            pump: () async {
              pumps++;
              if (pumps == 1) {
                cache.now = 15000;
                expect(
                  cache.cache.submitJson(wire).state,
                  NativeTestCommandState.unknown,
                );
                expect(cache.cache.takeNext(), isNull);
                expect(
                  cache.cache
                      .submitJson(cache.request(2, deadline: 30000))
                      .error,
                  NativeTestCommandError.busy,
                );
                expect(taps, 1);
              } else {
                cache.now = 15001;
                state = adapter.CreatedJobNativeUiState.complete;
              }
            },
          ),
          readState: () => state,
          isStillCurrent: () => true,
        ),
      );
      expect(reply.state, NativeTestCommandState.completed);
      expect(reply.effect, NativeTestEffect.completed);
      expect(pumps, 2);
      expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
      expect(cache.cache.takeNext(), isNull);
      expect(taps, 1);
      expect(
        () => adapter.validateJoinNativeDeadline(
          cache.now,
          command.deadlineMillis,
        ),
        throwsA(anything),
      );
      final expiredNew = cache.cache.submitJson(
        cache.request(
          2,
          action: NativeTestAction.accept,
          deadline: command.deadlineMillis,
        ),
      );
      expect(expiredNew.state, NativeTestCommandState.failed);
      expect(expiredNew.error, NativeTestCommandError.deadlineExpired);
      expect(cache.cache.takeNext(), isNull);
      expect(taps, 1);
    },
  );
  test(
    'admitted Close resolves original UNKNOWN command only after late drain',
    () async {
      final cache = command_test.Fixture();
      final wire = cache.request(
        1,
        action: NativeTestAction.finish,
        deadline: 15000,
      );
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var drained = false;
      var pumps = 0;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.waitForCreatedJobNativeCloseDrain(
          waitUntilReady: (ready) => adapter.waitForJoinNativeCompletion(
            ready: ready,
            elapsedMillis: () => cache.now,
            commandDeadlineMillis: command.deadlineMillis,
            pump: () async {
              pumps++;
              cache.now = pumps == 1 ? 15000 : 15001;
              if (pumps == 1) {
                expect(
                  cache.cache.submitJson(wire).state,
                  NativeTestCommandState.unknown,
                );
                expect(cache.cache.takeNext(), isNull);
                expect(
                  cache.cache
                      .submitJson(cache.request(2, deadline: 30000))
                      .error,
                  NativeTestCommandError.busy,
                );
              } else {
                drained = true;
              }
            },
          ),
          isDrained: () => drained,
        ),
      );
      expect(reply.state, NativeTestCommandState.completed);
      expect(reply.effect, NativeTestEffect.completed);
      expect(pumps, 2);
      expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
      expect(cache.cache.takeNext(), isNull);
    },
  );
  test('created native Pair retries failed state once through cache', () async {
    final cache = command_test.Fixture();
    final wire = cache.request(1, action: NativeTestAction.pair);
    cache.cache.submitJson(wire);
    final command = cache.cache.takeNext()!;
    var taps = 0;
    final reply = await _settleNativeCommand(
      cache,
      command,
      adapter.performJoinNativePair(
        createdMode: true,
        finished: false,
        phase: NearbyPhase.failed,
        peerCount: 1,
        tapPair: () async {
          taps++;
        },
      ),
    );
    expect(reply.state, NativeTestCommandState.completed);
    expect(reply.effect, NativeTestEffect.completed);
    expect(taps, 1);
    expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
    expect(cache.cache.takeNext(), isNull);
    expect(taps, 1);
  });
  test('native Pair preserves looking behavior in both modes', () async {
    for (final createdMode in [false, true]) {
      var taps = 0;
      final result = await adapter.performJoinNativePair(
        createdMode: createdMode,
        finished: false,
        phase: NearbyPhase.looking,
        peerCount: 1,
        tapPair: () async {
          taps++;
        },
      );
      expect(result.effect, NativeTestEffect.completed);
      expect(taps, 1);
    }
  });
  test('native Pair refuses legacy failure and other inactive boundary shapes before tapping', () async {
    final refused = [
      (created: false, finished: false, phase: NearbyPhase.failed, peers: 1),
      for (final created in [false, true])
        for (final phase in NearbyPhase.values)
          if (phase != NearbyPhase.looking && phase != NearbyPhase.failed)
            (created: created, finished: false, phase: phase, peers: 1),
      (created: true, finished: true, phase: NearbyPhase.failed, peers: 1),
      (created: true, finished: false, phase: NearbyPhase.failed, peers: 0),
      (created: true, finished: false, phase: NearbyPhase.failed, peers: 2),
    ];
    for (final input in refused) {
      final cache = command_test.Fixture();
      final wire = cache.request(1, action: NativeTestAction.pair);
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var taps = 0;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.performJoinNativePair(
          createdMode: input.created,
          finished: input.finished,
          phase: input.phase,
          peerCount: input.peers,
          tapPair: () async {
            taps++;
          },
        ),
      );
      expect(reply.state, NativeTestCommandState.failed, reason: '$input');
      expect(reply.effect, NativeTestEffect.possible);
      expect(taps, 0, reason: '$input');
    }
  });
  for (final terminal in [
    adapter.CreatedJobNativeUiState.complete,
    adapter.CreatedJobNativeUiState.incomplete,
    adapter.CreatedJobNativeUiState.error,
  ]) {
    test(
      'native Sync cache stays running until terminal ${terminal.name}',
      () async {
        final cache = command_test.Fixture();
        final wire = cache.request(1, action: NativeTestAction.accept);
        cache.cache.submitJson(wire);
        final command = cache.cache.takeNext()!;
        var state = adapter.CreatedJobNativeUiState.pending;
        bool Function()? ready;
        final waited = Completer<void>();
        var settled = false;
        final result =
            _settleNativeCommand(
              cache,
              command,
              adapter.waitForCreatedJobNativeSyncTerminal(
                waitUntilReady: (predicate) {
                  ready = predicate;
                  return waited.future;
                },
                readState: () => state,
                isStillCurrent: () => true,
              ),
            ).then((reply) {
              settled = true;
              return reply;
            });
        await Future<void>.value();
        expect(settled, isFalse);
        expect(ready!(), isFalse);
        expect(
          cache.cache.submitJson(wire).state,
          NativeTestCommandState.running,
        );
        expect(cache.cache.takeNext(), isNull);
        expect(
          cache.cache.submitJson(cache.request(2)).error,
          NativeTestCommandError.busy,
        );
        state = terminal;
        expect(ready!(), isTrue);
        waited.complete();
        final reply = await result;
        expect(reply.effect, NativeTestEffect.completed);
        expect(
          reply.state,
          terminal == adapter.CreatedJobNativeUiState.complete
              ? NativeTestCommandState.completed
              : NativeTestCommandState.failed,
        );
        expect(
          reply.error,
          terminal == adapter.CreatedJobNativeUiState.complete
              ? isNull
              : NativeTestCommandError.stateChanged,
        );
        expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
        expect(cache.cache.takeNext(), isNull);
      },
    );
  }
  for (final nonterminal in [
    adapter.CreatedJobNativeUiState.idle,
    adapter.CreatedJobNativeUiState.pending,
    adapter.CreatedJobNativeUiState.unknown,
  ]) {
    test(
      'native Sync refuses nonterminal ${nonterminal.name} after bounded wait',
      () async {
        final cache = command_test.Fixture();
        final wire = cache.request(1, action: NativeTestAction.accept);
        cache.cache.submitJson(wire);
        final command = cache.cache.takeNext()!;
        final reply = await _settleNativeCommand(
          cache,
          command,
          adapter.waitForCreatedJobNativeSyncTerminal(
            waitUntilReady: (ready) async {
              expect(ready(), isFalse);
              cache.now = 1000;
              cache.cache.tick();
              expect(
                cache.cache.submitJson(wire).state,
                NativeTestCommandState.unknown,
              );
              throw StateError('bounded wait expired');
            },
            readState: () => nonterminal,
            isStillCurrent: () => true,
          ),
        );
        expect(reply.state, NativeTestCommandState.failed);
        expect(reply.effect, NativeTestEffect.possible);
        expect(reply.error, NativeTestCommandError.harnessFailed);
      },
    );
  }
  test(
    'native Sync refuses late terminal UI after page or lifecycle cancellation',
    () async {
      final cache = command_test.Fixture();
      final wire = cache.request(1, action: NativeTestAction.accept);
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      var current = true;
      var state = adapter.CreatedJobNativeUiState.pending;
      final reply = await _settleNativeCommand(
        cache,
        command,
        adapter.waitForCreatedJobNativeSyncTerminal(
          waitUntilReady: (ready) => adapter.waitForJoinNativeCompletion(
            ready: ready,
            elapsedMillis: () => cache.now,
            commandDeadlineMillis: command.deadlineMillis,
            pump: () async {
              cache.now = 1000;
              expect(
                cache.cache.submitJson(wire).state,
                NativeTestCommandState.unknown,
              );
              current = false;
              state = adapter.CreatedJobNativeUiState.complete;
            },
          ),
          readState: () => state,
          isStillCurrent: () => current,
        ),
      );
      expect(reply.state, NativeTestCommandState.failed);
      expect(reply.effect, NativeTestEffect.possible);
      expect(reply.error, NativeTestCommandError.harnessFailed);
    },
  );
  testWidgets(
    'native Close waits for actual route return after controller stop drains',
    (tester) async {
      late JoinFixture fixture;
      await tester.runAsync(() async => fixture = await JoinFixture.create());
      final discovery = _HeldStopDiscovery();
      final controller = NearbyController(
        deviceId: 'native-close',
        deviceName: 'native-close',
        discovery: discovery,
        companyJoin: true,
        bindAddress: InternetAddress.loopbackIPv4,
        localIps: () async => ['127.0.0.1'],
        collectPayload: () async =>
            throw StateError('Join must not collect a shop'),
        applyPayload: (_) async =>
            throw StateError('Join must not replace a shop'),
      );
      final cache = command_test.Fixture();
      final wire = cache.request(1, action: NativeTestAction.finish);
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      final returned = Completer<void>();
      bool Function()? ready;
      final waited = Completer<void>();
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final navigator = Navigator.of(tester.element(find.byType(Scaffold)));
      unawaited(
        navigator
            .push<bool>(
              MaterialPageRoute(
                builder: (_) => CompanyJoinPage(
                  enrollment: fixture.aEnrollment,
                  approver: fixture.owner,
                  reconnect: true,
                  createController: (_) => controller,
                ),
              ),
            )
            .then((_) => returned.complete()),
      );
      final page = find.byType(CompanyJoinPage);
      try {
        final close = find.byKey(const Key('company-join-close'));
        await joinWidgetSignal(
          tester,
          () =>
              page.evaluate().length == 1 &&
              close.evaluate().length == 1 &&
              tester.widget<TextButton>(close).onPressed != null &&
              controller.state.running,
        );
        final state = tester.state(page);
        discovery.hold = true;
        await tester.runAsync(() => tester.tap(close));
        await joinWidgetSignal(tester, () => discovery.entered.isCompleted);
        expect(
          controller.state.running,
          isFalse,
          reason: 'Transport stop alone is not route/drain completion.',
        );
        expect(state.mounted, isTrue);
        expect(returned.isCompleted, isFalse);
        var settled = false;
        final result =
            _settleNativeCommand(
              cache,
              command,
              adapter.waitForCreatedJobNativeCloseDrain(
                waitUntilReady: (predicate) {
                  ready = predicate;
                  return waited.future;
                },
                isDrained: () =>
                    returned.isCompleted &&
                    !state.mounted &&
                    !controller.state.running,
              ),
            ).then((reply) {
              settled = true;
              return reply;
            });
        await tester.pump();
        expect(settled, isFalse);
        expect(
          cache.cache.submitJson(wire).state,
          NativeTestCommandState.running,
        );
        expect(cache.cache.takeNext(), isNull);
        expect(
          cache.cache.submitJson(cache.request(2)).error,
          NativeTestCommandError.busy,
        );
        discovery.release.complete();
        await joinWidgetSignal(
          tester,
          () =>
              returned.isCompleted &&
              !state.mounted &&
              !controller.state.running,
        );
        expect(ready!(), isTrue);
        waited.complete();
        await tester.pump();
        final reply = await result;
        expect(reply.state, NativeTestCommandState.completed);
        expect(reply.effect, NativeTestEffect.completed);
        expect(cache.cache.submitJson(wire).toJson(), reply.toJson());
        expect(cache.cache.takeNext(), isNull);
      } finally {
        if (!discovery.release.isCompleted) discovery.release.complete();
        await joinWidgetSignal(
          tester,
          () =>
              returned.isCompleted &&
              page.evaluate().isEmpty &&
              !controller.state.running,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await controller.dispose();
          await discovery.delegate.controller.close();
          await fixture.closeAndCheckOwnerData();
        });
      }
    },
  );
  testWidgets(
    'native signin waits for loaded Jobs before extra authority verification',
    (tester) async {
      late JoinFixture fixture;
      await tester.runAsync(() async {
        fixture = await JoinFixture.create();
        await fixture.aEnrollment.signOut();
      });
      final originalJobs = (await tester.runAsync(
        () => fixture.aDb.select(fixture.aDb.jobs).get(),
      ))!;
      final originalHistory = (await tester.runAsync(
        () => fixture.aDb.select(fixture.aDb.companyJobs).get(),
      ))!;
      final entered = Completer<void>();
      final released = Completer<void>();
      await tester.binding.setSurfaceSize(const Size(1500, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: CompanyBootstrapGate(
              db: fixture.aDb,
              installation: fixture.a,
            ),
          ),
        );
        await joinWidgetSignal(
          tester,
          () =>
              find.byKey(const Key('company-signin-pin')).evaluate().length ==
              1,
        );
        fixture.aStore.beforeRead = (namespace) {
          if (!entered.isCompleted &&
              namespace == fixture.a.namespace &&
              find.byType(CompanyJobsPanel).evaluate().length == 1) {
            entered.complete();
            return released.future;
          }
          return null;
        };
        await tester.enterText(
          find.byKey(const Key('company-signin-pin')),
          '1234',
        );
        await tester.runAsync(
          () => tester.tap(find.byKey(const Key('company-signin'))),
        );
        await joinWidgetSignal(tester, () => entered.isCompleted);
        expect(find.byKey(const Key('company-peer-open')), findsOneWidget);
        expect(find.text('Loading company Jobs...'), findsOneWidget);
        expect(find.byKey(const Key('company-jobs-list')), findsNothing);
        var readyForExtraSignIn = false;
        final readiness = adapter
            .waitForJoinNativeSignInReady(
              waitUntilReady: (ready) async {
                if (!ready()) {
                  await released.future;
                  await joinWidgetSignal(tester, ready);
                }
              },
            )
            .then((_) => readyForExtraSignIn = true);
        await tester.pump();
        expect(
          readyForExtraSignIn,
          isFalse,
          reason: 'The signed-in shell must not authorize another protected read while Jobs load.',
        );
        released.complete();
        await readiness;
        expect(readyForExtraSignIn, isTrue);
        final original = originalJobs.single;
        final renderedRow = find.byKey(Key('company-job-${original.id}'));
        expect(renderedRow, findsOneWidget);
        expect(
          find.descendant(of: renderedRow, matching: find.text(original.name)),
          findsOneWidget,
        );
        expect(find.byKey(const Key('company-job-error')), findsNothing);
        await tester.runAsync(() async {
          final extra = await fixture.aEnrollment.signIn('1234');
          final commands = CompanyJobCommands(enrollment: fixture.aEnrollment);
          final listed = await commands.listJobs(ownerSession: extra);
          expect(listed.map((job) => job.id), [original.id]);
          final verified = await commands.verifySyncRecord(original.id, extra);
          expect(verified, originalHistory.single);
          expect(
            await fixture.aDb.select(fixture.aDb.jobs).get(),
            originalJobs,
          );
          expect(
            await fixture.aDb.select(fixture.aDb.companyJobs).get(),
            originalHistory,
          );
          await fixture.aEnrollment.signOut();
        });
        expect(find.byKey(const Key('company-job-error')), findsNothing);
      } finally {
        fixture.aStore.beforeRead = null;
        if (!released.isCompleted) released.complete();
        await joinWidgetSignal(
          tester,
          () =>
              find
                  .byKey(const Key('company-jobs-list'))
                  .evaluate()
                  .isNotEmpty ||
              find.byKey(const Key('company-job-error')).evaluate().isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.closeAndCheckOwnerData);
      }
    },
  );
  testWidgets(
    'pushed page State capture completes after the action deadline and preserves pop completion',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      final navigator = Navigator.of(tester.element(find.byType(Scaffold)));
      const pageKey = Key('native-pushed-page');
      final page = find.byKey(pageKey);
      var routeReturned = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          navigator
              .push<void>(
                MaterialPageRoute(
                  builder: (_) => const Form(key: pageKey, child: SizedBox()),
                ),
              )
              .then((_) => routeReturned = true),
        );
      });
      await tester.pump();
      expect(page, findsNothing);
      var readinessPumps = 0;
      var elapsed = 19059;
      Future<void> readiness(
        bool Function() ready, {
        bool beforeEffect = false,
      }) => adapter.waitForJoinNativeCompletion(
        ready: ready,
        elapsedMillis: () => elapsed,
        commandDeadlineMillis: 15000,
        enforceCommandDeadline: beforeEffect,
        pump: () async {
          readinessPumps++;
          elapsed += 50;
          await tester.pump(const Duration(milliseconds: 50));
        },
      );
      await expectLater(
        adapter.captureJoinNativePageState(
          tester: tester,
          page: page,
          waitUntilReady: (ready) => readiness(ready, beforeEffect: true),
        ),
        throwsA(isA<NativeTestFailure>()),
      );
      expect(readinessPumps, 0);
      expect(page, findsNothing);
      expect(
        () => adapter.validateJoinNativeDeadline(elapsed, 15000),
        throwsA(isA<NativeTestFailure>()),
      );
      final captured = await adapter.captureJoinNativePageState(
        tester: tester,
        page: page,
        waitUntilReady: readiness,
      );
      expect(readinessPumps, greaterThan(0));
      expect(captured, same(tester.state<FormState>(page)));
      expect(captured.mounted, isTrue);
      expect(routeReturned, isFalse);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(routeReturned, isTrue);
      expect(captured.mounted, isFalse);
    },
  );
  test('created mode requires a fresh run and the exact full source pin', () {
    expect(() => _validate(), returnsNormally);
    expect(() => _validate(role: 'member', platform: 'macos'), returnsNormally);
    expect(() => _validate(run: adapter.joinNativeRun), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v1'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v2'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v3'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v4'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v5'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v6'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v7'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v8'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v9'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v15'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v16'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v17'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v18'), throwsA(anything));
    expect(() => _validate(run: 'j61-created-v20'), throwsA(anything));
    expect(() => _validate(productRevision: _tree), throwsA(anything));
    expect(
      () => _validate(revision: 'short', productRevision: 'short'),
      throwsA(anything),
    );
    expect(
      () => _validate(
        revision: adapter.joinNativeProductRevision,
        productRevision: adapter.joinNativeProductRevision,
      ),
      throwsA(anything),
    );
    expect(() => _validate(role: 'member'), throwsA(anything));
  });

  test('legacy defaults retain their exact run and product pin', () {
    expect(
      () => adapter.validateJoinNativeDefines(
        enabled: true,
        run: adapter.joinNativeRun,
        role: 'owner',
        platform: 'windows',
        revision: _revision,
        tree: _tree,
        adapter: _adapterHash,
      ),
      returnsNormally,
    );
    expect(() => _validate(createdMode: false), throwsA(anything));
    expect(
      adapter.joinNativeNamespace(adapter.joinNativeRun, 'owner'),
      'synthetic.company.join.j60-join-v10.owner',
    );
    expect(
      adapter.joinNativeNamespace(
        adapter.createdJobNativeRun,
        'owner',
        createdMode: true,
      ),
      'synthetic.company.created.j61-created-v19.owner',
    );
    expect(
      () => adapter.joinNativeNamespace(
        adapter.joinNativeRun,
        'owner',
        createdMode: true,
      ),
      throwsA(anything),
    );
  });

  test('public UI completion remains pending until its button is released', () {
    adapter.CreatedJobNativeUiState state(
      String status, {
      bool busy = false,
      bool error = false,
    }) => adapter.createdJobNativeUiState(
      status: status,
      errorVisible: error,
      busy: busy,
    );
    expect(
      state('Checking Job sync permissions.'),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Exchanging Job holdings with the verified peer.'),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.', busy: true),
      adapter.CreatedJobNativeUiState.pending,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.'),
      adapter.CreatedJobNativeUiState.complete,
    );
    expect(
      state(
        'Confirmed sent 0, received 0. More Jobs pending. Pair again and retry Sync Now.',
      ),
      adapter.CreatedJobNativeUiState.incomplete,
    );
    expect(
      state(
        'Job sync incomplete. Confirmed sent 0, received 0. Pair again and retry Sync Now.',
      ),
      adapter.CreatedJobNativeUiState.incomplete,
    );
    expect(
      state('Job snapshot synced. Sent 1, received 1.', error: true),
      adapter.CreatedJobNativeUiState.error,
    );
    expect(
      state(
        'Trusted peer authenticated. Verification alone does not exchange Jobs.',
      ),
      adapter.CreatedJobNativeUiState.idle,
    );
    expect(
      state('Unrecognized future product copy'),
      adapter.CreatedJobNativeUiState.unknown,
    );
  });

  test(
    'partial created fixtures cannot be adopted for an interruption retry',
    () {
      final root = Directory.systemTemp.createTempSync('j61-adapter-boundary-');
      addTearDown(() => root.deleteSync(recursive: true));
      bool validate() => adapter.validateJoinNativeExistingRoot(
        root,
        run: adapter.createdJobNativeRun,
        role: 'owner',
        revision: _revision,
        tree: _tree,
        adapter: _adapterHash,
        createdMode: true,
        productRevision: _revision,
      );
      expect(validate, throwsA(anything));
      final receipt = <String, Object?>{
        'format': 1,
        'passed': true,
        'run': adapter.createdJobNativeRun,
        'role': 'owner',
        'namespace': adapter.joinNativeNamespace(
          adapter.createdJobNativeRun,
          'owner',
          createdMode: true,
        ),
        'sourceRevision': _revision,
        'sourceTree': _tree,
        'adapterSha256': _adapterHash,
        'productRevision': _revision,
        'root': root.path,
        'locked': true,
        'mode': 'created-jobs',
        'schema': 9,
        'createdJobsComplete': false,
        'bothJobsRendered': true,
        'receiptCountVerifiedBeforeLock': 2,
        'identity': {
          for (final key in [
            'installation',
            'generation',
            'publicKeySha256',
            'storeGeneration',
            'company',
            'shop',
            'user',
            'device',
          ])
            key: key,
        },
      };
      final file = File(p.join(root.path, 'join-exercise.json'));
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate, throwsA(anything));
      receipt['createdJobsComplete'] = true;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate(), isTrue);
      bool validateNames() => adapter.validateJoinNativeExistingRoot(
        root,
        run: adapter.createdJobNativeRun,
        role: 'owner',
        revision: _revision,
        tree: _tree,
        adapter: _adapterHash,
        createdMode: true,
        jobNameMode: true,
        productRevision: _revision,
      );
      expect(validateNames, throwsA(anything));
      receipt.addAll({
        'jobNameMode': true,
        'jobNamesComplete': true,
        'nameOperationCount': 4,
        'nameAckCount': 4,
        'nameReceiptCountVerifiedBeforeLock': 3,
      });
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validate, throwsA(anything));
      expect(validateNames, throwsA(anything));
      receipt['nameReceiptCountVerifiedBeforeLock'] = 4;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validateNames(), isTrue);
      receipt['schema'] = 8;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validateNames, throwsA(anything));
      receipt['schema'] = 9;
      receipt['sourceTree'] = _revision;
      file.writeAsStringSync(jsonEncode(receipt));
      expect(validateNames, throwsA(anything));
    },
  );

  test(
    'unresolved Job-name conflict admits only its exact cold checkpoint',
    () {
      final root = Directory.systemTemp.createTempSync('j61-name-conflict-');
      addTearDown(() => root.deleteSync(recursive: true));
      final identity = {
        for (final key in [
          'installation',
          'generation',
          'publicKeySha256',
          'storeGeneration',
          'company',
          'shop',
          'user',
          'device',
        ])
          key: key,
      };
      final conflictView = {
        'job': 'job-1',
        'hasConflict': true,
        'heads': ['owner-head', 'member-head'],
        'candidates': [
          {
            'operation': 'owner-head',
            'name': 'Owner',
            'user': 'owner',
            'device': 'device-a',
          },
          {
            'operation': 'member-head',
            'name': 'Member',
            'user': 'member',
            'device': 'device-b',
          },
        ],
      };
      final checkpoint = <String, Object?>{
        'format': 1,
        'stage': 'unresolved-name-conflict',
        'passed': false,
        'run': adapter.createdJobNativeRun,
        'role': 'owner',
        'namespace': adapter.joinNativeNamespace(
          adapter.createdJobNativeRun,
          'owner',
          createdMode: true,
        ),
        'sourceRevision': _revision,
        'sourceTree': _tree,
        'adapterSha256': _adapterHash,
        'productRevision': _revision,
        'root': root.path,
        'mode': 'created-jobs',
        'schema': 9,
        'jobNameMode': true,
        'createdJobsComplete': false,
        'jobNamesComplete': false,
        'locked': true,
        'syncCompleted': true,
        'syncStarts': 1,
        'nearbyControllerRunning': false,
        'productionJobsPanelRendered': true,
        'bothAttributedCandidatesRendered': true,
        'lockedSqlSha256': 'd' * 64,
        'identity': identity,
        'nameEvidence': {
          'jobHistorySha256': 'a' * 64,
          'nameOperationCount': 3,
          'nameReceiptCountVerified': 3,
          'nameAckCount': 3,
          'nameRecordsSha256': 'b' * 64,
          'nameAckSha256': 'c' * 64,
          'nameReceiptVerification': 'typed-public-verifier',
          'ackVerification': 'confirmedPeerCounts',
          'nameViews': [
            conflictView,
            {
              'job': 'job-2',
              'hasConflict': false,
              'heads': [],
              'candidates': [],
            },
          ],
        },
      };
      final checkpointFile = File(p.join(root.path, 'join-name-conflict.json'));
      checkpointFile.writeAsStringSync(jsonEncode(checkpoint));
      adapter.JoinNativeRootAdmission validate() =>
          adapter.validateJoinNativeRootAdmission(
            root,
            run: adapter.createdJobNativeRun,
            role: 'owner',
            revision: _revision,
            tree: _tree,
            adapter: _adapterHash,
            createdMode: true,
            jobNameMode: true,
            productRevision: _revision,
          );

      expect(validate().stage, adapter.JoinNativeRootStage.unresolvedConflict);
      expect(
        adapter.validateJoinNativeExistingRoot(
          root,
          run: adapter.createdJobNativeRun,
          role: 'owner',
          revision: _revision,
          tree: _tree,
          adapter: _adapterHash,
          createdMode: true,
          jobNameMode: true,
          productRevision: _revision,
        ),
        isFalse,
      );
      for (final invalid in [
        {...checkpoint, 'passed': true},
        {
          ...checkpoint,
          'nameEvidence': {
            ...(checkpoint['nameEvidence'] as Map),
            'nameOperationCount': 4,
          },
        },
        {
          ...checkpoint,
          'nameEvidence': {
            ...(checkpoint['nameEvidence'] as Map),
            'nameAckSha256': 'not-a-digest',
          },
        },
        {
          ...checkpoint,
          'nameEvidence': {
            ...(checkpoint['nameEvidence'] as Map),
            'nameViews': [conflictView],
          },
        },
      ]) {
        checkpointFile.writeAsStringSync(jsonEncode(invalid));
        expect(validate, throwsA(anything));
      }
    },
  );

  test('cold name readback refuses changed identity, history, records, ACKs, or attribution', () {
    final identity = {
      for (final key in [
        'installation',
        'generation',
        'publicKeySha256',
        'storeGeneration',
        'company',
        'shop',
        'user',
        'device',
      ])
        key: key,
    };
    final views = [
      {
        'job': 'job-1',
        'hasConflict': true,
        'heads': ['owner-head', 'member-head'],
        'candidates': [
          {
            'operation': 'owner-head',
            'name': 'Owner',
            'user': 'owner',
            'device': 'device-a',
          },
          {
            'operation': 'member-head',
            'name': 'Member',
            'user': 'member',
            'device': 'device-b',
          },
        ],
      },
    ];
    final expected = <String, dynamic>{
      'identity': identity,
      'nameEvidence': {
        'jobHistorySha256': 'a' * 64,
        'nameOperationCount': 3,
        'nameReceiptCountVerified': 3,
        'nameAckCount': 3,
        'nameRecordsSha256': 'b' * 64,
        'nameAckSha256': 'c' * 64,
        'nameReceiptVerification': 'typed-public-verifier',
        'ackVerification': 'confirmedPeerCounts',
        'nameViews': views,
      },
    };
    final actual = <String, Object?>{
      ...(expected['nameEvidence'] as Map<String, Object?>),
      'identity': identity,
    };
    adapter.verifyJoinNativeJobNameReadback(expected, actual);
    for (final key in [
      'jobHistorySha256',
      'nameRecordsSha256',
      'nameAckSha256',
    ]) {
      final changed = {...actual, key: 'd' * 64};
      expect(
        () => adapter.verifyJoinNativeJobNameReadback(expected, changed),
        throwsA(anything),
      );
    }
    expect(
      () => adapter.verifyJoinNativeJobNameReadback(expected, {
        ...actual,
        'identity': {...identity, 'device': 'changed'},
      }),
      throwsA(anything),
    );
    expect(
      () => adapter.verifyJoinNativeJobNameReadback(expected, {
        ...actual,
        'nameViews': const [],
      }),
      throwsA(anything),
    );
  });

  test(
    'name finalization waits for conflict resume Sync after cold readback',
    () {
      expect(
        adapter.mayFinalizeCreatedJobNameStage(
          restart: false,
          conflictResume: false,
          conflictReadbackVerified: false,
          syncComplete: false,
        ),
        isFalse,
      );
      expect(
        adapter.mayFinalizeCreatedJobNameStage(
          restart: false,
          conflictResume: false,
          conflictReadbackVerified: false,
          syncComplete: true,
        ),
        isTrue,
      );
      expect(
        adapter.mayFinalizeCreatedJobNameStage(
          restart: true,
          conflictResume: true,
          conflictReadbackVerified: false,
          syncComplete: true,
        ),
        isFalse,
      );
      expect(
        adapter.mayFinalizeCreatedJobNameStage(
          restart: true,
          conflictResume: true,
          conflictReadbackVerified: true,
          syncComplete: false,
        ),
        isFalse,
      );
      expect(
        adapter.mayFinalizeCreatedJobNameStage(
          restart: true,
          conflictResume: true,
          conflictReadbackVerified: true,
          syncComplete: true,
        ),
        isTrue,
      );
      expect(
        adapter.mayFinalizeCreatedJobNameStage(
          restart: true,
          conflictResume: false,
          conflictReadbackVerified: false,
          syncComplete: false,
        ),
        isTrue,
      );
    },
  );
}
