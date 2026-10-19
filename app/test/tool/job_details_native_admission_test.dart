import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_crypto.dart';
import '../features/company/company_job_name_test.dart' show NameFixture;
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
    const adapterPath =
        'app/integration_test/company_join_native_test.dart';
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
