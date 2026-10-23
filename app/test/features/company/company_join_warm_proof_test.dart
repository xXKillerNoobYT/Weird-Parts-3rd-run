import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_join_test.dart';
import 'join_proof_verifier_test.dart' show ProbeCryptography, ProbeEd25519;

class CertificateRefusingCryptography extends ProbeCryptography {
  int certificateCalls = 0;
  @override
  Ed25519 ed25519() => CertificateRefusingEd25519(this);
}

class CertificateRefusingEd25519 extends ProbeEd25519 {
  CertificateRefusingEd25519(this.owner) : super(owner);
  final CertificateRefusingCryptography owner;
  @override
  Future<bool> verify(List<int> message, {required Signature signature}) {
    if (utf8.decode(message).startsWith('wiredpart.company.device.enroll@1:')) {
      owner.certificateCalls++;
      return Future.value(false);
    }
    return super.verify(message, signature: signature);
  }
}

Future<void> warmMember(JoinFixture f) async {
  await f.b.readCompanyTrust(f.bDb);
  final before = joinProofVerificationStatistics;
  await f.b.readCompanyTrust(f.bDb);
  await resolveCompanyMembership(db: f.bDb, installation: f.b);
  final after = joinProofVerificationStatistics;
  expect(after.hits, greaterThan(before.hits));
  expect(after.verifications, before.verifications);
  expect(after.entries, lessThanOrEqualTo(64));
  expect(after.codeUnits, lessThanOrEqualTo(65536));
}

Future<void> changeProtected(
  JoinActivationStore store,
  String namespace,
  void Function(Map<String, dynamic>) change,
) async {
  final prior = store.states[namespace]!;
  final body = jsonDecode(utf8.decode(prior.bytes)) as Map<String, dynamic>;
  change(body);
  await store.compareAndSwapState(
    namespace,
    expectedRevision: prior.revision,
    nextRevision: const Uuid().v4(),
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  );
}

void main() {
  setUp(() => Cryptography.instance = DartCryptography.defaultInstance);
  tearDown(() => Cryptography.instance = DartCryptography.defaultInstance);
  tearDownAll(() {
    final stats = joinProofVerificationStatistics;
    // Only aggregate work and retention counts leave this synthetic fixture.
    // ignore: avoid_print
    print(
      'JOIN_PROOF_AGGREGATE ${jsonEncode({'hits': stats.hits, 'verifications': stats.verifications, 'entries': stats.entries, 'codeUnits': stats.codeUnits, 'evictions': stats.evictions})}',
    );
  });

  test('warm production proofs still refuse issuer and member floors and revocations', () async {
    final f = await JoinFixture.create();
    await activateFixtureB(f);
    await warmMember(f);
    final row =
        (await f.bDb.select(f.bDb.companyMembershipCertificates).get()).single;
    final body = jsonDecode(row.proofBytes)['body'] as Map;
    final issuer = body['issuer'] as Map;
    final member = body['recipient'] as Map;
    final original = Map.of(f.bStore.states);
    for (final entry in <String, int>{
      'authority.${body['company']}': 2,
      'grant.${issuer['grant']}': 2,
      'grant.${member['grant']}': 2,
      'credential.${member['user']}': 2,
      'permission.${member['user']}': 2,
      'revocation.user.${member['user']}': 1,
      'revocation.device.${issuer['device']}': 1,
      'revocation.device.${member['device']}': 1,
      'revocation.grant.${issuer['grant']}': 1,
      'revocation.grant.${member['grant']}': 1,
    }.entries) {
      await advanceJoinFloor(f.bStore, f.b.namespace, entry.key, entry.value);
      final sql = await sqlSnapshot(f.bDb);
      final protected = Map.of(f.bStore.states);
      await expectLater(f.b.readCompanyTrust(f.bDb), throwsA(anything));
      expect(await sqlSnapshot(f.bDb), sql);
      expectJoinProtectedUnchanged(f.bStore, protected);
      f.bStore.states
        ..clear()
        ..addAll(original);
      await warmMember(f);
    }
  });

  test(
    'warm public membership rejects changed signature body encoding and schema',
    () async {
      final f = await JoinFixture.create();
      await activateFixtureB(f);
      await warmMember(f);
      final row =
          (await f.bDb.select(f.bDb.companyMembershipCertificates).get())
              .single;
      final sql = await sqlSnapshot(f.bDb);
      final protected = Map.of(f.bStore.states);
      final changes = <void Function(Map<String, dynamic>)>[
        (s) => s['signature'] = base64Encode(List.filled(64, 0)),
        (s) => (s['body'] as Map)['sequence'] = 2,
        (s) => (s['body'] as Map)['depth'] = 2,
        (s) => (s['body'] as Map)['delegable'] = true,
        (s) => (s['body'] as Map)['extra'] = true,
        (s) => s['signature'] = '!' * 88,
        (s) => s['signature'] = 'A' * 88,
        (s) => s['signature'] = base64Encode(List.filled(63, 0)),
        (s) => s['signature'] = 1,
        (s) => (s['body'] as Map)['kind'] = 'unsupported',
        (s) =>
            (s['body'] as Map)['recipient']['capabilities'] = ['enrollDevice'],
      ];
      for (final change in changes) {
        final signed = jsonDecode(row.proofBytes) as Map<String, dynamic>;
        change(signed);
        await expectLater(
          resolveCompanyMembership(
            db: f.bDb,
            installation: f.b,
            certificateBytes: canonicalJoinTest(signed),
          ),
          throwsA(anything),
        );
      }
      for (final bytes in [
        ' ${row.proofBytes}',
        '${row.proofBytes} ',
        ' ' * 4097,
      ]) {
        await expectLater(
          resolveCompanyMembership(
            db: f.bDb,
            installation: f.b,
            certificateBytes: bytes,
          ),
          throwsA(anything),
        );
      }
      final parsed = jsonDecode(row.proofBytes) as Map<String, dynamic>;
      final reordered = Map<String, dynamic>.fromEntries(
        parsed.entries.toList().reversed,
      );
      final before = joinProofVerificationStatistics;
      await resolveCompanyMembership(
        db: f.bDb,
        installation: f.b,
        certificateBytes: canonicalJoinTest(reordered),
      );
      expect(joinProofVerificationStatistics.hits, greaterThan(before.hits));
      expect(await sqlSnapshot(f.bDb), sql);
      expectJoinProtectedUnchanged(f.bStore, protected);
    },
  );

  test(
    'warm public proof cannot bypass a different cryptographic provider',
    () async {
      final f = await JoinFixture.create();
      await activateFixtureB(f);
      await warmMember(f);
      final sql = await sqlSnapshot(f.bDb);
      final protected = Map.of(f.bStore.states);
      final provider = CertificateRefusingCryptography();
      Cryptography.instance = provider;
      await expectLater(
        resolveCompanyMembership(db: f.bDb, installation: f.b),
        throwsA(anything),
      );
      expect(provider.certificateCalls, 1);
      expect(await sqlSnapshot(f.bDb), sql);
      expectJoinProtectedUnchanged(f.bStore, protected);
      Cryptography.instance = DartCryptography.defaultInstance;
      await warmMember(f);
    },
  );

  test(
    'warm member evidence cannot grant a signed-out session a job write',
    () async {
      final f = await JoinFixture.create();
      await activateFixtureB(f);
      final owner = await f.bEnrollment.signIn('1234');
      await warmMember(f);
      await f.bEnrollment.signOut();
      final sql = await sqlSnapshot(f.bDb);
      final protected = Map.of(f.bStore.states);
      await expectLater(
        CompanyJobCommands(enrollment: f.bEnrollment).createJob(
          CreateJob(
            companyId: owner.identity.companyId,
            shopId: owner.identity.shopId,
            jobId: const Uuid().v4(),
            requestId: const Uuid().v4(),
            name: 'Refused',
          ),
          ownerSession: owner,
        ),
        throwsA(anything),
      );
      expect(await sqlSnapshot(f.bDb), sql);
      expectJoinProtectedUnchanged(f.bStore, protected);
    },
  );

  test('warm proofs cannot replace current installation key generation store or trust bindings', () async {
    final f = await JoinFixture.create();
    await activateFixtureB(f);
    await warmMember(f);
    final original = Map.of(f.bStore.states);
    for (final change in <void Function(Map<String, dynamic>)>[
      (b) => b['id'] = const Uuid().v4(),
      (b) => b['generation'] = const Uuid().v4(),
      (b) => b['store'] = const Uuid().v4(),
      (b) => b['public'] = base64Encode(List.filled(32, 3)),
      (b) => b['seed'] = base64Encode(List.filled(32, 3)),
      (b) => b['storePath'] = '0' * 64,
      (b) =>
          (b['companyTrust'] as Map)['root'] = base64Encode(List.filled(32, 3)),
      (b) => (b['companyTrust'] as Map)['company'] = const Uuid().v4(),
    ]) {
      await changeProtected(f.bStore, f.b.namespace, change);
      final sql = await sqlSnapshot(f.bDb);
      final protected = Map.of(f.bStore.states);
      await expectLater(f.b.readCompanyTrust(f.bDb), throwsA(anything));
      expect(await sqlSnapshot(f.bDb), sql);
      expectJoinProtectedUnchanged(f.bStore, protected);
      f.bStore.states
        ..clear()
        ..addAll(original);
      await warmMember(f);
    }
  });

  test(
    'warm proof still rereads activation witness certificate and request rows',
    () async {
      final f = await JoinFixture.create();
      await activateFixtureB(f);
      await warmMember(f);
      final event = (await f.bDb.select(f.bDb.companyJoinEvents).get()).single;
      final certificate =
          (await f.bDb.select(f.bDb.companyMembershipCertificates).get())
              .single;
      final request =
          (await f.bDb.select(f.bDb.companyJoinRequests).get()).single;
      final changes = <(String, List<Object?>, List<Object?>)>[
        (
          'UPDATE company_join_events SET evidence_bytes = ? WHERE request_id = ? AND ordinal = 0',
          ['{}', event.requestId],
          [event.evidenceBytes, event.requestId],
        ),
        (
          'UPDATE company_membership_certificates SET proof_bytes = ? WHERE proof_commitment = ?',
          ['{}', certificate.proofCommitment],
          [certificate.proofBytes, certificate.proofCommitment],
        ),
        (
          'UPDATE company_join_requests SET request_bytes = ? WHERE request_id = ?',
          ['{}', request.requestId],
          [request.requestBytes, request.requestId],
        ),
      ];
      for (final change in changes) {
        await f.bDb.customStatement(change.$1, change.$2);
        final sql = await sqlSnapshot(f.bDb);
        final protected = Map.of(f.bStore.states);
        await expectLater(f.b.readCompanyTrust(f.bDb), throwsA(anything));
        expect(await sqlSnapshot(f.bDb), sql);
        expectJoinProtectedUnchanged(f.bStore, protected);
        await f.bDb.customStatement(change.$1, change.$3);
        await warmMember(f);
      }
      final sql = await sqlSnapshot(f.bDb);
      await f.bDb.settingsDao.setSetting(kInstallationBindingKey, '{}');
      final mutated = await sqlSnapshot(f.bDb);
      final protected = Map.of(f.bStore.states);
      await expectLater(f.b.readCompanyTrust(f.bDb), throwsA(anything));
      expect(await sqlSnapshot(f.bDb), mutated);
      expectJoinProtectedUnchanged(f.bStore, protected);
      expect(mutated, isNot(sql));
    },
  );

  test('warm global proofs grant no custody to a copied path or fresh installation', () async {
    final f = await JoinFixture.create();
    await activateFixtureB(f);
    await warmMember(f);
    final copiedPath = '${f.root.path}/copied.sqlite';
    await f.bDb.customStatement('VACUUM INTO ?', [copiedPath]);
    final copied = AppDatabase.forTesting(NativeDatabase(File(copiedPath)));
    addTearDown(copied.close);
    final before = await sqlSnapshot(copied);
    final protected = Map.of(f.bStore.states);
    final moved = InstallationSecurity(
      store: f.bStore,
      namespace: f.b.namespace,
    );
    await expectLater(moved.readCompanyTrust(copied), throwsA(anything));
    final fresh = InstallationSecurity(
      store: JoinActivationStore(),
      namespace: 'synthetic.warm-fresh',
    );
    await expectLater(fresh.readCompanyTrust(copied), throwsA(anything));
    expect(await sqlSnapshot(copied), before);
    expectJoinProtectedUnchanged(f.bStore, protected);
  });

  test('warm member proofs still require current and ancestor authority signatures', () async {
    final f = await JoinFixture.create();
    final recoveredDb = AppDatabase.forTesting(
      NativeDatabase(File('${f.root.path}/recovered.sqlite')),
    );
    addTearDown(recoveredDb.close);
    final recovered = InstallationSecurity(
      store: JoinActivationStore(),
      namespace: 'synthetic.warm-recovery',
    );
    await recovered.start(recoveredDb);
    final enrollment = CompanyEnrollment(
      installation: recovered,
      db: recoveredDb,
    );
    await enrollment.recover(
      policy: CompanyContinuityPolicy.localContinuity,
      sourceFile: File('${f.root.path}/a.wpca'),
      sourcePassphrase: 'synthetic durable authority phrase',
      newPin: '1234',
      newRecoveryPassphrase: 'synthetic next authority phrase',
      newRecoveryFile: File('${f.root.path}/next.wpca'),
    );
    final owner = await enrollment.signIn('1234');
    final (bc, ac) = await joinChannels();
    try {
      final aj = CompanyJoin(enrollment: enrollment);
      final bj = CompanyJoin(enrollment: f.bEnrollment);
      final request = await aj.receiveJoinRequest(ac, await bj.beginJoin(bc));
      await bj.acceptProvision(
        await bj.receiveProvision(
          bc,
          await aj.approveJoin(ac, request, ownerSession: owner),
        ),
      );
    } finally {
      bc.close();
      ac.close();
    }
    await warmMember(f);
    final facts = await f.bDb.select(f.bDb.companyAuthorityFacts).get();
    expect(facts, hasLength(2));
    for (final fact in facts) {
      final signed = jsonDecode(fact.signedBytes) as Map<String, dynamic>;
      signed['signature'] = base64Encode(List.filled(64, 0));
      await f.bDb.customStatement(
        'UPDATE company_authority_facts SET signed_bytes = ? WHERE commitment = ?',
        [canonicalJoinTest(signed), fact.commitment],
      );
      final sql = await sqlSnapshot(f.bDb);
      final protected = Map.of(f.bStore.states);
      await expectLater(f.b.readCompanyTrust(f.bDb), throwsA(anything));
      expect(await sqlSnapshot(f.bDb), sql);
      expectJoinProtectedUnchanged(f.bStore, protected);
      await f.bDb.customStatement(
        'UPDATE company_authority_facts SET signed_bytes = ? WHERE commitment = ?',
        [fact.signedBytes, fact.commitment],
      );
      await warmMember(f);
    }
  });
}
