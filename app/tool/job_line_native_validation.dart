import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import '../test/features/job_line_commands/atomic_job_line_support.dart';
import 'nearby_lan_workspace.dart';

/// An opt-in phase of the existing installation validation entry point. Every
/// signed fixture and protected pin is confined to fresh owned synthetic stores.
Future<void> runJobLineNativeValidation(
  String run, {
  InstallationSecureStore validationStore =
      const NativeInstallationSecureStore(),
  Directory? temporaryDirectory,
}) async {
  final fixtureRun = 'jobline-$run';
  final marker = File(
    p.join(
      (temporaryDirectory ?? Directory.systemTemp).resolveSymbolicLinksSync(),
      'wired-parts-lan-$fixtureRun-sender',
      'receipts',
      'job-line-exercise.json',
    ),
  );
  final restart = marker.existsSync();
  final source = ValidationWorkspace.open(
    run: fixtureRun,
    role: ValidationRole.sender,
    requireExisting: restart,
    temporaryDirectory: temporaryDirectory,
  );
  ValidationWorkspace? receiver;
  final databases = <AppDatabase>[];
  var phase = 'bootstrap';
  try {
    receiver = ValidationWorkspace.open(
      run: fixtureRun,
      role: ValidationRole.receiver,
      requireExisting: restart,
      temporaryDirectory: temporaryDirectory,
    );
    final files = [
      File(p.join(source.support.path, kSqliteFileName)),
      File(p.join(receiver.support.path, kSqliteFileName)),
    ];
    final store = validationStore;
    String namespace(int i) => 'synthetic.jobline.$run.${i == 0 ? 's' : 'r'}';
    validateInstallationNamespace(namespace(0));
    validateInstallationNamespace(namespace(1));
    final receiptFile = File(
      p.join(
        source.receipts.path,
        restart ? 'job-line-restart.json' : 'job-line-exercise.json',
      ),
    );
    Map<String, Object?> evidence;
    if (!restart) {
      if (source.initialized || receiver.initialized) {
        throw StateError('Native job-line exercise requires a fresh run');
      }
      final fixture = await AtomicFixture.create(
        ownedDirectory: source.support,
        databaseFiles: files,
        nativeStore: store,
        namespaceForStore: namespace,
      );
      databases.addAll(fixture.databases);
      phase = 'commands';
      final command = fixture.command(
        const JobLinePatch(
          quantities: JobLineQuantities(needed: 9, shopPull: 15, unit: 'ea'),
          notes: SetField('Native atomic line'),
        ),
      );
      final first = await fixture.commit(0, command);
      _require(first.status == 'applied', 'Native local command did not apply');
      final repeated = await fixture.commit(0, command);
      _require(first.bytes == repeated.bytes, 'Native local replay differs');
      final incoming = await fixture
          .commands(1)
          .applyIncoming(first.operationBytes);
      _require(
        incoming.status == 'applied' &&
            incoming.bytes ==
                (await fixture.commands(1).applyIncoming(first.operationBytes))
                    .bytes,
        'Native incoming replay differs',
      );
      final beforeDenied = await _logicalHash(databases[0]);
      final denied = fixture.command(
        const JobLinePatch(notes: SetField('Denied')),
        shopId: '20000000-0000-4000-8000-000000000002',
      );
      try {
        await fixture.commit(0, denied);
        throw StateError('Native wrong-shop command was accepted');
      } on JobLineRefusal {
        /* Expected signed fixture refusal. */
      }
      _require(
        beforeDenied == await _logicalHash(databases[0]),
        'Denied native command changed logical rows',
      );
      final pending = fixture.command(
        const JobLinePatch(notes: SetField('Native pending committed')),
        parents: [operationKey(first)],
      );
      try {
        await fixture
            .commands(
              0,
              afterCommit: () async {
                throw const _LostNativeReply();
              },
            )
            .patchJobLine(await fixture.session(0, pending), pending);
        throw StateError('Native lost-response injection did not run');
      } on _LostNativeReply {
        /* Keep the real sealed native intent for restart. */
      }
      final protected = await store.readState(namespace(0));
      _require(
        protected != null &&
            protected.bytes.length <= kInstallationStateLimit &&
            (jsonDecode(utf8.decode(protected.bytes))
                    as Map)['pendingCommand'] !=
                null,
        'Native command intent was not retained',
      );
      final saved =
          await (databases[0].select(databases[0].jobLineReceipts)
                ..where((t) => t.commandCommitment.equals(pending.commitment)))
              .getSingle();
      evidence = {
        'format': 1,
        'run': run,
        'stage': 'exercise',
        'passed': true,
        'pid': pid,
        'nativeStore': true,
        'localReplay': true,
        'incomingReplay': true,
        'deniedUnchanged': true,
        'pendingIntent': true,
        'receiptSha256': sha256
            .convert(utf8.encode(saved.receiptBytes))
            .toString(),
        'pendingOperation': saved.operationCommitment,
        'pendingReceiptKey': saved.receiptKey,
        'pendingCommand': saved.commandCommitment,
        'senderLogicalSha256': await _logicalHash(databases[0]),
        'receiverLogicalSha256': await _logicalHash(databases[1]),
        'senderCounts': await fixture.counts(0),
        'receiverCounts': await fixture.counts(1),
      };
      source.markInitialized();
      receiver.markInitialized();
    } else {
      phase = 'restart';
      _require(
        !receiptFile.existsSync(),
        'Native recovery receipt is already sealed',
      );
      final exercise = jsonDecode(marker.readAsStringSync()) as Map;
      _require(
        exercise['format'] == 1 &&
            exercise['run'] == run &&
            exercise['passed'] == true &&
            exercise['stage'] == 'exercise' &&
            exercise['pid'] != pid,
        'Native restart requires a passed exercise from another process',
      );
      final beforeRecovery = await store.readState(namespace(0));
      final beforeRecord = beforeRecovery == null
          ? null
          : jsonDecode(utf8.decode(beforeRecovery.bytes)) as Map;
      final held = beforeRecord?['pendingCommand'];
      _require(
        beforeRecord?['v'] == 2 &&
            held is Map &&
            held['operation'] == exercise['pendingOperation'] &&
            held['receipt'] == exercise['pendingReceiptKey'] &&
            held['command'] == exercise['pendingCommand'] &&
            held['after'] is String &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(held['after'] as String),
        'Native cold recovery requires the matching sealed pending intent',
      );
      for (var i = 0; i < 2; i++) {
        final db = AppDatabase.forTesting(NativeDatabase(files[i]));
        databases.add(db);
        final security = InstallationSecurity(
          store: store,
          namespace: namespace(i),
        );
        await security.start(db);
        _require(
          security.readiness == InstallationReadiness.ready,
          'Native pending command did not recover',
        );
      }
      _require(
        await _logicalHash(databases[0]) == exercise['senderLogicalSha256'] &&
            await _logicalHash(databases[1]) ==
                exercise['receiverLogicalSha256'],
        'Native restart changed logical history',
      );
      final db = databases[0];
      final security = InstallationSecurity(
        store: store,
        namespace: namespace(0),
      );
      await security.start(db);
      final operation =
          await (db.select(db.jobLineOperations)..where(
                (t) =>
                    t.commitment.equals(exercise['pendingOperation'] as String),
              ))
              .getSingle();
      final commands = JobLineCommands(
        authorization: JobLineAuthorization(db: db, installation: security),
      );
      final reply = await commands.applyIncoming(
        Uint8List.fromList(utf8.encode(operation.operationBytes)),
      );
      _require(
        sha256.convert(utf8.encode(reply.bytes)).toString() ==
                exercise['receiptSha256'] &&
            await _logicalHash(db) == exercise['senderLogicalSha256'],
        'Native committed replay changed receipt or effects',
      );
      final protected = await store.readState(namespace(0));
      _require(
        (jsonDecode(utf8.decode(protected!.bytes)) as Map)['pendingCommand'] ==
            null,
        'Native pending intent was not cleared',
      );
      final line = await db.select(db.jobLines).getSingle();
      _require(
        line.notes == 'Native pending committed' &&
            line.neededQty == 9 &&
            line.shopPullQty == 15,
        'Native projection did not persist',
      );
      evidence = {
        'format': 1,
        'run': run,
        'stage': 'restart',
        'passed': true,
        'pid': pid,
        'exercisePid': exercise['pid'],
        'nativeStore': true,
        'matchingSealedIntentObserved': true,
        'pendingRecovered': true,
        'exactReplay': true,
        'logicalRowsUnchanged': true,
        'receiptSha256': exercise['receiptSha256'],
        'senderLogicalSha256': await _logicalHash(db),
        'receiverLogicalSha256': await _logicalHash(databases[1]),
      };
    }
    // Closing SQLite does not reconcile protected state. The exercise's sealed
    // pending intent stays unresolved until the separately launched process.
    for (final db in databases) {
      await db.close();
    }
    _require(
      validationStore.runtimeType == NativeInstallationSecureStore,
      'Native acceptance requires the actual native secure store',
    );
    receiptFile.writeAsStringSync(jsonEncode(evidence), flush: true);
    debugPrint(
      'JOB_LINE_NATIVE ${restart ? 'restart' : 'exercise'} PASS pid=$pid',
    );
    runApp(
      _NativeValidationWindow(
        workspaces: [source, receiver],
        message: restart ? 'Native job-line restart PASS' : 'Native job-line exercise PASS. Quit normally, then reopen the same run.',
      ),
    );
  } catch (error) {
    var databasesClosed =
        error is! FixtureBootstrapFailure || error.databasesClosed;
    for (final db in databases) {
      try {
        await db.close();
      } catch (_) {
        databasesClosed = false;
      }
    }
    final failure = {
      'format': 1,
      'run': run,
      'stage': phase,
      'passed': false,
      'pid': pid,
      'nativeStore': validationStore is NativeInstallationSecureStore,
      'databasesClosed': databasesClosed,
      'nativeCause': 'unknown',
      if (error is FixtureBootstrapFailure) ...{
        'bootstrapStage': error.stage.name,
        'storeIndex': error.storeIndex,
        'readiness': error.readiness?.name,
      },
    };
    var diagnosticWritten = false;
    try {
      File(
        p.join(
          source.receipts.path,
          'job-line-failure-$pid-${DateTime.now().toUtc().microsecondsSinceEpoch}.json',
        ),
      ).writeAsStringSync(jsonEncode(failure), flush: true);
      diagnosticWritten = true;
    } catch (_) {
      // A failed evidence write must still show failure without raw exceptions.
    }
    source.close();
    receiver?.close();
    exitCode = 1;
    debugPrint(
      'JOB_LINE_NATIVE FAIL ${jsonEncode(failure)} diagnosticWritten=$diagnosticWritten',
    );
    runApp(
      _NativeValidationWindow(
        workspaces: const [],
        message:
            'Native job-line FAIL ($phase). '
            'Readiness ${error is FixtureBootstrapFailure ? error.readiness?.name ?? 'unknown' : 'unknown'}. '
            'Native cause unknown. Databases closed $databasesClosed. '
            'Diagnostic written $diagnosticWritten.',
      ),
    );
  }
}

Future<String> _logicalHash(AppDatabase db) async {
  final evidence = <String, Object?>{};
  for (final name in [
    'jobs',
    'job_lines',
    'company_authority_facts',
    'job_line_baselines',
    'job_line_operations',
    'job_line_receipts',
    'job_line_audits',
    'job_line_outgoing',
    'job_line_conflicts',
  ]) {
    final rows = await db.customSelect('SELECT * FROM "$name"').get();
    evidence[name] = rows.map((r) => canonical(r.data)).toList()..sort();
  }
  return digest(evidence);
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

final class _LostNativeReply implements Exception {
  const _LostNativeReply();
}

class _NativeValidationWindow extends StatefulWidget {
  const _NativeValidationWindow({
    required this.workspaces,
    required this.message,
  });
  final List<ValidationWorkspace> workspaces;
  final String message;
  @override
  State<_NativeValidationWindow> createState() =>
      _NativeValidationWindowState();
}

class _NativeValidationWindowState extends State<_NativeValidationWindow>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    for (final workspace in widget.workspaces) {
      workspace.close();
    }
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Synthetic job-line validation')),
      body: Center(child: Text(widget.message)),
    ),
  );
}
