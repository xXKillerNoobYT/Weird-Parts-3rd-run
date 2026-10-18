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

void main() {
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
    'same-v2 baseline recovery pins origin and refuses other source lineage',
    () {
      final origin = <String, dynamic>{
        'revision': 'ab710d81811eda567a2920a7557a5df52685c9af',
        'tree': '073ecdf226dd4e57da25714c401e4edcdaad4302',
        'adapterSha256':
            'cb4c521e610aaa9ccd4121ff231114c82f02dea28fe4e3ed53609c7d4b831f4c',
        'productRevision': 'ab710d81811eda567a2920a7557a5df52685c9af',
        'manifestSha256':
            'd4791cb60877b78caad3680366eadb7408727dd463ab19ed9e763692e5349860',
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
