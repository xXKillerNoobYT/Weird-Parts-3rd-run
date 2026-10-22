import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_crypto.dart';
import '../../tool/native_nearby_test_commands.dart';
import 'job_name_native_ui_test.dart' as native show ready, tap;
import 'native_nearby_test_commands_test.dart' as command_test show Fixture;
import '../features/company/company_job_name_test.dart'
    show NameFixture, canonicalNameTest;
import '../features/company/company_join_test.dart'
    show JoinFixture, activateFixtureB;
import '../features/company/company_created_job_sync_test.dart'
    show openSyncPair;

String digest(String text) => sha256.convert(utf8.encode(text)).toString();

final class _LoopbackHttpOverrides extends HttpOverrides {}

final class _BaselineInspectionFixture {
  _BaselineInspectionFixture(this.root, this.role) {
    pid = role == 'owner' ? 33960 : 87978;
    final identity = {
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
      'publicKeySha256': 'a' * 64,
    };
    final header = <String, dynamic>{
      'format': 1,
      'run': adapter.jobDetailsNativeRun,
      'role': role,
      'pid': pid,
      'root': root.path,
      'namespace': adapter.joinNativeNamespace(
        adapter.jobDetailsNativeRun,
        role,
        createdMode: true,
        detailsMode: true,
      ),
      'sourceRevision': '6a417521bb80ed6614ef5a5ef71f7158c6e0f929',
      'sourceTree': 'a3f403d4d8dfa4bcb630d481e006a722e5d9a3cd',
      'adapterSha256':
          'ae534fe3996ff64de481bf5364a9adbb1575b70f066c85a53bccde41929be8dd',
      'productRevision': '6a417521bb80ed6614ef5a5ef71f7158c6e0f929',
      'detailsManifestSha256':
          '188758e654d61748851a82f7800ba02225f364d089e3b7f1308343d5fc196c39',
      'jobDetailsMode': true,
      'mode': 'created-jobs',
      'platform': role == 'owner' ? 'windows' : 'macos',
    };
    recovery = {
      'role': role,
      'root': root.path,
      'namespace': header['namespace'],
      'files': <Map<String, dynamic>>[],
      'evidence': {'identity': identity, 'sqlSha256': 'b' * 64},
    };
    shared = {
      ...header,
      'selectedJob': 'job-a',
      'creationDigest': digest('synthetic creation A'),
      'creationHistorySha256': 'c' * 64,
      'nameRecordsSha256': digest('[]'),
    };
    inspection = {
      ...header,
      'identity': identity,
      'sqlSha256': 'b' * 64,
      'jobHistorySha256': 'c' * 64,
      'nameRecordsSha256': digest('[]'),
      'selectedJob': 'job-a',
      'step': 'inspect',
      'savedThroughProductionUi': false,
      'productionJobsPanelRendered': true,
      'companyControllerStoppedDuringUi': true,
      'passed': false,
      'locked': false,
      'schema': 10,
      'integrityValid': true,
      'referencesValid': true,
      'receiptCountVerified': 2,
      'ackCount': 2,
      'nameOperationCount': 0,
      'nameReceiptCountVerified': 0,
      'nameAckCount': 0,
      'detailsOperationCount': 0,
      'detailsReceiptCountVerified': 0,
      'detailsAckCount': 0,
      'receiptVerification': 'typed-public-verifier',
      'nameReceiptVerification': 'typed-public-verifier',
      'detailsReceiptVerification': 'typed-public-verifier',
      'ackVerification': 'confirmedPeerCounts',
      'confirmedPeerCounts': {'job-a': 1, 'job-b': 1},
      'originalLocalRecordUnchanged': true,
      'nameRecords': <Object>[],
      'detailsRecords': <Object>[],
      'records': [
        for (final name in ['A', 'B'])
          {
            'jobId': name == 'A' ? 'job-a' : 'job-b',
            'operationBytes': 'synthetic creation $name',
            'operationSha256': digest('synthetic creation $name'),
          },
      ],
      'detailsViews': [
        for (final job in ['job-a', 'job-b'])
          {
            'job': job,
            'fields': {
              for (final field in JobDetailField.values)
                field.name: {
                  'value': field == JobDetailField.status ? 'active' : null,
                  'lastAgreedValue': field == JobDetailField.status
                      ? 'active'
                      : null,
                  'heads': <String>[],
                  'candidates': <Object>[],
                  'hasConflict': false,
                },
            },
          },
      ],
    };
    freeze();
  }
  final Directory root;
  final String role;
  late final int pid;
  late final Map<String, dynamic> recovery, shared, inspection;
  String get inspectName => 'details-ui-$pid-20.json';
  String get sharedName => 'details-shared-baseline-$role.json';
  void freeze() {
    final files = recovery['files'] as List;
    files.clear();
    for (final entry in {inspectName: inspection, sharedName: shared}.entries) {
      final file = File(p.join(root.path, entry.key));
      file.writeAsStringSync(jsonEncode(entry.value));
      files.add({
        'path': entry.key,
        'bytes': file.lengthSync(),
        'sha256': digest(file.readAsStringSync()),
      });
    }
  }

  void verify() => adapter.verifyDetailsBaselineInspection(root, recovery);
}

void main() {
  test('cold profile preserves legacy ID distinct from company device and refuses rehashed profile changes', () {
    final original = raw.sqlite3.openInMemory();
    final current = raw.sqlite3.openInMemory();
    addTearDown(original.dispose);
    addTearDown(current.dispose);
    const binding = 'synthetic installation binding';
    for (final db in [original, current]) {
      db.execute('PRAGMA user_version = 10');
      db.execute(
        'CREATE TABLE device_profiles (id TEXT, display_name TEXT, created_at INTEGER)',
      );
      db.execute('INSERT INTO device_profiles VALUES (?, ?, ?)', [
        'legacy-profile',
        'This device',
        123,
      ]);
      db.execute('CREATE TABLE app_settings (key TEXT, value TEXT)');
      db.execute('INSERT INTO app_settings VALUES (?, ?)', [
        kInstallationBindingKey,
        binding,
      ]);
      final counts = {
        'jobs': 2,
        'company_jobs': 2,
        'company_job_peer_acks': 2,
        'company_job_names': 0,
        'company_job_name_peer_acks': 0,
        'company_job_details': 3,
        'company_job_detail_peer_acks': 2,
        for (var i = 0; i < 23; i++) 'unchanged_$i': 0,
      };
      for (final entry in counts.entries) {
        db.execute('CREATE TABLE "${entry.key}" (id TEXT)');
        for (var i = 0; i < entry.value; i++) {
          db.execute('INSERT INTO "${entry.key}" VALUES (?)', ['$i']);
        }
      }
    }
    String snapshot() => digest(
      canonicalNameTest({
        for (final row in current.select(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          row['name'] as String:
              current
                  .select('SELECT * FROM "${row['name']}"')
                  .map((r) => canonicalNameTest(Map<String, Object?>.from(r)))
                  .toList()
                ..sort(),
      }),
    );
    void verify() => adapter.verifyDetailsMixedRecoveryDatabase(
      current,
      original: original,
      detailsCount: 3,
      evidence: {
        'identity': {'device': 'company-membership-device'},
        'sqlSha256': snapshot(),
        'bindingSha256': digest(binding),
      },
    );
    final before = snapshot();
    expect(verify, returnsNormally);
    expect(snapshot(), before);
    current.execute('UPDATE app_settings SET value = ? WHERE key = ?', [
      '{}',
      kInstallationBindingKey,
    ]);
    final changedBinding = snapshot();
    expect(verify, throwsA(isA<NativeTestFailure>()));
    expect(snapshot(), changedBinding);
    current.execute('UPDATE app_settings SET value = ? WHERE key = ?', [
      binding,
      kInstallationBindingKey,
    ]);
    expect(verify, returnsNormally);
    expect(snapshot(), before);
    for (final change in [
      "UPDATE device_profiles SET id = 'changed-profile'",
      "UPDATE device_profiles SET display_name = 'changed name'",
      'UPDATE device_profiles SET created_at = 456',
      'DELETE FROM device_profiles',
    ]) {
      current.execute(change);
      final changed = snapshot();
      expect(verify, throwsA(isA<NativeTestFailure>()));
      expect(snapshot(), changed);
      current.execute('DELETE FROM device_profiles');
      current.execute('INSERT INTO device_profiles VALUES (?, ?, ?)', [
        'legacy-profile',
        'This device',
        123,
      ]);
    }
    expect(verify, returnsNormally);
    expect(snapshot(), before);
  });

  final checkpointBase = ProtectedInstallationState(
    '5c4a605b-97f6-4b6c-968e-d06050605017',
    Uint8List.fromList([1, 2, 3]),
  );
  final checkpointCustody = ProtectedInstallationState(
    '6d72da4c-587b-48bd-83a4-912edc514fe4',
    Uint8List.fromList([4, 5, 6]),
  );
  final rotatedCustody = ProtectedInstallationState(
    '478b8ea0-adbd-4b4b-9bdf-2b034ce7bc8d',
    checkpointCustody.bytes,
  );
  final expectedProtected = <String, dynamic>{
    'baseProtectedRevision': checkpointBase.revision,
    'baseProtectedSha256': sha256.convert(checkpointBase.bytes).toString(),
    'custodyProtectedRevision': checkpointCustody.revision,
    'custodyProtectedSha256': sha256
        .convert(checkpointCustody.bytes)
        .toString(),
  };
  void verifyProtected(
    ProtectedInstallationState base,
    ProtectedInstallationState custody,
  ) => adapter.verifyJobDetailsCheckpointProtectedState(
    base: base,
    custody: custody,
    expected: expectedProtected,
  );
  test('checkpoint protected state accepts byte-identical custody after PIN revision rotation', () {
    expect(
      () => verifyProtected(checkpointBase, checkpointCustody),
      returnsNormally,
    );
    expect(
      () => verifyProtected(checkpointBase, rotatedCustody),
      returnsNormally,
    );
  });
  test('checkpoint protected state refuses changed custody bytes', () {
    for (final revision in [
      checkpointCustody.revision,
      rotatedCustody.revision,
    ]) {
      expect(
        () => verifyProtected(
          checkpointBase,
          ProtectedInstallationState(revision, Uint8List.fromList([4, 5, 7])),
        ),
        throwsA(isA<NativeTestFailure>()),
      );
    }
  });
  test('checkpoint protected state refuses changed base revision or bytes', () {
    for (final base in [
      ProtectedInstallationState(
        '11715385-1fb4-4b2d-984c-b46cd15291f4',
        checkpointBase.bytes,
      ),
      ProtectedInstallationState(
        checkpointBase.revision,
        Uint8List.fromList([1, 2, 4]),
      ),
    ]) {
      expect(
        () => verifyProtected(base, rotatedCustody),
        throwsA(isA<NativeTestFailure>()),
      );
    }
  });

  testWidgets(
    'checkpoint cleanup remounts the real locked gate after deadline without another action',
    (tester) async {
      final f = (await tester.runAsync(NameFixture.create))!;
      addTearDown(f.close);
      Future<void> mount(
        Future<void> Function(bool Function()) waitUntilReady,
      ) async {
        await tester.pumpWidget(
          WiredPartsApp(
            key: UniqueKey(),
            db: f.db,
            pin: PinService(f.db.settingsDao),
            deviceId: f.owner.identity.deviceId,
            installation: f.security,
            enableCompanyBootstrap: true,
          ),
        );
        await waitUntilReady(
          () => find.text('Company locked').evaluate().length == 1,
        );
      }

      await mount((ready) => native.ready(tester, ready));
      await tester.enterText(
        find.byKey(const Key('company-signin-pin')),
        '1234',
      );
      await native.tap(tester, find.byKey(const Key('company-signin')));
      await adapter.waitForJoinNativeSignInReady(
        waitUntilReady: (ready) => native.ready(tester, ready),
      );
      final uiSession = tester
          .widget<CompanyJobsPanel>(find.byType(CompanyJobsPanel))
          .owner;
      expect(uiSession.isValid, isTrue);
      final sql = await tester.runAsync(
        () => adapter.detailsNativeSqlHash(f.db),
      );
      final cache = command_test.Fixture();
      final wire = NativeTestCommand.encodeRequest(
        session: cache.localSession,
        sequence: 1,
        action: NativeTestAction.jobDetailsUi,
        deadlineMillis: 15000,
        jobDetailsStep: NativeJobDetailsUiStep.checkpointMixed,
      );
      cache.cache.submitJson(wire);
      final command = cache.cache.takeNext()!;
      cache.now = 20000;
      expect(
        () => adapter.validateJoinNativeDeadline(
          cache.now,
          command.deadlineMillis,
        ),
        throwsA(isA<NativeTestFailure>()),
      );
      await tester.runAsync(f.enrollment.signOut);
      // The gate owns its own session; signing out the adapter alone leaves it visible.
      expect(uiSession.isValid, isTrue);
      var pumps = 0;
      await adapter.completeJobDetailsNativeUiReturn(
        isStillCurrent: () => true,
        mountPage: mount,
        waitForCompletion: (ready) => adapter.waitForJoinNativeCompletion(
          ready: () => pumps >= 2 && ready(),
          elapsedMillis: () => cache.now,
          commandDeadlineMillis: command.deadlineMillis,
          pump: () async {
            pumps++;
            cache.now += 50;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            await tester.pump(const Duration(milliseconds: 25));
          },
        ),
      );
      expect(pumps, greaterThanOrEqualTo(2));
      expect(find.text('Company locked'), findsOneWidget);
      expect(find.byType(CompanyJobsPanel), findsNothing);
      expect(uiSession.isValid, isFalse);
      expect(
        await tester.runAsync(() => adapter.detailsNativeSqlHash(f.db)),
        sql,
      );
      final completed = cache.cache.complete(
        command,
        const NativeTestCommandResult.effect(),
      );
      expect(completed.state, NativeTestCommandState.completed);
      expect(cache.cache.submitJson(wire).toJson(), completed.toJson());
      expect(cache.cache.takeNext(), isNull);
      expect(
        cache.cache.submitJson(cache.request(2, deadline: 15000)).error,
        NativeTestCommandError.deadlineExpired,
      );
      for (final loseBeforeMount in [true, false]) {
        var current = !loseBeforeMount;
        var mounts = 0;
        await expectLater(
          adapter.completeJobDetailsNativeUiReturn(
            isStillCurrent: () => current,
            mountPage: (_) async {
              mounts++;
              current = false;
            },
            waitForCompletion: (_) async {},
          ),
          throwsA(isA<NativeTestFailure>()),
        );
        expect(mounts, loseBeforeMount ? 0 : 1);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('prior genuine checkpoint bridge pins exact seven-c source and protocol map', () {
    final checkpoint = <String, dynamic>{
      'sourceRevision': '7c41169845820ac03c0f9cd4fd9e40b8cb83ba53',
      'sourceTree': '34a7a9cd1f3f966f55663fc34b9f0f2e29b7efa3',
      'adapterSha256':
          'ae62b6a2fa353046a71faaea2e2a3f387278e7f21fd0964b83866ec4ff981786',
      'productRevision': '7c41169845820ac03c0f9cd4fd9e40b8cb83ba53',
      'detailsManifestSha256':
          '4ce106cbe1497c3a76e3c4c01173d27dd98cb7b2e6e71cee6ef75284ce090c67',
    };
    expect(adapter.validateDetailsPriorCheckpointSource(checkpoint), isTrue);
    for (final key in checkpoint.keys) {
      expect(
        () => adapter.validateDetailsPriorCheckpointSource({
          ...checkpoint,
          key: '0' * 64,
        }),
        throwsA(isA<NativeTestFailure>()),
      );
    }
    final previous = <String, dynamic>{
      for (var i = 0; i < 93; i++) 'app/lib/frozen$i.dart': 'a' * 64,
      'app/tool/native_nearby_test_commands.dart': 'b' * 64,
      'app/integration_test/company_join_native_test.dart': 'c' * 64,
    };
    final current = {
      ...previous,
      'app/integration_test/company_join_native_test.dart': 'd' * 64,
    };
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, current),
      returnsNormally,
    );
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, {
        ...current,
        'app/tool/native_nearby_test_commands.dart': 'e' * 64,
      }),
      throwsA(isA<NativeTestFailure>()),
    );
  });

  test(
    'interrupted mixed details admit signed two-way state after cold restart and refuse rehashed forgeries',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final f = await JoinFixture.create(allowOwnerAdditions: true);
      await activateFixtureB(f);
      var member = await f.bEnrollment.signIn('1234');
      await f.bDb.settingsDao.keepLocalDeviceId(member.identity.deviceId);
      final aCommands = CompanyJobCommands(enrollment: f.aEnrollment);
      var bCommands = CompanyJobCommands(enrollment: f.bEnrollment);
      await bCommands.createJob(
        CreateJob(
          companyId: member.identity.companyId,
          shopId: member.identity.shopId,
          jobId: const Uuid().v4(),
          requestId: const Uuid().v4(),
          name: 'Synthetic member mixed details',
        ),
        ownerSession: member,
      );
      final pair = await openSyncPair(f);
      final created = await pair.a.syncNow();
      expect([created.complete, created.sent, created.received], [true, 1, 1]);
      final original = (await f.bDb.select(f.bDb.companyJobs).get())
          .singleWhere((r) => r.outgoing);
      final views = await aCommands.listJobViews(ownerSession: f.owner);
      final selected =
          (views.toList()..sort((a, b) => a.baseJob.id.compareTo(b.baseJob.id)))
              .first;
      Future<void> patch(
        CompanyJobCommands commands,
        OwnerSession session,
        JobDetailsPatch patch,
        List<JobDetailField> fields,
      ) => commands
          .patchJobDetails(
            PatchJobDetails(
              companyId: session.identity.companyId,
              shopId: session.identity.shopId,
              jobId: selected.baseJob.id,
              requestId: const Uuid().v4(),
              creationDigest: selected.creationDigest,
              patch: patch,
              observedHeads: {for (final field in fields) field: []},
            ),
            ownerSession: session,
          )
          .then((_) {});
      await patch(
        aCommands,
        f.owner,
        const JobDetailsPatch(
          customer: SetField('Acme'),
          status: SetField(CompanyJobStatus.archived),
        ),
        [JobDetailField.customer, JobDetailField.status],
      );
      await patch(
        bCommands,
        member,
        const JobDetailsPatch(notes: SetField('Gate 3')),
        [JobDetailField.notes],
      );
      final mixed = await pair.a.syncNow();
      final repeat = await pair.a.syncNow();
      expect([mixed.complete, mixed.sent, mixed.received], [true, 1, 1]);
      expect([repeat.complete, repeat.sent, repeat.received], [true, 0, 0]);
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
      await pair.a.controller.dispose();
      await pair.b.controller.dispose();
      final sql = await adapter.detailsNativeSqlHash(f.bDb);
      final signed = await f.bDb.select(f.bDb.companyJobDetails).get();
      final base = (await f.bStore.readState(f.b.namespace))!;
      final custody = await f.bStore.readState(
        companyCustodyNamespace(f.b.namespace),
      );
      final binding = (await f.bDb.settingsDao.getSetting(
        kInstallationBindingKey,
      ))!;
      final identity = <String, Object?>{
        'installation': f.b.identity!.id.value,
        'generation': f.b.identity!.generation.value,
        'storeGeneration': f.b.receivingStoreGeneration!.value,
        'publicKeySha256': sha256.convert(f.b.identity!.publicKey).toString(),
        'company': member.identity.companyId,
        'shop': member.identity.shopId,
        'user': member.identity.userId,
        'device': member.identity.deviceId,
      };
      Future<void> headers(ProtectedInstallationState held) async {
        expect(
          (await adapter.verifyDetailsMixedNativeHeaders(
            db: f.bDb,
            base: held,
            custody: custody,
            binding: binding,
            databasePath: '${f.root.path}/b.sqlite',
            originalIdentity: identity,
            originalReceipt: original.receiptBytes,
            incomingOperations: (await f.bDb.select(f.bDb.companyJobs).get())
                .where((r) => !r.outgoing)
                .map((r) => r.operationCommitment)
                .toSet(),
          ))['detailsSealsVerified'],
          2,
        );
      }

      await headers(base);
      final nativeHeader =
          jsonDecode(utf8.decode(base.bytes)) as Map<String, dynamic>;
      final held = signed.first;
      for (final pending in [
        {'family': 'unknown'},
        CompanyCommandIntent(
          family: held.outgoing
              ? CompanyCommandFamily.jobDetails
              : CompanyCommandFamily.jobDetailsIncoming,
          receiptKey: held.receiptKey,
          operationCommitment: held.operationCommitment,
          commandCommitment: held.commandCommitment,
          storeGeneration: f.b.receivingStoreGeneration!.value,
          companyId: held.companyId,
          lineId: held.jobId,
          originGeneration: held.originGeneration,
          requestId: held.requestId,
        ).encode(),
      ]) {
        await expectLater(
          headers(
            ProtectedInstallationState(
              base.revision,
              Uint8List.fromList(
                utf8.encode(
                  jsonEncode({...nativeHeader, 'pendingCommand': pending}),
                ),
              ),
            ),
          ),
          throwsA(anything),
        );
        expect(await adapter.detailsNativeSqlHash(f.bDb), sql);
      }
      await f.reopenB();
      member = await f.bEnrollment.signIn('1234');
      bCommands = CompanyJobCommands(enrollment: f.bEnrollment);
      Future<void> verify() async => adapter.verifyDetailsMixedRecoveryRecords(
        enrollment: f.bEnrollment,
        owner: member,
        sqlSha256: await adapter.detailsNativeSqlHash(f.bDb),
        localCreation: {'record': original.toJson()},
      );
      await verify();
      expect(await adapter.detailsNativeSqlHash(f.bDb), sql);
      expect(await f.bDb.select(f.bDb.companyJobDetails).get(), signed);
      final after = (await bCommands.listJobViews(ownerSession: member))
          .singleWhere((v) => v.baseJob.id == selected.baseJob.id);
      expect(after.details.customer.value, 'Acme');
      expect(after.details.status.value, CompanyJobStatus.archived);
      expect(after.details.notes.value, 'Gate 3');
      final originalDb = raw.sqlite3.openInMemory();
      final currentDb = raw.sqlite3.open(
        '${f.root.path}/b.sqlite',
        mode: raw.OpenMode.readOnly,
      );
      try {
        final profile = currentDb
            .select('SELECT * FROM device_profiles')
            .single;
        originalDb.execute(
          'CREATE TABLE device_profiles (id TEXT, display_name TEXT, created_at INTEGER)',
        );
        originalDb.execute('INSERT INTO device_profiles VALUES (?, ?, ?)', [
          profile['id'],
          profile['display_name'],
          profile['created_at'],
        ]);
        originalDb.execute('CREATE TABLE app_settings (key TEXT, value TEXT)');
        originalDb.execute('INSERT INTO app_settings VALUES (?, ?)', [
          kInstallationBindingKey,
          binding,
        ]);
        Future<void> checkCold() async =>
            adapter.verifyDetailsMixedRecoveryDatabase(
              currentDb,
              original: originalDb,
              evidence: {
                'identity': identity,
                'sqlSha256': await adapter.detailsNativeSqlHash(f.bDb),
                'bindingSha256': digest(binding),
              },
            );
        expect(
          currentDb.select('PRAGMA user_version').single.values.single,
          11,
        );
        expect(
          currentDb.select(
            "SELECT name FROM sqlite_master WHERE type = 'table'",
          ),
          hasLength(34),
        );
        final currentSql = await adapter.detailsNativeSqlHash(f.bDb);
        await expectLater(checkCold(), throwsA(isA<NativeTestFailure>()));
        expect(await adapter.detailsNativeSqlHash(f.bDb), currentSql);
      } finally {
        currentDb.dispose();
        originalDb.dispose();
      }
      for (final attack in ['operation', 'receipt', 'ack']) {
        final detail = signed.first;
        final ack =
            (await f.bDb.select(f.bDb.companyJobDetailPeerAcks).get()).first;
        final table = attack == 'ack'
            ? 'company_job_detail_peer_acks'
            : 'company_job_details';
        final column = attack == 'operation'
            ? 'operation_bytes'
            : attack == 'receipt'
            ? 'receipt_bytes'
            : 'ack_bytes';
        final originalBytes = attack == 'operation'
            ? detail.operationBytes
            : attack == 'receipt'
            ? detail.receiptBytes
            : ack.ackBytes;
        final forged = jsonDecode(originalBytes) as Map<String, dynamic>;
        if (attack == 'operation') {
          (forged['body'] as Map)['user'] = const Uuid().v4();
        } else {
          forged[attack == 'receipt' ? 'seal' : 'signature'] = base64Encode(
            List<int>.filled(64, 0),
          );
        }
        final request = attack == 'ack' ? ack.requestId : detail.requestId;
        await f.bDb.customStatement(
          'UPDATE $table SET $column = ? WHERE request_id = ?',
          [jsonEncode(forged), request],
        );
        final changedSql = await adapter.detailsNativeSqlHash(f.bDb);
        await expectLater(verify(), throwsA(anything));
        expect(await adapter.detailsNativeSqlHash(f.bDb), changedSql);
        await f.bDb.customStatement(
          'UPDATE $table SET $column = ? WHERE request_id = ?',
          [originalBytes, request],
        );
      }
      expect(await adapter.detailsNativeSqlHash(f.bDb), sql);
      Future<Map<String, dynamic>> parentEvidence(
        CompanyJobCommands commands,
        OwnerSession session,
      ) async {
        final records = await commands.detailsSyncHoldings(
          ownerSession: session,
        );
        final acks = await commands.enrollment.db
            .select(commands.enrollment.db.companyJobDetailPeerAcks)
            .get();
        String recordsHash(Iterable<Map<String, dynamic>> rows) => digest(
          canonicalNameTest(rows.map(canonicalNameTest).toList()..sort()),
        );
        return {
          'detailsRecords': records
              .map((r) => {'operation': r.operationCommitment})
              .toList(),
          'detailsRecordsSha256': recordsHash(records.map((r) => r.toJson())),
          'detailsAckSha256': recordsHash(acks.map((r) => r.toJson())),
        };
      }

      final parentB = await parentEvidence(bCommands, member);
      final parentA = await parentEvidence(aCommands, f.owner);
      for (final item in [
        (bCommands, member, 'member'),
        (aCommands, f.owner, 'owner'),
      ]) {
        await item.$1.patchJobDetails(
          PatchJobDetails(
            companyId: item.$2.identity.companyId,
            shopId: item.$2.identity.shopId,
            jobId: selected.baseJob.id,
            requestId: const Uuid().v4(),
            creationDigest: selected.creationDigest,
            patch: JobDetailsPatch(
              notes: SetField(
                'Synthetic ${item.$3} notes ${adapter.jobDetailsNativeRun}',
              ),
            ),
            observedHeads: {JobDetailField.notes: after.details.notes.heads},
          ),
          ownerSession: item.$2,
        );
      }
      final pendingSql = await adapter.detailsNativeSqlHash(f.bDb);
      await f.reopenB();
      member = await f.bEnrollment.signIn('1234');
      await adapter.verifyDetailsPendingNotesRecoveryRecords(
        enrollment: f.bEnrollment,
        owner: member,
        sqlSha256: pendingSql,
        localCreation: {'record': original.toJson()},
        parent: parentB,
        role: 'member',
      );
      final originalA = (await f.aDb.select(f.aDb.companyJobs).get())
          .singleWhere((r) => r.outgoing);
      await adapter.verifyDetailsPendingNotesRecoveryRecords(
        enrollment: f.aEnrollment,
        owner: f.owner,
        sqlSha256: await adapter.detailsNativeSqlHash(f.aDb),
        localCreation: {'record': originalA.toJson()},
        parent: parentA,
        role: 'owner',
      );
      expect(await adapter.detailsNativeSqlHash(f.bDb), pendingSql);
      Future<void> verifyNotes({
        Map<String, dynamic>? parent,
        String role = 'member',
      }) async => adapter.verifyDetailsPendingNotesRecoveryRecords(
        enrollment: f.bEnrollment,
        owner: member,
        sqlSha256: await adapter.detailsNativeSqlHash(f.bDb),
        localCreation: {'record': original.toJson()},
        parent: parent ?? parentB,
        role: role,
      );
      await expectLater(verifyNotes(role: 'owner'), throwsA(anything));
      await expectLater(
        verifyNotes(parent: {...parentB, 'detailsRecordsSha256': '0' * 64}),
        throwsA(anything),
      );
      final history = await f.bDb.select(f.bDb.companyJobDetails).get();
      final added = history.singleWhere(
        (r) => !signed.any(
          (old) => old.operationCommitment == r.operationCommitment,
        ),
      );
      final noteBody = jsonDecode(added.operationBytes) as Map<String, dynamic>;
      (((noteBody['body'] as Map)['units'] as Map)['notes'] as Map)['parents'] =
          <String>[];
      expect(
        () => adapter.verifyDetailsPendingNotesHistory(
          history
              .map(
                (r) => r == added
                    ? r.copyWith(operationBytes: jsonEncode(noteBody))
                    : r,
              )
              .toList(),
          parent: parentB,
          identity: identity,
          role: 'member',
        ),
        throwsA(anything),
      );
      for (final attack in ['old-operation', 'notes-receipt', 'ack']) {
        final detail = attack == 'old-operation' ? signed.first : added;
        final ack =
            (await f.bDb.select(f.bDb.companyJobDetailPeerAcks).get()).first;
        final table = attack == 'ack'
            ? 'company_job_detail_peer_acks'
            : 'company_job_details';
        final column = attack == 'ack'
            ? 'ack_bytes'
            : attack == 'old-operation'
            ? 'operation_bytes'
            : 'receipt_bytes';
        final bytes = attack == 'ack'
            ? ack.ackBytes
            : attack == 'old-operation'
            ? detail.operationBytes
            : detail.receiptBytes;
        final forged = jsonDecode(bytes) as Map<String, dynamic>;
        if (attack == 'old-operation') {
          (forged['body'] as Map)['user'] = const Uuid().v4();
        } else {
          forged[attack == 'ack' ? 'signature' : 'seal'] = base64Encode(
            List<int>.filled(64, 0),
          );
        }
        final request = attack == 'ack' ? ack.requestId : detail.requestId;
        await f.bDb.customStatement(
          'UPDATE $table SET $column = ? WHERE request_id = ?',
          [jsonEncode(forged), request],
        );
        final changed = await adapter.detailsNativeSqlHash(f.bDb);
        await expectLater(verifyNotes(), throwsA(anything));
        expect(await adapter.detailsNativeSqlHash(f.bDb), changed);
        await f.bDb.customStatement(
          'UPDATE $table SET $column = ? WHERE request_id = ?',
          [bytes, request],
        );
      }
      final currentBase = (await f.bStore.readState(f.b.namespace))!;
      final currentCustody = await f.bStore.readState(
        companyCustodyNamespace(f.b.namespace),
      );
      Future<void> notesHeaders(ProtectedInstallationState held) async {
        expect(
          (await adapter.verifyDetailsMixedNativeHeaders(
            db: f.bDb,
            base: held,
            custody: currentCustody,
            binding: binding,
            databasePath: '${f.root.path}/b.sqlite',
            originalIdentity: identity,
            originalReceipt: original.receiptBytes,
            incomingOperations: {},
            notesParent: parentB,
            role: 'member',
          ))['detailsSealsVerified'],
          3,
        );
      }

      await notesHeaders(currentBase);
      final currentNative =
          jsonDecode(utf8.decode(currentBase.bytes)) as Map<String, dynamic>;
      final old = signed.first;
      final unrelated = CompanyCommandIntent(
        family: old.outgoing
            ? CompanyCommandFamily.jobDetails
            : CompanyCommandFamily.jobDetailsIncoming,
        receiptKey: old.receiptKey,
        operationCommitment: old.operationCommitment,
        commandCommitment: old.commandCommitment,
        storeGeneration: f.b.receivingStoreGeneration!.value,
        companyId: old.companyId,
        lineId: old.jobId,
        originGeneration: old.originGeneration,
        requestId: old.requestId,
        beforeWitness: '0' * 64,
        afterWitness: '0' * 64,
      );
      await expectLater(
        notesHeaders(
          ProtectedInstallationState(
            currentBase.revision,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  ...currentNative,
                  'pendingCommand': unrelated.encode(),
                }),
              ),
            ),
          ),
        ),
        throwsA(anything),
      );
      expect(await adapter.detailsNativeSqlHash(f.bDb), pendingSql);
    }, _LoopbackHttpOverrides()),
    timeout: const Timeout(Duration(minutes: 6)),
  );
  test(
    'pending local details survive cold admission with original signed creation and ACKs',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final f = await JoinFixture.create(allowOwnerAdditions: true);
      await activateFixtureB(f);
      var member = await f.bEnrollment.signIn('1234');
      final commands = CompanyJobCommands(enrollment: f.bEnrollment);
      await commands.createJob(
        CreateJob(
          companyId: member.identity.companyId,
          shopId: member.identity.shopId,
          jobId: const Uuid().v4(),
          requestId: const Uuid().v4(),
          name: 'Synthetic member pending details',
        ),
        ownerSession: member,
      );
      final pair = await openSyncPair(f);
      final synced = await pair.a.syncNow();
      expect([synced.complete, synced.sent, synced.received], [true, 1, 1]);
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
      await pair.a.controller.dispose();
      await pair.b.controller.dispose();
      final original = (await f.bDb.select(f.bDb.companyJobs).get())
          .singleWhere((r) => r.outgoing);
      final views = await commands.listJobViews(ownerSession: member);
      final selected =
          (views.toList()..sort((a, b) => a.baseJob.id.compareTo(b.baseJob.id)))
              .first;
      await commands.patchJobDetails(
        PatchJobDetails(
          companyId: member.identity.companyId,
          shopId: member.identity.shopId,
          jobId: selected.baseJob.id,
          requestId: const Uuid().v4(),
          creationDigest: selected.creationDigest,
          patch: const JobDetailsPatch(notes: SetField('Gate 3')),
          observedHeads: {JobDetailField.notes: []},
        ),
        ownerSession: member,
      );
      final saved = (await commands.detailsSyncHoldings(ownerSession: member))
          .single;
      final sql = await adapter.detailsNativeSqlHash(f.bDb);
      final base = (await f.bStore.readState(f.b.namespace))!;
      final custody = await f.bStore.readState(
        companyCustodyNamespace(f.b.namespace),
      );
      final binding = (await f.bDb.settingsDao.getSetting(
        kInstallationBindingKey,
      ))!;
      final identity = <String, Object?>{
        'installation': f.b.identity!.id.value,
        'generation': f.b.identity!.generation.value,
        'storeGeneration': f.b.receivingStoreGeneration!.value,
        'publicKeySha256': sha256.convert(f.b.identity!.publicKey).toString(),
        'company': member.identity.companyId,
        'shop': member.identity.shopId,
        'user': member.identity.userId,
        'device': member.identity.deviceId,
      };
      Future<void> headers(ProtectedInstallationState held) async {
        await adapter.verifyDetailsPendingNativeHeaders(
          db: f.bDb,
          base: held,
          custody: custody,
          binding: binding,
          databasePath: '${f.root.path}/b.sqlite',
          originalIdentity: identity,
          originalReceipt: original.receiptBytes,
          incomingOperations: (await f.bDb.select(f.bDb.companyJobs).get())
              .where((r) => !r.outgoing)
              .map((r) => r.operationCommitment)
              .toSet(),
        );
      }

      await headers(base);
      final native =
          jsonDecode(utf8.decode(base.bytes)) as Map<String, dynamic>;
      for (final pending in [
        {'family': 'unknown'},
        CompanyCommandIntent(
          family: CompanyCommandFamily.jobDetails,
          receiptKey: saved.receiptKey,
          operationCommitment: saved.operationCommitment,
          commandCommitment: saved.commandCommitment,
          storeGeneration: f.b.receivingStoreGeneration!.value,
          companyId: saved.companyId,
          lineId: saved.jobId,
          originGeneration: saved.originGeneration,
          requestId: saved.requestId,
        ).encode(),
        CompanyCommandIntent(
          family: CompanyCommandFamily.jobCreateIncoming,
          receiptKey: original.receiptKey,
          operationCommitment: original.operationCommitment,
          commandCommitment: original.commandCommitment,
          storeGeneration: f.b.receivingStoreGeneration!.value,
          companyId: original.companyId,
          lineId: original.jobId,
          originGeneration: original.originGeneration,
          requestId: original.requestId,
        ).encode(),
      ]) {
        await expectLater(
          headers(
            ProtectedInstallationState(
              base.revision,
              Uint8List.fromList(
                utf8.encode(jsonEncode({...native, 'pendingCommand': pending})),
              ),
            ),
          ),
          throwsA(anything),
        );
        expect(await adapter.detailsNativeSqlHash(f.bDb), sql);
        expect(
          (await f.bStore.readState(f.b.namespace))!.revision,
          base.revision,
        );
      }
      await f.reopenB();
      member = await f.bEnrollment.signIn('1234');
      await adapter.verifyDetailsPendingRecoveryRecords(
        enrollment: f.bEnrollment,
        owner: member,
        sqlSha256: sql,
        localCreation: {'record': original.toJson()},
        savedDetail: saved.toJson(),
        role: 'member',
      );
      final after = await CompanyJobCommands(enrollment: f.bEnrollment)
          .detailsSyncHoldings(ownerSession: member);
      expect(after.map((r) => r.toJson()), [saved.toJson()]);
      expect(await f.bDb.select(f.bDb.companyJobDetailPeerAcks).get(), isEmpty);
      expect(await adapter.detailsNativeSqlHash(f.bDb), sql);
      for (final column in [
        'receipt_bytes',
        'operation_bytes',
        'audit_bytes',
      ]) {
        final originalBytes = column == 'receipt_bytes'
            ? saved.receiptBytes
            : column == 'operation_bytes'
            ? saved.operationBytes
            : saved.auditBytes;
        final corrupt = jsonDecode(originalBytes) as Map<String, dynamic>;
        if (column == 'receipt_bytes') {
          corrupt['seal'] = base64Encode(List<int>.filled(64, 0));
        } else if (column == 'operation_bytes') {
          (corrupt['body'] as Map)['user'] = const Uuid().v4();
        } else {
          corrupt['forged'] = true;
        }
        await f.bDb.customStatement(
          'UPDATE company_job_details SET $column = ?',
          [jsonEncode(corrupt)],
        );
        final before = await adapter.detailsNativeSqlHash(f.bDb);
        final changed =
            (await f.bDb.select(f.bDb.companyJobDetails).get()).single;
        await expectLater(
          adapter.verifyDetailsPendingRecoveryRecords(
            enrollment: f.bEnrollment,
            owner: member,
            sqlSha256: before,
            localCreation: {'record': original.toJson()},
            savedDetail: changed.toJson(),
            role: 'member',
          ),
          throwsA(anything),
        );
        expect(await adapter.detailsNativeSqlHash(f.bDb), before);
        await f.bDb.customStatement(
          'UPDATE company_job_details SET $column = ?',
          [originalBytes],
        );
      }
      expect(await adapter.detailsNativeSqlHash(f.bDb), sql);
    }, _LoopbackHttpOverrides()),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('Notes archive replica is bound to member root and original closure inventory without writes', () {
    final temp = Directory.systemTemp.createTempSync('notes-archive-copy-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final parent = Directory(temp.resolveSymbolicLinksSync());
    final root = Directory(p.join(parent.path, 'isolated-member'))
      ..createSync();
    final original = Directory(p.join(parent.path, 'original-closed-archive'))
      ..createSync();
    final copy = Directory('${root.path}-notes-archive')..createSync();
    for (final archive in [original, copy]) {
      for (final name in [
        'support',
        'documents',
        'temporary',
        'cache',
        'library',
        'downloads',
        'receipts',
      ]) {
        Directory(p.join(archive.path, name)).createSync();
      }
      File(p.join(archive.path, 'support', 'wired_parts.sqlite'))
          .writeAsStringSync('immutable closed bytes');
    }
    final originalSql = File(
      p.join(original.path, 'support', 'wired_parts.sqlite'),
    );
    final copySql = File(p.join(copy.path, 'support', 'wired_parts.sqlite'));
    final files = [
      {
        'path': 'support/wired_parts.sqlite',
        'bytes': originalSql.lengthSync(),
        'sha256': digest(originalSql.readAsStringSync()),
      },
    ];
    const closure =
        '73f28bcafb43a3da1dd949cafb81032a33fd6f0cccbfd3cc9776b957b40d1b77';
    final binding = {'path': copy.path, 'closedReceiptSha256': closure};
    void verify({Object? archiveCopy, String role = 'member'}) =>
        adapter.verifyDetailsNotesArchive(
          root: root,
          originalArchive: original,
          role: role,
          closedReceiptSha256: closure,
          files: files,
          archiveCopy: archiveCopy,
        );
    expect(verify, returnsNormally);
    expect(() => verify(archiveCopy: binding), returnsNormally);
    for (final bad in [
      {...binding, 'path': original.path},
      {...binding, 'path': root.path},
      {...binding, 'path': p.join(root.path, 'nested-copy')},
      {...binding, 'path': p.join(parent.path, 'unbound-copy')},
      {...binding, 'path': 'relative-copy'},
      {...binding, 'closedReceiptSha256': '0' * 64},
      {...binding, 'extra': true},
    ]) {
      expect(() => verify(archiveCopy: bad), throwsA(isA<NativeTestFailure>()));
    }
    expect(
      () => verify(archiveCopy: binding, role: 'owner'),
      throwsA(isA<NativeTestFailure>()),
    );
    copySql.writeAsStringSync('changed closed bytes');
    expect(
      () => verify(archiveCopy: binding),
      throwsA(isA<NativeTestFailure>()),
    );
    copySql.writeAsStringSync('immutable closed bytes');
    final extra = File(p.join(copy.path, 'extra.json'))
      ..writeAsStringSync('{}');
    expect(
      () => verify(archiveCopy: binding),
      throwsA(isA<NativeTestFailure>()),
    );
    extra.deleteSync();
    copySql.deleteSync();
    expect(
      () => verify(archiveCopy: binding),
      throwsA(isA<NativeTestFailure>()),
    );
    copySql.writeAsStringSync('immutable closed bytes');
    expect(() => verify(archiveCopy: binding), returnsNormally);
    expect(originalSql.readAsStringSync(), 'immutable closed bytes');
    adapter.verifyDetailsPendingInventory(original, files);
  });

  test('pending cold inventory rejects missing extra changed duplicate and traversal members without writes', () {
    final root = Directory.systemTemp.createTempSync('pending-inventory-');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final name in [
      'documents',
      'temporary',
      'cache',
      'library',
      'downloads',
      'receipts',
    ]) {
      Directory(p.join(root.path, name)).createSync();
    }
    final support = Directory(p.join(root.path, 'support'))..createSync();
    final sql = File(p.join(support.path, 'wired_parts.sqlite'))
      ..writeAsStringSync('synthetic cold bytes');
    final files = [
      {
        'path': 'support/wired_parts.sqlite',
        'bytes': sql.lengthSync(),
        'sha256': digest(sql.readAsStringSync()),
      },
    ];
    adapter.verifyDetailsPendingInventory(root, files);
    Directory(p.join(root.path, 'cache')).deleteSync();
    expect(
      () => adapter.verifyDetailsPendingInventory(root, files),
      throwsA(anything),
    );
    Directory(p.join(root.path, 'cache')).createSync();
    final restore = File(p.join(support.path, 'restore_swap.marker'))
      ..writeAsStringSync('in-progress');
    expect(
      () => adapter.verifyDetailsPendingInventory(root, files),
      throwsA(anything),
    );
    restore.deleteSync();
    for (final entries in [
      <Map<String, Object?>>[],
      [...files, files.single],
      [
        {...files.single, 'path': '../wired_parts.sqlite'},
      ],
      [
        {...files.single, 'sha256': '0' * 64},
      ],
      [
        {...files.single, 'bytes': 1},
      ],
    ]) {
      expect(
        () => adapter.verifyDetailsPendingInventory(root, entries),
        throwsA(anything),
      );
      expect(sql.readAsStringSync(), 'synthetic cold bytes');
    }
    final extra = File(p.join(root.path, 'extra.json'))
      ..writeAsStringSync('{}');
    expect(
      () => adapter.verifyDetailsPendingInventory(root, files),
      throwsA(anything),
    );
    extra.deleteSync();
    sql.deleteSync();
    expect(
      () => adapter.verifyDetailsPendingInventory(root, files),
      throwsA(anything),
    );
    expect(sql.existsSync(), isFalse);
  });
  test('pre-kernel native headers require original identity, path and sealed creation proof', () async {
    final f = await NameFixture.create();
    addTearDown(f.close);
    final base = await f.store.readState(f.security.namespace);
    final custody = await f.store.readState(
      companyCustodyNamespace(f.security.namespace),
    );
    final binding = (await f.db.settingsDao.getSetting(
      kInstallationBindingKey,
    ))!;
    final record = (await f.db.select(f.db.companyJobs).get()).single;
    final identity = <String, Object?>{
      'installation': f.security.identity!.id.value,
      'generation': f.security.identity!.generation.value,
      'storeGeneration': f.security.receivingStoreGeneration!.value,
      'publicKeySha256': sha256
          .convert(f.security.identity!.publicKey)
          .toString(),
      'company': f.owner.identity.companyId,
      'shop': f.owner.identity.shopId,
      'user': f.owner.identity.userId,
      'device': f.owner.identity.deviceId,
    };
    Future<Map<String, Object?>> verify({
      ProtectedInstallationState? heldBase,
      bool missingBase = false,
      String? path,
      String? receipt,
      Map<String, Object?>? expected,
    }) => adapter.verifyDetailsBaselineNativeHeaders(
      base: missingBase ? null : heldBase ?? base,
      custody: custody,
      binding: binding,
      databasePath: path ?? '${f.root.path}/shop.sqlite',
      originalIdentity: expected ?? identity,
      originalReceipt: receipt ?? record.receiptBytes,
      incomingOperations: {},
    );
    final beforeSql = await adapter.detailsNativeSqlHash(f.db);
    expect((await verify())['hashesAreIndependentAnchor'], isFalse);
    await expectLater(verify(missingBase: true), throwsA(anything));
    await expectLater(
      verify(expected: {...identity, 'installation': const Uuid().v4()}),
      throwsA(anything),
    );
    await expectLater(
      verify(expected: {...identity, 'publicKeySha256': '0' * 64}),
      throwsA(anything),
    );
    final changedReceipt =
        jsonDecode(record.receiptBytes) as Map<String, dynamic>;
    changedReceipt['seal'] = base64Encode(List<int>.filled(64, 0));
    await expectLater(
      verify(receipt: jsonEncode(changedReceipt)),
      throwsA(anything),
    );
    await expectLater(
      verify(path: '${f.root.path}/authority.wpca'),
      throwsA(anything),
    );
    for (final family in [
      CompanyCommandFamily.jobDetails,
      CompanyCommandFamily.jobCreateIncoming,
    ]) {
      final native =
          jsonDecode(utf8.decode(base!.bytes)) as Map<String, dynamic>;
      native['pendingCommand'] = CompanyCommandIntent(
        family: family,
        receiptKey: record.receiptKey,
        operationCommitment: '0' * 64,
        commandCommitment: record.commandCommitment,
        storeGeneration: f.security.receivingStoreGeneration!.value,
        companyId: f.owner.identity.companyId,
        lineId: record.jobId,
        originGeneration: record.originGeneration,
        requestId: record.requestId,
      ).encode();
      await expectLater(
        verify(
          heldBase: ProtectedInstallationState(
            base.revision,
            Uint8List.fromList(utf8.encode(jsonEncode(native))),
          ),
        ),
        throwsA(anything),
      );
    }
    expect(await adapter.detailsNativeSqlHash(f.db), beforeSql);
    expect(
      (await f.store.readState(f.security.namespace))!.revision,
      base!.revision,
    );
    expect(
      (await f.store.readState(companyCustodyNamespace(f.security.namespace)))!
          .revision,
      custody!.revision,
    );
  });

  test(
    'baseline typed recovery verifies both creation receipts and rejects forged ACK signature',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final f = await JoinFixture.create(allowOwnerAdditions: true);
      await activateFixtureB(f);
      final member = await f.bEnrollment.signIn('1234');
      await CompanyJobCommands(enrollment: f.bEnrollment).createJob(
        CreateJob(
          companyId: member.identity.companyId,
          shopId: member.identity.shopId,
          jobId: const Uuid().v4(),
          requestId: const Uuid().v4(),
          name: 'Synthetic member baseline',
        ),
        ownerSession: member,
      );
      final pair = await openSyncPair(f);
      addTearDown(() async {
        await pair.a.closeAndDrain();
        await pair.b.closeAndDrain();
        await pair.a.controller.dispose();
        await pair.b.controller.dispose();
      });
      final result = await pair.a.syncNow();
      expect(
        result.complete,
        isTrue,
        reason: result.failure == null
            ? 'no failure reported'
            : '${result.failure!.stage.name}/${result.failure!.reason.name}',
      );
      expect([result.sent, result.received], [1, 1]);
      final original = (await f.aDb.select(f.aDb.companyJobs).get())
          .singleWhere((r) => r.outgoing);
      Future<void> verify() async =>
          adapter.verifyDetailsBaselineRecoveryRecords(
            enrollment: f.aEnrollment,
            owner: f.owner,
            sqlSha256: await adapter.detailsNativeSqlHash(f.aDb),
            localCreation: {'record': original.toJson()},
          );
      await verify();
      final ack = (await f.aDb.select(f.aDb.companyJobPeerAcks).get()).first;
      final forged = jsonDecode(ack.ackBytes) as Map<String, dynamic>;
      forged['signature'] = base64Encode(List<int>.filled(64, 0));
      await f.aDb.customStatement(
        'UPDATE company_job_peer_acks SET ack_bytes = ? WHERE request_id = ?',
        [jsonEncode(forged), ack.requestId],
      );
      final before = await adapter.detailsNativeSqlHash(f.aDb);
      await expectLater(verify(), throwsA(anything));
      expect(await adapter.detailsNativeSqlHash(f.aDb), before);
    }, _LoopbackHttpOverrides()),
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'same-v3 baseline recovery pins origin and refuses other source lineage',
    () {
      final origin = <String, dynamic>{
        'revision': '6a417521bb80ed6614ef5a5ef71f7158c6e0f929',
        'tree': 'a3f403d4d8dfa4bcb630d481e006a722e5d9a3cd',
        'adapterSha256':
            'ae534fe3996ff64de481bf5364a9adbb1575b70f066c85a53bccde41929be8dd',
        'productRevision': '6a417521bb80ed6614ef5a5ef71f7158c6e0f929',
        'manifestSha256':
            '188758e654d61748851a82f7800ba02225f364d089e3b7f1308343d5fc196c39',
      };
      expect(
        () => adapter.validateDetailsBaselineRecoveryOrigin(origin),
        returnsNormally,
      );
      for (final key in origin.keys) {
        expect(
          () => adapter.validateDetailsBaselineRecoveryOrigin({
            ...origin,
            key: '0' * (origin[key] as String).length,
          }),
          throwsA(isA<NativeTestFailure>()),
        );
      }
      expect(
        () => adapter.validateDetailsBaselineRecoveryOrigin({
          ...origin,
          'extra': true,
        }),
        throwsA(isA<NativeTestFailure>()),
      );
    },
  );
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('details-admission-');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('v3 baseline admits only frozen non-saving inspect20 and matching shared baseline', () {
    for (final role in ['owner', 'member']) {
      final root = Directory(p.join(temp.path, role))..createSync();
      final fixture = _BaselineInspectionFixture(root, role);
      expect(fixture.verify, returnsNormally);
    }
  });

  test('v3 baseline rejects rehashed saved, inconsistent or wrong-origin inspection evidence without writes', () {
    final attacks = <void Function(_BaselineInspectionFixture)>[
      (f) => f.inspection['step'] = 'editMixedOffline',
      (f) => f.inspection['savedThroughProductionUi'] = true,
      (f) => f.inspection['passed'] = true,
      (f) => f.inspection['companyControllerStoppedDuringUi'] = false,
      (f) => f.inspection['detailsOperationCount'] = 1,
      (f) => f.inspection['detailsReceiptCountVerified'] = 1,
      (f) => f.inspection['detailsAckCount'] = 1,
      (f) => f.inspection['nameOperationCount'] = 1,
      (f) => f.inspection['nameAckCount'] = 1,
      (f) => f.inspection['receiptCountVerified'] = 1,
      (f) => f.inspection['ackCount'] = 1,
      (f) => f.inspection['receiptVerification'] = 'locked-not-performed',
      (f) => f.inspection['sqlSha256'] = '0' * 64,
      (f) => f.inspection['identity'] = {
        ...f.inspection['identity'] as Map,
        'device': 'adopted',
      },
      (f) => f.shared['selectedJob'] = 'job-b',
      (f) => f.shared['creationDigest'] = '0' * 64,
      (f) => f.shared['creationHistorySha256'] = '0' * 64,
      (f) => f.shared['nameRecordsSha256'] = '0' * 64,
      (f) => f.shared['sourceRevision'] = '0' * 40,
      (f) => f.shared['detailsManifestSha256'] = '0' * 64,
      (f) => f.shared['role'] = 'member',
      (f) => f.inspection['pid'] = 35228,
      (f) => f.shared['extra'] = true,
      (f) => (f.inspection['confirmedPeerCounts'] as Map)['job-a'] = 0,
      (f) =>
          (((f.inspection['detailsViews'] as List).first as Map)['fields']
              as Map)['notes']['heads'] = [
            'invented',
          ],
      (f) =>
          (((f.inspection['detailsViews'] as List).first as Map)['fields']
                  as Map)['notes']['value'] =
              'hidden edit',
    ];
    for (var i = 0; i < attacks.length; i++) {
      final root = Directory(p.join(temp.path, 'attack-$i'))..createSync();
      final f = _BaselineInspectionFixture(root, 'owner');
      attacks[i](f);
      f.freeze(); // Reach semantic verification, rather than a stale file hash.
      final before = {
        for (final file in root.listSync().cast<File>())
          file.path: digest(file.readAsStringSync()),
      };
      expect(f.verify, throwsA(anything), reason: 'attack $i');
      expect({
        for (final file in root.listSync().cast<File>())
          file.path: digest(file.readAsStringSync()),
      }, before);
    }
  });

  test('v3 baseline refuses missing, modified, extra or unpinned inspection members', () {
    final root = Directory(p.join(temp.path, 'files'))..createSync();
    final f = _BaselineInspectionFixture(root, 'owner');
    final files = f.recovery['files'] as List;
    File(p.join(root.path, f.sharedName)).writeAsStringSync('{}');
    expect(f.verify, throwsA(anything));
    f.freeze();
    File(p.join(root.path, f.inspectName)).deleteSync();
    expect(f.verify, throwsA(anything));
    f.freeze();
    files.removeLast();
    expect(f.verify, throwsA(anything));
    for (final extra in [
      'details-ui-33960-21.json',
      'details-ui-87978-20.json',
      'details-shared-baseline-member.json',
      'join-details-checkpoint-33960-21.json',
    ]) {
      f.freeze();
      files.add({'path': extra, 'bytes': 2, 'sha256': digest('{}')});
      expect(f.verify, throwsA(anything), reason: extra);
    }
    f.freeze();
    files.add(Map<String, dynamic>.from(files.first as Map));
    expect(f.verify, throwsA(anything));
  });

  test('pinned origin shared baseline stays exact beside later checkpoint-stage files', () {
    final root = Directory(p.join(temp.path, 'later'))..createSync();
    final f = _BaselineInspectionFixture(root, 'owner');
    File(p.join(root.path, 'details-ui-99999-3.json')).writeAsStringSync(
      jsonEncode({'step': 'checkpointMixed', 'syntheticTestOnly': true}),
    );
    // Later checkpoint admission verifies its own new files. These are not
    // adopted into the frozen recovery inventory or used as baseline evidence.
    final baseline = adapter.verifyDetailsBaselineInspection(root, f.recovery);
    expect(baseline, f.shared);
    expect(
      baseline['sourceRevision'],
      '6a417521bb80ed6614ef5a5ef71f7158c6e0f929',
    );
    File(
      p.join(root.path, f.sharedName),
    ).writeAsStringSync(jsonEncode({...f.shared, 'sourceRevision': 'f' * 40}));
    expect(f.verify, throwsA(anything));
  });

  test('source lineage admits only one pinned company page update', () {
    const adapterPath = 'app/integration_test/company_join_native_test.dart';
    const pagePath = 'app/lib/features/company/company_join_page.dart';
    const protocolPath = 'app/lib/features/company/company_protocol.dart';
    const oldPageHash =
        'bdaf55a859223548b146b51489e1dd53284cff160710c5a5f5dcd1456c440baf';
    const candidatePageHash =
        '9576ed1dbaf0764b5623c455a702b0540afdbf14738f47c73b3dc3c436278da2';
    final previous = <String, dynamic>{
      for (var i = 0; i < 92; i++)
        'app/lib/features/source_fixture_$i.dart': digest('source-$i'),
      protocolPath: digest('company protocol'),
      adapterPath: digest('previous adapter'),
      pagePath: oldPageHash,
    };
    final unchanged = <String, dynamic>{
      ...previous,
      adapterPath: digest('current adapter'),
    };
    final candidate = <String, dynamic>{
      ...unchanged,
      pagePath: candidatePageHash,
    };

    expect(previous.length, 95);
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, unchanged),
      returnsNormally,
    );
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, candidate),
      returnsNormally,
    );
    expect(
      () => adapter.validateJobDetailsSourceLineage(candidate, unchanged),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, {
        ...candidate,
        pagePath: digest('unreviewed page'),
      }),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, {
        ...candidate,
        protocolPath: digest('changed company protocol'),
      }),
      throwsA(isA<NativeTestFailure>()),
    );
    final missing = Map<String, dynamic>.from(candidate)..remove(protocolPath);
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, missing),
      throwsA(isA<NativeTestFailure>()),
    );
    final extra = Map<String, dynamic>.from(candidate)
      ..['app/lib/features/company/unpinned.dart'] = digest('extra source');
    expect(
      () => adapter.validateJobDetailsSourceLineage(previous, extra),
      throwsA(isA<NativeTestFailure>()),
    );
  });

  test('frozen source bundle verifies inside copied container location', () {
    final paths = [
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
    ];
    paths.addAll([
      for (var i = paths.length; i < 95; i++) 'app/lib/frozen_source_$i.dart',
    ]);
    for (final path in paths) {
      final file = File(p.join(temp.path, 'source', path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('frozen\r\n');
    }
    final sourceHash = digest('frozen\n');
    final manifest = File(p.join(temp.path, 'manifest.json'));
    final value = {
      'format': 1,
      'kind': 'j116.details.source@1',
      'run': adapter.jobDetailsNativeRun,
      'revision': 'a' * 40,
      'tree': 'b' * 40,
      'adapterSha256': sourceHash,
      'productRevision': 'a' * 40,
      'sourceLfSha256': {for (final path in paths) path: sourceHash},
    };
    manifest.writeAsStringSync(jsonEncode(value));
    final manifestHash = digest(manifest.readAsStringSync());
    void validate({String? hash}) =>
        adapter.validateJobDetailsNativeSourceManifest(
          manifest: manifest,
          manifestSha256: hash ?? manifestHash,
          revision: 'a' * 40,
          tree: 'b' * 40,
          adapter: sourceHash,
          productRevision: 'a' * 40,
        );
    expect(validate, returnsNormally);
    final savedContext = <String, String>{
      'revision': 'a' * 40,
      'tree': 'b' * 40,
      'adapterSha256': sourceHash,
      'productRevision': 'a' * 40,
      'manifestSha256': manifestHash,
    };
    void validatePair(Map<String, String> current) =>
        adapter.validateDetailsNotesSourceManifests(
          savedManifest: manifest,
          savedSource: savedContext,
          currentManifest: manifest,
          currentSource: current,
        );
    expect(() => validatePair(savedContext), returnsNormally);
    final changedSource = File(p.join(temp.path, 'source', paths.first));
    changedSource.writeAsStringSync('changed product\n');
    final currentValue = {
      ...value,
      'revision': 'c' * 40,
      'tree': 'd' * 40,
      'productRevision': 'c' * 40,
      'sourceLfSha256': {
        ...value['sourceLfSha256'] as Map,
        paths.first: digest('changed product\n'),
      },
    };
    manifest.writeAsStringSync(jsonEncode(currentValue));
    final currentContext = {
      ...savedContext,
      'revision': 'c' * 40,
      'tree': 'd' * 40,
      'productRevision': 'c' * 40,
      'manifestSha256': digest(manifest.readAsStringSync()),
    };
    expect(
      () => adapter.validateJobDetailsNativeSourceManifest(
        manifest: manifest,
        manifestSha256: currentContext['manifestSha256']!,
        revision: currentContext['revision']!,
        tree: currentContext['tree']!,
        adapter: sourceHash,
        productRevision: currentContext['productRevision']!,
      ),
      returnsNormally,
    );
    expect(
      () => validatePair(currentContext),
      throwsA(isA<NativeTestFailure>()),
    );
    changedSource.writeAsStringSync('frozen\r\n');
    manifest.writeAsStringSync(jsonEncode(value));
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(value),
    );
    expect(validate, throwsA(isA<NativeTestFailure>()));
    manifest.writeAsStringSync(jsonEncode(value));
    final edited = File(p.join(temp.path, 'source', paths.first));
    edited.writeAsStringSync('changed\n');
    expect(validate, throwsA(isA<NativeTestFailure>()));
    edited.writeAsStringSync('frozen\n');
    expect(validate, returnsNormally);
    final extra = File(p.join(temp.path, 'source', 'unexpected.dart'))
      ..writeAsStringSync('extra');
    expect(validate, throwsA(isA<NativeTestFailure>()));
    extra.deleteSync();
    expect(() => validate(hash: '0' * 64), throwsA(isA<NativeTestFailure>()));
    manifest.writeAsStringSync(
      jsonEncode({...value, 'run': adapter.createdJobNativeRun}),
    );
    expect(
      () => validate(hash: digest(manifest.readAsStringSync())),
      throwsA(isA<NativeTestFailure>()),
    );
  });

  test('details root rejects retired roots, unfinished state and absent checkpoint without writes', () {
    final nativeTemp = Directory(temp.resolveSymbolicLinksSync());
    final root = Directory(
      p.join(
        nativeTemp.path,
        'wired-parts-lan-company-${adapter.jobDetailsNativeRun}-sender',
      ),
    );
    adapter.JoinNativeRootAdmission admit(
      Directory target, {
      String path = '',
      String hash = '',
    }) => adapter.validateJobDetailsNativeRootAdmission(
      target,
      run: adapter.jobDetailsNativeRun,
      role: 'owner',
      revision: 'a' * 40,
      tree: 'b' * 40,
      adapter: 'c' * 64,
      productRevision: 'a' * 40,
      manifestSha256: 'd' * 64,
      checkpointPath: path,
      checkpointSha256: hash,
      temporaryDirectory: nativeTemp,
    );
    expect(admit(root).stage, adapter.JoinNativeRootStage.fresh);
    expect(root.existsSync(), isFalse);
    final retired = Directory(
      p.join(
        nativeTemp.path,
        'wired-parts-lan-company-${adapter.createdJobNativeRun}-sender',
      ),
    );
    expect(() => admit(retired), throwsA(isA<NativeTestFailure>()));
    final retiredDetails = Directory(
      p.join(nativeTemp.path, 'wired-parts-lan-company-j116-details-v1-sender'),
    )..createSync();
    final retiredEvidence = File(p.join(retiredDetails.path, 'preserved.json'))
      ..writeAsStringSync('preserved');
    expect(() => admit(retiredDetails), throwsA(isA<NativeTestFailure>()));
    expect(retiredEvidence.readAsStringSync(), 'preserved');
    root.createSync();
    final preserved = File(p.join(root.path, 'failed-evidence.json'))
      ..writeAsStringSync('preserved');
    expect(() => admit(root), throwsA(isA<NativeTestFailure>()));
    final checkpoint =
        File(p.join(root.path, 'join-details-checkpoint-1-1.json'))
          ..writeAsStringSync(
            jsonEncode({'format': 1, 'run': adapter.createdJobNativeRun}),
          );
    final before = checkpoint.readAsBytesSync();
    expect(
      () => admit(
        root,
        path: checkpoint.path,
        hash: sha256.convert(before).toString(),
      ),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(checkpoint.readAsBytesSync(), before);
    expect(preserved.readAsStringSync(), 'preserved');
  });

  test(
    'cold readback refuses changed details, family ACKs or immutable history',
    () {
      final evidence = <String, Object?>{
        'identity': {'device': 'a'},
        'counts': {'company_job_details': 4},
        'schema': 10,
        'jobHistorySha256': '1' * 64,
        'receiptSha256': '2' * 64,
        'ackCount': 2,
        'ackSha256': '3' * 64,
        'nameOperationCount': 0,
        'nameReceiptCountVerified': 0,
        'nameRecordsSha256': '4' * 64,
        'nameAckCount': 0,
        'nameAckSha256': '5' * 64,
        'nameViews': [],
        'detailsOperationCount': 4,
        'detailsReceiptCountVerified': 4,
        'detailsRecordsSha256': '6' * 64,
        'detailsAckCount': 4,
        'detailsAckSha256': '7' * 64,
        'detailsViews': [
          {
            'notes': {'hasConflict': true, 'lastAgreedValue': 'Gate 3'},
          },
        ],
        'confirmedPeerCounts': {'job': 1},
        'detailsReceiptVerification': 'typed-public-verifier',
        'nameReceiptVerification': 'typed-public-verifier',
        'receiptVerification': 'typed-public-verifier',
        'ackVerification': 'confirmedPeerCounts',
      };
      final checkpoint = <String, dynamic>{'detailsEvidence': evidence};
      expect(
        () => adapter.verifyJobDetailsNativeReadback(checkpoint, evidence),
        returnsNormally,
      );
      for (final change in <Map<String, Object?>>[
        {'detailsViews': []},
        {'detailsAckCount': 3},
        {'jobHistorySha256': '0' * 64},
        {'nameRecordsSha256': '0' * 64},
        {'detailsReceiptCountVerified': 3},
        {'receiptVerification': 'locked-not-performed'},
      ]) {
        expect(
          () => adapter.verifyJobDetailsNativeReadback(checkpoint, {
            ...evidence,
            ...change,
          }),
          throwsA(isA<NativeTestFailure>()),
        );
      }
    },
  );
}
