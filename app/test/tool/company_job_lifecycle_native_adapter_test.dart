@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_crypto.dart';
import '../features/company/company_job_name_test.dart' show NameFixture;
import '../features/company/company_job_lifecycle_sync_test.dart' show deletion;
import '../features/company/company_join_test.dart'
    show JoinFixture, activateFixtureB;
import '../features/company/company_created_job_sync_test.dart'
    show openSyncPair;
import '../features/company/company_join_widget_test.dart'
    show JoinLoopbackHttpOverrides;
import 'job_name_native_ui_test.dart' as native show mount, ready, tap;

String digest(String value) => sha256.convert(utf8.encode(value)).toString();
Object? canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: canonicalValue(value[key])};
  }
  if (value is List) return value.map(canonicalValue).toList();
  return value;
}

String canonical(Object? value) => jsonEncode(canonicalValue(value));

Map<String, Object?> terminal(
  int sent,
  int received,
  int time, {
  int page = 1,
}) => {
  'complete': true,
  'sent': sent,
  'received': received,
  'elapsedMillis': time,
  'pageEpoch': page,
  'pairIdSha256': 'a' * 64,
  'pairRemainingMillis': 299999,
};

Map<String, dynamic> evidence(List<String> tables, {bool resolved = false}) {
  final life = resolved ? 2 : 1;
  final delete = 'a' * 64, edit = 'b' * 64, keep = 'c' * 64;
  final counts = {for (final table in tables) table: 0};
  counts.addAll({
    'jobs': 2,
    'company_jobs': 2,
    'company_job_peer_acks': 2,
    'company_job_details': 1,
    'company_job_detail_peer_acks': 1,
    'company_job_lifecycles': life,
    'company_job_lifecycle_peer_acks': life,
  });
  final creation = 'd' * 64;
  return {
    'identity': {
      for (final key in [
        'installation',
        'generation',
        'storeGeneration',
        'company',
        'shop',
        'user',
        'device',
      ])
        key: key,
      'publicKeySha256': 'e' * 64,
    },
    'counts': counts,
    'schema': 11,
    'integrityValid': true,
    'referencesValid': true,
    'receiptCountVerified': 2,
    'ackCount': 2,
    'originalLocalRecordUnchanged': true,
    'nameOperationCount': 0,
    'nameReceiptCountVerified': 0,
    'nameAckCount': 0,
    'detailsOperationCount': 1,
    'detailsReceiptCountVerified': 1,
    'detailsAckCount': 1,
    'lifecycleOperationCount': life,
    'lifecycleReceiptCountVerified': life,
    'lifecycleAckCount': life,
    'nativeCustodyActive': true,
    'lifecycleGenesisProfileVerified': true,
    'ackVerification': 'confirmedPeerCounts',
    for (final family in ['', 'name', 'details', 'lifecycle'])
      family.isEmpty ? 'receiptVerification' : '${family}ReceiptVerification':
          'typed-public-verifier',
    'selectedJob': 'job-a',
    'creationDigest': creation,
    'sharedCreations': [
      {'job': 'job-a', 'creationDigest': creation},
      {'job': 'job-b', 'creationDigest': 'f' * 64},
    ],
    'confirmedPeerCounts': {'job-a': 1, 'job-b': 1},
    'lifecycleMetadataRecords': [
      {
        'job': 'job-a',
        'contract': 'job.details.patch@2',
        'lifecycle': [],
        'operation': edit,
        'originalDevice': 'member',
      },
    ],
    'lifecycleRecords': [
      {
        'job': 'job-a',
        'operation': delete,
        'contract': 'job.lifecycle.set@1',
        'choice': 'deleted',
        'resolve': false,
        'parents': [],
        'originalDevice': 'owner',
      },
      if (resolved)
        {
          'job': 'job-a',
          'operation': keep,
          'contract': 'job.lifecycle.set@1',
          'choice': 'kept',
          'resolve': true,
          'parents': ['d/$edit', 'l/$delete'],
          'originalDevice': 'owner',
        },
    ],
    'lifecycleViews': [
      {
        'job': 'job-a',
        'creationDigest': creation,
        'state': resolved ? 'live' : 'deleteConflict',
        'notes':
            'Synthetic member lifecycle notes ${adapter.jobLifecycleNativeRun}',
        'notesConflict': false,
        'alternatives': resolved
            ? [
                {'operation': keep, 'device': 'owner'},
              ]
            : [
                {'operation': delete, 'device': 'owner'},
                {'operation': edit, 'device': 'member'},
              ],
      },
      {'job': 'job-b', 'creationDigest': 'f' * 64, 'state': 'live'},
    ],
    for (final key in [
      'jobHistorySha256',
      'receiptSha256',
      'ackSha256',
      'nameRecordsSha256',
      'nameAckSha256',
      'detailsRecordsSha256',
      'detailsAckSha256',
      'lifecycleRecordsSha256',
      'lifecycleAckSha256',
    ])
      key: digest(key),
    'nameViews': [],
    'detailsViews': [],
  };
}

void main() {
  test('lifecycle source manifest binds the frozen product separately from adapter revision', () {
    final root = Directory.systemTemp.createTempSync('lifecycle-source-');
    addTearDown(() => root.deleteSync(recursive: true));
    final paths = [
      'app/lib/data/app_database.dart',
      'app/lib/data/app_database.g.dart',
      'app/lib/features/company/company_join.dart',
      'app/lib/features/company/company_protocol.dart',
      'app/lib/features/company/company_membership.dart',
      'app/lib/features/company/company_created_job_sync.dart',
      'app/lib/features/company/company_job_details_section.dart',
      'app/lib/features/company/company_jobs_panel.dart',
      'app/lib/features/installation/installation_security.dart',
      'app/lib/features/job_line_commands/job_details.dart',
      'app/lib/features/job_line_commands/job_lifecycle.dart',
      'app/tool/native_nearby_test_commands.dart',
      'app/tool/native_nearby_test_fixture.dart',
      'app/integration_test/company_join_native_test.dart',
      'app/pubspec.yaml',
      'app/pubspec.lock',
    ];
    for (final path in paths) {
      final file = File('${root.path}/source/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('synthetic\r\n');
    }
    final manifest = File('${root.path}/source-manifest.json');
    final sourceHash = digest('synthetic\n');
    final body = {
      'format': 1,
      'kind': 'j63.lifecycle.source@1',
      'run': adapter.jobLifecycleNativeRun,
      'revision': 'a' * 40,
      'tree': 'b' * 40,
      'adapterSha256': sourceHash,
      'productRevision': adapter.jobLifecycleNativeProductRevision,
      'sourceLfSha256': {for (final path in paths) path: sourceHash},
    };
    manifest.writeAsStringSync(jsonEncode(body));
    final pin = digest(manifest.readAsStringSync());
    void validate({String? product}) =>
        adapter.validateJobLifecycleNativeSourceManifest(
          manifest: manifest,
          manifestSha256: pin,
          revision: 'a' * 40,
          tree: 'b' * 40,
          adapter: sourceHash,
          productRevision: product ?? adapter.jobLifecycleNativeProductRevision,
        );
    expect(validate, returnsNormally);
    expect(
      () => validate(product: 'a' * 40),
      throwsA(isA<NativeTestFailure>()),
    );
    File('${root.path}/source/${paths.first}').writeAsStringSync('changed');
    expect(validate, throwsA(isA<NativeTestFailure>()));
  });

  test('the reused protected checkpoint verifier refuses altered revision and native bytes', () {
    final base = ProtectedInstallationState(
      'base-revision',
      Uint8List.fromList([1, 2, 3]),
    );
    final custody = ProtectedInstallationState(
      'custody-revision',
      Uint8List.fromList([4, 5, 6]),
    );
    final expected = <String, dynamic>{
      'baseProtectedRevision': base.revision,
      'baseProtectedSha256': sha256.convert(base.bytes).toString(),
      'custodyProtectedSha256': sha256.convert(custody.bytes).toString(),
    };
    void verify(ProtectedInstallationState b, ProtectedInstallationState c) =>
        adapter.verifyJobDetailsCheckpointProtectedState(
          base: b,
          custody: c,
          expected: expected,
        );
    expect(() => verify(base, custody), returnsNormally);
    expect(
      () => verify(ProtectedInstallationState('changed', base.bytes), custody),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(
      () => verify(
        ProtectedInstallationState(base.revision, Uint8List.fromList([7])),
        custody,
      ),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(
      () => verify(
        base,
        ProtectedInstallationState(custody.revision, Uint8List.fromList([7])),
      ),
      throwsA(isA<NativeTestFailure>()),
    );
  });

  late List<String> tables;
  setUpAll(() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    tables = db.allTables.map((t) => t.actualTableName).toList();
    await db.close();
  });

  test('lifecycle defines bind the frozen product and a separate custody namespace', () {
    void validate({String? run, String? product, bool details = false}) =>
        adapter.validateJoinNativeDefines(
          enabled: true,
          run: run ?? adapter.jobLifecycleNativeRun,
          role: 'owner',
          platform: 'windows',
          revision: 'a' * 40,
          tree: 'b' * 40,
          adapter: 'c' * 64,
          createdMode: true,
          lifecycleMode: true,
          detailsMode: details,
          productRevision: product ?? adapter.jobLifecycleNativeProductRevision,
        );
    expect(validate, returnsNormally);
    expect(
      () => validate(run: adapter.jobDetailsNativeRun),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(
      () => validate(product: 'd' * 40),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(() => validate(details: true), throwsA(isA<NativeTestFailure>()));
    expect(
      adapter.joinNativeNamespace(
        adapter.jobLifecycleNativeRun,
        'owner',
        createdMode: true,
        lifecycleMode: true,
      ),
      isNot(
        adapter.joinNativeNamespace(
          adapter.jobDetailsNativeRun,
          'owner',
          createdMode: true,
          detailsMode: true,
        ),
      ),
    );
  });

  test('conflict and resolution require the exact family totals, v2 context and attributed frontier', () {
    for (final resolved in [false, true]) {
      final stage = resolved
          ? adapter.JobLifecycleNativeStage.resolved
          : adapter.JobLifecycleNativeStage.conflict;
      expect(
        () => adapter.validateJobLifecycleNativeEvidence(
          evidence(tables, resolved: resolved),
          stage,
        ),
        returnsNormally,
      );
      final mutations = <void Function(Map<String, dynamic>)>[
        (e) => e['schema'] = 10,
        (e) => (e['counts'] as Map).remove(tables.last),
        (e) => e['lifecycleReceiptCountVerified'] = 0,
        (e) => e['lifecycleReceiptVerification'] = 'locked-not-performed',
        (e) => e['lifecycleAckCount'] = 0,
        (e) => e['lifecycleGenesisProfileVerified'] = false,
        (e) => e['selectedJob'] = 'job-b',
        (e) => e['creationDigest'] = 'f' * 64,
        (e) => (e['confirmedPeerCounts'] as Map)['job-a'] = 0,
        (e) =>
            ((e['lifecycleMetadataRecords'] as List).single
                    as Map)['contract'] =
                'job.details.patch@1',
        (e) =>
            ((e['lifecycleMetadataRecords'] as List).single
                as Map)['lifecycle'] = [
              'a' * 64,
            ],
        (e) =>
            (((e['lifecycleViews'] as List).first as Map)['alternatives']
                    as List)
                .clear(),
        (e) =>
            ((e['lifecycleRecords'] as List).first as Map)['originalDevice'] =
                'member',
        (e) =>
            ((e['lifecycleViews'] as List).first as Map)['notes'] = 'lost edit',
      ];
      for (final mutate in mutations) {
        final changed = evidence(tables, resolved: resolved);
        mutate(changed);
        expect(
          () => adapter.validateJobLifecycleNativeEvidence(changed, stage),
          throwsA(anything),
        );
      }
    }
  });

  test('repeat gates require actual directional totals on the same Pair within five minutes', () {
    for (final owner in [false, true]) {
      final sent = owner ? 1 : 0, received = owner ? 0 : 1;
      void validate(List<Map<String, Object?>> t) =>
          adapter.validateJobLifecycleNativeRepeat(
            t,
            stage: adapter.JobLifecycleNativeStage.resolved,
            owner: owner,
          );
      expect(
        () => validate([terminal(sent, received, 5), terminal(0, 0, 300005)]),
        returnsNormally,
      );
      for (final invalid in [
        <Map<String, Object?>>[],
        [terminal(sent, received, 5)],
        [terminal(received, sent, 5), terminal(0, 0, 6)],
        [terminal(sent, received, 5), terminal(0, 0, 6, page: 2)],
        [terminal(sent, received, 5), terminal(0, 0, 300006)],
        [
          terminal(sent, received, 5),
          {...terminal(0, 0, 6), 'pairIdSha256': 'b' * 64},
        ],
        [
          terminal(sent, received, 5),
          {...terminal(0, 0, 6), 'pairRemainingMillis': 0},
        ],
        [
          {...terminal(sent, received, 5), 'pairRemainingMillis': 10},
          {...terminal(0, 0, 6), 'pairRemainingMillis': 11},
        ],
      ]) {
        expect(() => validate(invalid), throwsA(isA<NativeTestFailure>()));
      }
    }
    expect(
      () => adapter.validateJobLifecycleNativeRepeat(
        [terminal(1, 1, 0), terminal(0, 0, 2)],
        stage: adapter.JobLifecycleNativeStage.conflict,
        owner: true,
      ),
      returnsNormally,
    );
  });

  test('cold readback compares retained history and refuses changed receipt, ACK, identity or Notes', () {
    final expected = evidence(tables);
    final checkpoint = {
      'lifecycleStage': 'conflict',
      'lifecycleEvidence': expected,
    };
    expect(
      () => adapter.verifyJobLifecycleNativeReadback(
        checkpoint,
        evidence(tables),
      ),
      returnsNormally,
    );
    for (final key in [
      'identity',
      'receiptSha256',
      'ackSha256',
      'lifecycleAckSha256',
      'lifecycleRecordsSha256',
    ]) {
      final changed = evidence(tables)..[key] = 'changed';
      expect(
        () => adapter.verifyJobLifecycleNativeReadback(checkpoint, changed),
        throwsA(anything),
      );
    }
  });

  test('cold admission pins checkpoint, baseline and every SQL table without modifying the database', () {
    final root = Directory.systemTemp.createTempSync('lifecycle-cold-');
    addTearDown(() => root.deleteSync(recursive: true));
    final sqlite = File('${root.path}/support/wired_parts.sqlite');
    sqlite.parent.createSync();
    final db = raw.sqlite3.open(sqlite.path);
    final expected = evidence(tables);
    for (final table in tables) {
      db.execute('CREATE TABLE "$table" (n INTEGER)');
      for (var i = 0; i < (expected['counts'] as Map)[table]; i++) {
        db.execute('INSERT INTO "$table" VALUES (?)', [i]);
      }
    }
    db.execute('PRAGMA user_version = 11');
    final sql = {
      for (final table in tables)
        table:
            db
                .select('SELECT * FROM "$table"')
                .map((r) => canonical(Map<String, Object?>.from(r)))
                .toList()
              ..sort(),
    };
    db.dispose();
    File('${root.path}/validation-owner.json').writeAsStringSync(
      jsonEncode({
        'format': 1,
        'run': 'company-${adapter.jobLifecycleNativeRun}',
        'role': 'sender',
        'root': root.path,
        'initialized': true,
      }),
    );
    final baseline = {'selectedJob': 'job-a', 'creationDigest': 'd' * 64};
    File('${root.path}/lifecycle-shared-baseline-owner.json')
        .writeAsStringSync(jsonEncode(baseline));
    final checkpoint = <String, dynamic>{
      'format': 1,
      'run': adapter.jobLifecycleNativeRun,
      'role': 'owner',
      'platform': 'windows',
      'root': root.path,
      'namespace': adapter.joinNativeNamespace(
        adapter.jobLifecycleNativeRun,
        'owner',
        createdMode: true,
        lifecycleMode: true,
      ),
      'jobLifecycleMode': true,
      'lifecycleManifestSha256': 'd' * 64,
      'schema': 11,
      'locked': true,
      'nearbyControllerRunning': false,
      'passed': false,
      'lifecycleStage': 'conflict',
      'sourceRevision': 'a' * 40,
      'sourceTree': 'b' * 40,
      'adapterSha256': 'c' * 64,
      'productRevision': adapter.jobLifecycleNativeProductRevision,
      'lifecycleEvidence': expected,
      'baselineSha256': digest(canonical(baseline)),
      'lockedSqlSha256': digest(canonical(sql)),
      'lifecycleTerminals': [terminal(1, 1, 0), terminal(0, 0, 1)],
    };
    final file = File('${root.path}/join-lifecycle-checkpoint-123-1.json');
    file.writeAsStringSync(jsonEncode(checkpoint));
    final hash = digest(file.readAsStringSync());
    adapter.JoinNativeRootAdmission admit({String? checksum}) =>
        adapter.validateJobLifecycleNativeRootAdmission(
          root,
          role: 'owner',
          revision: 'a' * 40,
          tree: 'b' * 40,
          adapter: 'c' * 64,
          manifestSha256: 'd' * 64,
          checkpointPath: file.path,
          checkpointSha256: checksum ?? hash,
        );
    final before = sqlite.readAsBytesSync();
    expect(admit().stage, adapter.JoinNativeRootStage.lifecycleCheckpoint);
    expect(sqlite.readAsBytesSync(), before);
    expect(() => admit(checksum: '0' * 64), throwsA(isA<NativeTestFailure>()));
    File('${root.path}/lifecycle-shared-baseline-owner.json')
        .writeAsStringSync('{}');
    expect(admit, throwsA(isA<NativeTestFailure>()));
    File('${root.path}/lifecycle-shared-baseline-owner.json')
        .writeAsStringSync(jsonEncode(baseline));
    final changed = raw.sqlite3.open(sqlite.path);
    changed.execute('INSERT INTO "${tables.last}" VALUES (99)');
    changed.dispose();
    expect(admit, throwsA(isA<NativeTestFailure>()));
  });

  testWidgets(
    'native Delete uses confirmation and retains typed history outside the normal list',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      await native.mount(tester, f);
      final original = await tester.runAsync(
        () => f.db.select(f.db.companyJobs).get(),
      );
      var checks = 0;
      await adapter.saveJobLifecycleThroughNativeUi(
        tester: tester,
        jobId: f.createCommand.jobId,
        choice: JobLifecycleChoice.deleted,
        tap: (target) => native.tap(tester, target),
        waitUntilReady: (ready) => native.ready(tester, ready),
        requireBeforeEffect: () => checks++,
      );
      final views = (await tester.runAsync(
        () => f.commands.listJobViews(ownerSession: f.owner),
      ))!;
      expect(views.single.lifecycle.state, CompanyJobLifecycleState.deleted);
      adapter.assertJobLifecycleNativeViewUi(tester, views);
      expect(checks, 2);
      expect(
        await tester.runAsync(
          () => f.commands.lifecycleSyncHoldings(ownerSession: f.owner),
        ),
        hasLength(1),
      );
      expect(
        await tester.runAsync(() => f.db.select(f.db.companyJobs).get()),
        original,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'expiry at delete confirmation leaves no signed lifecycle mutation',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      await native.mount(tester, f);
      var checks = 0;
      await expectLater(
        adapter.saveJobLifecycleThroughNativeUi(
          tester: tester,
          jobId: f.createCommand.jobId,
          choice: JobLifecycleChoice.deleted,
          tap: (target) => native.tap(tester, target),
          waitUntilReady: (ready) => native.ready(tester, ready),
          requireBeforeEffect: () {
            if (++checks == 2) adapter.validateJoinNativeDeadline(15000, 15000);
          },
        ),
        throwsA(isA<NativeTestFailure>()),
      );
      expect(
        await tester.runAsync(
          () => f.db.select(f.db.companyJobLifecycles).get(),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'native Keep observes attributed deletion conflict and preserves v2 Notes and creation',
    (tester) async {
      final f = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => JoinFixture.create(allowOwnerAdditions: true),
          JoinLoopbackHttpOverrides(),
        ),
      ))!;
      addTearDown(f.closeAndCheckOwnerData);
      final pair = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await activateFixtureB(f);
          return openSyncPair(f);
        }, JoinLoopbackHttpOverrides()),
      ))!;
      addTearDown(() async {
        await pair.a.closeAndDrain();
        await pair.b.closeAndDrain();
      });
      final ac = CompanyJobCommands(enrollment: f.aEnrollment),
          bc = CompanyJobCommands(enrollment: f.bEnrollment);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          expect((await pair.a.syncNow()).complete, isTrue);
          final av = (await ac.listJobViews(ownerSession: f.owner)).single;
          final bv = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
          await ac.setJobLifecycle(
            deletion(av, f.owner),
            ownerSession: f.owner,
          );
          await bc.patchJobDetails(
            PatchJobDetails(
              companyId: pair.ownerB.identity.companyId,
              shopId: pair.ownerB.identity.shopId,
              jobId: bv.baseJob.id,
              requestId: const Uuid().v4(),
              creationDigest: bv.creationDigest,
              patch: const JobDetailsPatch(
                notes: SetField('Native retained Notes'),
              ),
              observedHeads: {JobDetailField.notes: []},
              observedLifecycleHeads: [],
            ),
            ownerSession: pair.ownerB,
          );
          expect((await pair.a.syncNow()).complete, isTrue);
          await pair.a.closeAndDrain();
          await pair.b.closeAndDrain();
        }, JoinLoopbackHttpOverrides()),
      );
      final original = await tester.runAsync(
        () => f.aDb.select(f.aDb.companyJobs).get(),
      );
      final before = (await tester.runAsync(
        () => ac.listJobViews(ownerSession: f.owner),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(commands: ac, owner: f.owner),
            ),
          ),
        ),
      );
      await native.ready(
        tester,
        () =>
            find
                .byKey(Key('company-job-keep-${before.single.baseJob.id}'))
                .evaluate()
                .length ==
            1,
      );
      adapter.assertJobLifecycleNativeViewUi(tester, before);
      await adapter.saveJobLifecycleThroughNativeUi(
        tester: tester,
        jobId: before.single.baseJob.id,
        choice: JobLifecycleChoice.kept,
        tap: (target) => native.tap(tester, target),
        waitUntilReady: (ready) => native.ready(tester, ready),
        requireBeforeEffect: () {},
      );
      final after = (await tester.runAsync(
        () => ac.listJobViews(ownerSession: f.owner),
      ))!;
      expect(after.single.lifecycle.state, CompanyJobLifecycleState.live);
      expect(after.single.details.notes.value, 'Native retained Notes');
      adapter.assertJobLifecycleNativeViewUi(tester, after);
      final life = (await tester.runAsync(
        () => ac.lifecycleSyncHoldings(ownerSession: f.owner),
      ))!;
      expect(life, hasLength(2));
      final kept = life.singleWhere(
        (r) =>
            SetJobLifecycle.fromOperationBytes(utf8.encode(r.operationBytes))
                .choice ==
            JobLifecycleChoice.kept,
      );
      expect(
        SetJobLifecycle.fromOperationBytes(utf8.encode(kept.operationBytes))
            .observed
            .tagged,
        before.single.lifecycle.context.tagged,
      );
      expect(
        await tester.runAsync(() => f.aDb.select(f.aDb.companyJobs).get()),
        original,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
