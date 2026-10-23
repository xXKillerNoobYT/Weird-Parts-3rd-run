@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import '../features/company/company_job_name_test.dart' show canonicalNameTest;
import '../features/company/company_job_test_support.dart' show JobTestStore;
import '../features/company/company_join_test.dart'
    show JoinFixture, activateFixtureB, sqlSnapshot;
import '../features/company/company_created_job_sync_test.dart'
    show openSyncPair;
import '../features/company/company_job_lifecycle_sync_test.dart' show deletion;

void main() {
  test('valid member device subset without lifecycle refuses incoming while user retains right', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    addTearDown(f.closeAndCheckOwnerData);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    addTearDown(() async {
      await pair.a.closeAndDrain();
      await pair.b.closeAndDrain();
    });
    final ac = CompanyJobCommands(enrollment: f.aEnrollment);
    final bc = CompanyJobCommands(enrollment: f.bEnrollment);
    final creation = (await f.aDb.select(f.aDb.companyJobs).get()).single;
    await bc.applyIncomingCreate(
      Uint8List.fromList(utf8.encode(creation.operationBytes)),
      ownerSession: pair.ownerB,
      availability: pair.b.availability,
    );
    final view = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
    await bc.setJobLifecycle(
      deletion(view, pair.ownerB),
      ownerSession: pair.ownerB,
    );
    final op = jsonDecode(
      (await f.bDb.select(f.bDb.companyJobLifecycles).get())
          .single
          .operationBytes,
    ) as Map<String, dynamic>;
    final proof = op['authorization'] as Map<String, dynamic>;
    final certificate =
        jsonDecode(proof['membership'] as String) as Map<String, dynamic>;
    final capabilities =
        ((certificate['body'] as Map)['recipient'] as Map)['capabilities']
            as List;
    final originalCapabilities = List<Object?>.from(capabilities);
    expect(capabilities.where((c) => c == 'manageJobLifecycle'), hasLength(1));
    capabilities.remove('manageJobLifecycle');
    expect(
      capabilities,
      originalCapabilities.where((c) => c != 'manageJobLifecycle').toList(),
    );
    final aState =
        jsonDecode(utf8.decode(f.aStore.states[f.a.namespace]!.bytes)) as Map;
    final issuerKey = await Ed25519().newKeyPairFromSeed(
      base64Decode(aState['seed'] as String),
    );
    certificate['signature'] = base64Encode(
      (await Ed25519().sign(
        utf8.encode(
          'wiredpart.company.device.enroll@1:${canonicalNameTest(certificate['body'])}',
        ),
        keyPair: issuerKey,
      )).bytes,
    );
    proof['membership'] = canonicalNameTest(certificate);
    (proof['body'] as Map)['membership'] = hash.sha256
        .convert(utf8.encode(canonicalNameTest(certificate)))
        .toString();
    final bState =
        jsonDecode(utf8.decode(f.bStore.states[f.b.namespace]!.bytes)) as Map;
    final memberKey = await Ed25519().newKeyPairFromSeed(
      base64Decode(bState['seed'] as String),
    );
    proof['signature'] = base64Encode(
      (await Ed25519().sign(
        utf8.encode(
          'wiredpart.job.lifecycle.authorization@2:${canonicalNameTest(proof['body'])}',
        ),
        keyPair: memberKey,
      )).bytes,
    );
    final member = await resolveCompanyMembership(
      db: f.bDb,
      installation: f.b,
      certificateBytes: canonicalNameTest(certificate),
    );
    expect(member.user['capabilities'], contains('manageJobLifecycle'));
    expect(
      member.device['capabilities'],
      isNot(contains('manageJobLifecycle')),
    );
    Map<String, Object?> protectedSnapshot() => {
      for (final (store, namespace) in [
        (f.aStore, f.a.namespace),
        (f.bStore, f.b.namespace),
      ])
        for (final key in [namespace, companyCustodyNamespace(namespace)])
          key: {
            'revision': store.states[key]!.revision,
            'sha256': hash.sha256.convert(store.states[key]!.bytes).toString(),
          },
    };
    final sqlA = await sqlSnapshot(f.aDb), sqlB = await sqlSnapshot(f.bDb);
    final protected = protectedSnapshot();
    await expectLater(
      ac.applyIncomingLifecycle(
        Uint8List.fromList(utf8.encode(canonicalNameTest(op))),
        ownerSession: f.owner,
        availability: pair.a.availability,
      ),
      throwsA(
        isA<JobLineRefusal>().having(
          (e) => e.reason,
          'family-specific refusal',
          'Job lifecycle unavailable. Existing company authority needs an explicit capability upgrade.',
        ),
      ),
    );
    expect(await sqlSnapshot(f.aDb), sqlA);
    expect(await sqlSnapshot(f.bDb), sqlB);
    expect(protectedSnapshot(), protected);
    expect((await f.aDb.select(f.aDb.companyJobs).get()).single, creation);
    expect(await f.aDb.select(f.aDb.companyJobLifecycles).get(), isEmpty);
    expect(
      await f.aDb.select(f.aDb.companyJobLifecyclePeerAcks).get(),
      isEmpty,
    );
  });

  test('compatible symmetric root profile missing lifecycle refuses without effects', () async {
    final root = Directory.systemTemp.createTempSync('lifecycle-capability-');
    final db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/shop.sqlite')),
    );
    addTearDown(() async {
      await db.close();
      root.deleteSync(recursive: true);
    });
    final store = JobTestStore();
    final security = InstallationSecurity(
      store: store,
      namespace: 'synthetic.lifecycle-capability',
    );
    await security.start(db);
    final enrollment = CompanyEnrollment(db: db, installation: security);
    final identity = await enrollment.create(
      companyName: 'Synthetic capability boundary',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'synthetic capability authority',
      recoveryFile: File('${root.path}/authority.wpca'),
    );

    // Reuse the fresh root-signed v2 fixture recipe in company_enrollment_test.
    // Unlike recovery, this remains authority1/v2/empty entities throughout.
    final original = (await db.select(db.companyAuthorityFacts).get()).single;
    final signed = jsonDecode(original.signedBytes) as Map<String, dynamic>;
    final facts = signed['body'] as Map<String, dynamic>;
    expect(facts['v'], 2);
    expect(facts['authority'], 1);
    expect(facts['entities'], isEmpty);
    for (final key in ['users', 'devices']) {
      final capabilities =
          ((facts[key] as List).single['capabilities'] as List);
      final originalCapabilities = List<Object?>.from(capabilities);
      expect(
        capabilities.where((c) => c == 'manageJobLifecycle'),
        hasLength(1),
      );
      capabilities.remove('manageJobLifecycle');
      expect(
        capabilities,
        originalCapabilities.where((c) => c != 'manageJobLifecycle').toList(),
      );
    }
    final commitment = hash.sha256
        .convert(utf8.encode(canonicalNameTest(facts)))
        .toString();
    final custodyNamespace = companyCustodyNamespace(security.namespace);
    final custodyState = store.states[custodyNamespace]!;
    final custody =
        jsonDecode(utf8.decode(custodyState.bytes)) as Map<String, dynamic>;
    final rootKey = await Ed25519().newKeyPairFromSeed(
      base64Decode(custody['rootSeed'] as String),
    );
    final signature = await Ed25519().sign(
      utf8.encode('wiredpart.company.facts@2:${canonicalNameTest(facts)}'),
      keyPair: rootKey,
    );
    await db.customStatement(
      'UPDATE company_authority_facts SET commitment = ?, signed_bytes = ? WHERE company_id = ?',
      [
        commitment,
        canonicalNameTest({
          'body': facts,
          'signature': base64Encode(signature.bytes),
        }),
        identity.companyId,
      ],
    );
    await db.customStatement(
      'UPDATE company_bootstrap_witnesses SET facts_commitment = ? WHERE company_id = ?',
      [commitment, identity.companyId],
    );
    custody['facts'] = commitment;
    store.states[custodyNamespace] = ProtectedInstallationState(
      const Uuid().v4(),
      Uint8List.fromList(utf8.encode(jsonEncode(custody))),
    );
    final base = jsonDecode(
      utf8.decode(store.states[security.namespace]!.bytes),
    ) as Map<String, dynamic>;
    (base['companyTrust'] as Map)['facts'] = commitment;
    store.states[security.namespace] = ProtectedInstallationState(
      const Uuid().v4(),
      Uint8List.fromList(utf8.encode(jsonEncode(base))),
    );
    await security.start(db);
    expect(security.readiness, InstallationReadiness.ready);
    final owner = await enrollment.signIn('1234');
    final commands = CompanyJobCommands(enrollment: enrollment);
    final create = CreateJob(
      companyId: identity.companyId,
      shopId: identity.shopId,
      jobId: const Uuid().v4(),
      requestId: const Uuid().v4(),
      name: 'Permission boundary',
    );
    await commands.createJob(create, ownerSession: owner);
    final created = (await db.select(db.companyJobs).get()).single;
    expect(
      (jsonDecode(created.operationBytes)['body'] as Map)['facts'],
      commitment,
    );
    final command = SetJobLifecycle(
      companyId: identity.companyId,
      shopId: identity.shopId,
      jobId: create.jobId,
      requestId: const Uuid().v4(),
      creationDigest: hash.sha256
          .convert(utf8.encode(created.operationBytes))
          .toString(),
      observed: JobCausalContext.fromTagged([]),
      choice: JobLifecycleChoice.deleted,
    );
    final beforeSql = await sqlSnapshot(db);
    Map<String, Object?> protectedSnapshot() => {
      for (final entry in store.states.entries)
        entry.key: {
          'revision': entry.value.revision,
          'sha256': hash.sha256.convert(entry.value.bytes).toString(),
        },
    };
    final beforeProtected = protectedSnapshot();
    await expectLater(
      commands.setJobLifecycle(command, ownerSession: owner),
      throwsA(
        isA<JobLineRefusal>().having(
          (e) => e.reason,
          'family-specific refusal',
          'Job lifecycle unavailable. Existing company authority needs an explicit capability upgrade.',
        ),
      ),
    );
    expect(await sqlSnapshot(db), beforeSql);
    expect((await db.select(db.companyJobs).get()).single, created);
    expect(protectedSnapshot(), beforeProtected);
    expect(await db.select(db.companyJobLifecycles).get(), isEmpty);
    expect(await db.select(db.companyJobLifecyclePeerAcks).get(), isEmpty);
  });
}
