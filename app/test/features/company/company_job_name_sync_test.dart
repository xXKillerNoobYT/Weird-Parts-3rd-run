@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_join_test.dart'
    show JoinFixture, activateFixtureB, enrollAdditionalFixtureC, sqlSnapshot;
import 'company_created_job_sync_test.dart'
    show openSyncPair, receiverAvailability, syncAttackWire;
import 'company_job_name_test.dart' show canonicalNameTest;

String digestName(Object? value) =>
    hashes.sha256.convert(utf8.encode(canonicalNameTest(value))).toString();

Future<void> closeNamePair(
  ({CompanyCreatedJobSync a, CompanyCreatedJobSync b, OwnerSession ownerB})
  pair,
) async {
  await pair.a.closeAndDrain();
  await pair.b.closeAndDrain();
}

void main() {
  for (final fromA in [true, false]) {
    test(
      'foreign dependencies stay pending while unrelated traffic syncs from ${fromA ? 'A' : 'C'}',
      () async {
        final f = await JoinFixture.create(allowOwnerAdditions: true);
        await activateFixtureB(f);
        final ac = CompanyJobCommands(enrollment: f.aEnrollment);
        final bc = CompanyJobCommands(enrollment: f.bEnrollment);
        final ab = await openSyncPair(f);
        late CompanyJobView base, foreign;
        late JobNameCommandReceipt parent, child, grandchild, missingCreation;
        try {
          expect((await ab.a.syncNow()).complete, isTrue);
          base = (await ac.listJobViews(ownerSession: f.owner)).single;
          RenameJob edit(
            CompanyJobView view,
            String name,
            List<String> heads,
          ) => RenameJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: view.baseJob.id,
            requestId: const Uuid().v4(),
            creationDigest: view.creationDigest,
            observedHeads: heads,
            name: name,
          );
          parent = await bc.renameJob(
            edit(base, 'B parent', []),
            ownerSession: ab.ownerB,
          );
          final foreignJob = const Uuid().v4();
          await bc.createJob(
            CreateJob(
              companyId: f.owner.identity.companyId,
              shopId: f.owner.identity.shopId,
              jobId: foreignJob,
              requestId: const Uuid().v4(),
              name: 'B created Job',
            ),
            ownerSession: ab.ownerB,
          );
          expect((await ab.a.syncNow()).complete, isTrue);
          foreign = (await ac.listJobViews(ownerSession: f.owner))
              .singleWhere((v) => v.baseJob.id == foreignJob);
          child = await ac.renameJob(
            edit(base, 'A child', [parent.operationId]),
            ownerSession: f.owner,
          );
          grandchild = await ac.renameJob(
            edit(base, 'A grandchild', [child.operationId]),
            ownerSession: f.owner,
          );
          missingCreation = await ac.renameJob(
            edit(foreign, 'A name on B Job', []),
            ownerSession: f.owner,
          );
          await ac.renameJob(
            edit(base, 'Independent A name', []),
            ownerSession: f.owner,
          );
        } finally {
          await closeNamePair(ab);
        }
        final ce = await enrollAdditionalFixtureC(f);
        final co = await ce.signIn('1234');
        final cc = CompanyJobCommands(enrollment: ce);
        final independent = const Uuid().v4();
        await cc.createJob(
          CreateJob(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            jobId: independent,
            requestId: const Uuid().v4(),
            name: 'Independent C Job',
          ),
          ownerSession: co,
        );
        final pair = await openSyncPair(f, peerEnrollment: ce);
        try {
          final run = await (fromA ? pair.a : pair.b).syncNow();
          expect(run.complete, isFalse);
          expect(
            run.failure?.reason,
            CreatedJobSyncReason.unsupportedAuthor,
            reason: safeNameFailure(pair),
          );
          expect(run.unsupported, 5);
          expect(run.sent, fromA ? 2 : 1);
          expect(run.received, fromA ? 1 : 2);
          expect(pair.a.lastFailure, isNull);
          expect(pair.b.lastFailure, isNull);
          final cv = await cc.listJobViews(ownerSession: co);
          expect(cv.map((v) => v.baseJob.id).toSet(), {
            base.baseJob.id,
            independent,
          });
          expect(
            cv.singleWhere((v) => v.baseJob.id == base.baseJob.id).resolvedName,
            'Independent A name',
          );
          expect(
            (await ac.listJobViews(ownerSession: f.owner))
                .singleWhere((v) => v.baseJob.id == independent)
                .resolvedName,
            'Independent C Job',
          );
          final blocked = {
            parent.operationId,
            child.operationId,
            grandchild.operationId,
            missingCreation.operationId,
          };
          final cNames = await ce.db.select(ce.db.companyJobNames).get();
          expect(
            cNames.any((r) => blocked.contains(r.operationCommitment)),
            isFalse,
          );
          expect(
            await ce.db.select(ce.db.companyJobNamePeerAcks).get(),
            hasLength(1),
          );
          expect(
            (await f.aDb.select(f.aDb.companyJobNamePeerAcks).get()).where(
              (r) => r.peerDeviceId == co.identity.deviceId,
            ),
            hasLength(1),
          );
          expect(
            (await f.aDb.select(f.aDb.companyJobPeerAcks).get()).where(
              (r) => r.peerDeviceId == co.identity.deviceId,
            ),
            hasLength(2),
          );
          final aBefore = digestName(await sqlSnapshot(f.aDb));
          final cBefore = digestName(await sqlSnapshot(ce.db));
          final aProtected = hashes.sha256
              .convert(f.aStore.states[f.a.namespace]!.bytes)
              .toString();
          final cProtected = hashes.sha256
              .convert(
                (await ce.installation.store.readState(
                  ce.installation.namespace,
                ))!.bytes,
              )
              .toString();
          final repeat = await (fromA ? pair.a : pair.b).syncNow();
          expect(repeat.complete, isFalse);
          expect(
            repeat.failure?.reason,
            CreatedJobSyncReason.unsupportedAuthor,
          );
          expect(repeat.unsupported, 5);
          expect(repeat.sent, 0);
          expect(repeat.received, 0);
          expect(digestName(await sqlSnapshot(f.aDb)), aBefore);
          expect(digestName(await sqlSnapshot(ce.db)), cBefore);
          expect(
            hashes.sha256
                .convert(f.aStore.states[f.a.namespace]!.bytes)
                .toString(),
            aProtected,
          );
          expect(
            hashes.sha256
                .convert(
                  (await ce.installation.store.readState(
                    ce.installation.namespace,
                  ))!.bytes,
                )
                .toString(),
            cProtected,
          );
        } finally {
          await closeNamePair(pair);
        }
        final held = await openSyncPair(f);
        try {
          final run = await (fromA ? held.a : held.b).syncNow();
          expect(run.complete, isFalse);
          expect(run.failure?.reason, CreatedJobSyncReason.unsupportedAuthor);
          expect(run.unsupported, 1);
          expect(run.sent, fromA ? 4 : 0);
          expect(run.received, fromA ? 0 : 4);
          final bNames = await f.bDb.select(f.bDb.companyJobNames).get();
          expect(
            bNames.map((r) => r.operationCommitment),
            containsAll([
              parent.operationId,
              child.operationId,
              grandchild.operationId,
              missingCreation.operationId,
            ]),
          );
          final before = digestName(await sqlSnapshot(f.bDb));
          final repeat = await (fromA ? held.a : held.b).syncNow();
          expect(repeat.complete, isFalse);
          expect(
            repeat.failure?.reason,
            CreatedJobSyncReason.unsupportedAuthor,
          );
          expect(repeat.sent, 0);
          expect(repeat.received, 0);
          expect(digestName(await sqlSnapshot(f.bDb)), before);
        } finally {
          await closeNamePair(held);
        }
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  }

  test('framing-only large parent pages respect unchanged envelope budget', () {
    final records = List.generate(64, (i) => framingNameRecord(i, 32));
    final local = CreatedJobHoldingsInventory.local(records);
    expect(local.pages, greaterThan(2));
    final remote = CreatedJobHoldingsInventory.remote(local.meta);
    for (var ordinal = 0; ordinal < local.pages; ordinal++) {
      final page = local.page(ordinal);
      final wire = {
        'ordinal': ordinal,
        'digest': local.digest,
        'items': page,
        'confirmedStores': List.filled(page.length, const Uuid().v4()),
      };
      expect(utf8.encode(canonicalNameTest(wire)).length, lessThan(33 * 1024));
      remote.acceptPage(wire);
    }
    expect(remote.complete, isTrue);
    expect(remote.digest, local.digest);
  });
  test('byte-packed short first page signals adaptive layout even when page count matches ceiling', () {
    final records = List.generate(
      33,
      (i) => framingNameRecord(i, i < 17 ? 32 : 0),
    );
    final local = CreatedJobHoldingsInventory.local(records);
    expect(local.pages, 2);
    expect(local.page(0).length, lessThan(32));
    final remote = CreatedJobHoldingsInventory.remote(local.meta);
    for (var i = 0; i < local.pages; i++) {
      final items = local.page(i);
      remote.acceptPage({
        'ordinal': i,
        'digest': local.digest,
        'items': items,
        'confirmedStores': List.filled(items.length, null),
      });
    }
    expect(remote.complete, isTrue);
  });

  for (final fromA in [true, false]) {
    test(
      'one Sync Now exchanges concurrent names both ways, resolves and repeats from ${fromA ? 'A' : 'B'}',
      () async {
        final f = await JoinFixture.create(allowOwnerAdditions: true);
        await activateFixtureB(f);
        final pair = await openSyncPair(f);
        try {
          expect(
            (await pair.a.syncNow()).complete,
            isTrue,
            reason: safeNameFailure(pair),
          );
          final base = (await f.aDb.select(f.aDb.companyJobs).get()).single;
          final aCreate = digestName(base.toJson());
          final bCreate = digestName(
            (await f.bDb.select(f.bDb.companyJobs).get()).single.toJson(),
          );
          final ac = CompanyJobCommands(enrollment: f.aEnrollment),
              bc = CompanyJobCommands(enrollment: f.bEnrollment);
          RenameJob edit(String name, {List<String> heads = const []}) =>
              RenameJob(
                companyId: base.companyId,
                shopId: base.shopId,
                jobId: base.jobId,
                requestId: const Uuid().v4(),
                creationDigest: hashes.sha256
                    .convert(utf8.encode(base.operationBytes))
                    .toString(),
                observedHeads: heads,
                name: name,
              );
          await ac.renameJob(edit('A name'), ownerSession: f.owner);
          await bc.renameJob(edit('B name'), ownerSession: pair.ownerB);
          expect(
            (await CompanyCreatedJobSync.confirmedPeerCounts(
              f.aEnrollment,
              f.owner,
            ))[base.jobId],
            0,
          );
          final run = await (fromA ? pair.a : pair.b).syncNow();
          expect(run.complete, isTrue);
          expect(run.sent, 1);
          expect(run.received, 1);
          final av = (await ac.listJobViews(ownerSession: f.owner)).single;
          final bv = (await bc.listJobViews(ownerSession: pair.ownerB)).single;
          expect(av.candidates.map((c) => c.name).toSet(), {
            'A name',
            'B name',
          });
          expect(bv.nameHeads, av.nameHeads);
          expect(av.candidates.map((c) => c.originalDeviceId).toSet(), {
            f.owner.identity.deviceId,
            pair.ownerB.identity.deviceId,
          });
          final repeat = await (fromA ? pair.a : pair.b).syncNow();
          expect(repeat.complete, isTrue);
          expect(repeat.sent, 0);
          expect(repeat.received, 0);
          await ac.renameJob(
            edit('Resolved', heads: av.nameHeads),
            ownerSession: f.owner,
          );
          expect(
            (await pair.a.syncNow()).complete,
            isTrue,
            reason: safeNameFailure(pair),
          );
          expect(
            (await bc.listJobViews(ownerSession: pair.ownerB))
                .single
                .resolvedName,
            'Resolved',
          );
          expect(
            (await f.aDb.select(f.aDb.companyJobNames).get()),
            hasLength(3),
          );
          expect(
            (await f.bDb.select(f.bDb.companyJobNames).get()),
            hasLength(3),
          );
          expect(
            digestName(
              (await f.aDb.select(f.aDb.companyJobs).get()).single.toJson(),
            ),
            aCreate,
          );
          expect(
            digestName(
              (await f.bDb.select(f.bDb.companyJobs).get()).single.toJson(),
            ),
            bCreate,
          );
          final acks = await f.aDb.select(f.aDb.companyJobNamePeerAcks).get();
          expect(acks, hasLength(3));
          expect(
            acks.every(
              (a) =>
                  (jsonDecode(a.ackBytes)['body'] as Map)['kind'] ==
                  'company.job.name.ack@1',
            ),
            isTrue,
          );
        } finally {
          await closeNamePair(pair);
        }
        await f.reopenB();
        final bo = await f.bEnrollment.signIn('1234');
        expect(
          (await CompanyJobCommands(enrollment: f.bEnrollment)
                  .listJobViews(ownerSession: bo))
              .single
              .resolvedName,
          'Resolved',
        );
      },
    );
  }

  test('out of order dependency rejects unchanged then exact signed child retries after parent', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    expect(
      (await pair.a.syncNow()).complete,
      isTrue,
      reason: safeNameFailure(pair),
    );
    await closeNamePair(pair);
    final ac = CompanyJobCommands(enrollment: f.aEnrollment),
        bc = CompanyJobCommands(enrollment: f.bEnrollment);
    final view = (await ac.listJobViews(ownerSession: f.owner)).single;
    RenameJob edit(String name, List<String> parents) => RenameJob(
      companyId: f.owner.identity.companyId,
      shopId: f.owner.identity.shopId,
      jobId: view.baseJob.id,
      requestId: const Uuid().v4(),
      creationDigest: view.creationDigest,
      observedHeads: parents,
      name: name,
    );
    final parent = await ac.renameJob(
      edit('Parent', []),
      ownerSession: f.owner,
    );
    final child = await ac.renameJob(
      edit('Child', [parent.operationId]),
      ownerSession: f.owner,
    );
    final records = await f.aDb.select(f.aDb.companyJobNames).get();
    final availability = await receiverAvailability(f, pair.ownerB);
    final childBytes = Uint8List.fromList(
      utf8.encode(
        records
            .singleWhere((r) => r.operationCommitment == child.operationId)
            .operationBytes,
      ),
    );
    final before = digestName(await sqlSnapshot(f.bDb));
    final protected = hashes.sha256
        .convert(f.bStore.states[f.b.namespace]!.bytes)
        .toString();
    await expectLater(
      bc.applyIncomingName(
        childBytes,
        ownerSession: pair.ownerB,
        availability: availability,
      ),
      throwsA(isA<JobNameDependencyRefusal>()),
    );
    expect(digestName(await sqlSnapshot(f.bDb)), before);
    expect(
      hashes.sha256.convert(f.bStore.states[f.b.namespace]!.bytes).toString(),
      protected,
    );
    final parentBytes = Uint8List.fromList(
      utf8.encode(
        records
            .singleWhere((r) => r.operationCommitment == parent.operationId)
            .operationBytes,
      ),
    );
    await bc.applyIncomingName(
      parentBytes,
      ownerSession: pair.ownerB,
      availability: availability,
    );
    final receipt = await bc.applyIncomingName(
      childBytes,
      ownerSession: pair.ownerB,
      availability: availability,
    );
    expect(
      await bc.applyIncomingName(
        childBytes,
        ownerSession: pair.ownerB,
        availability: availability,
      ),
      receipt,
    );
    expect(
      (await bc.listJobViews(ownerSession: pair.ownerB)).single.resolvedName,
      'Child',
    );
    final tampered =
        jsonDecode(utf8.decode(childBytes)) as Map<String, dynamic>;
    tampered['signature'] = base64Encode(List.filled(64, 0));
    final after = digestName(await sqlSnapshot(f.bDb));
    await expectLater(
      bc.applyIncomingName(
        Uint8List.fromList(utf8.encode(canonicalNameTest(tampered))),
        ownerSession: pair.ownerB,
        availability: availability,
      ),
      throwsA(anything),
    );
    expect(digestName(await sqlSnapshot(f.bDb)), after);
  });

  test('creation-only signed member certificate never gains name permission', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    try {
      expect(
        (await pair.a.syncNow()).complete,
        isTrue,
        reason: safeNameFailure(pair),
      );
      final commands = CompanyJobCommands(enrollment: f.bEnrollment);
      final view = (await commands.listJobViews(ownerSession: pair.ownerB))
          .single;
      final command = RenameJob(
        companyId: pair.ownerB.identity.companyId,
        shopId: pair.ownerB.identity.shopId,
        jobId: view.baseJob.id,
        requestId: const Uuid().v4(),
        creationDigest: view.creationDigest,
        observedHeads: [],
        name: 'Explicit authority',
      );
      await commands.renameJob(command, ownerSession: pair.ownerB);
      final op = jsonDecode(
        (await f.bDb.select(f.bDb.companyJobNames).get()).single.operationBytes,
      ) as Map;
      final proof = Map<String, dynamic>.from(op['authorization'] as Map);
      final certificate =
          jsonDecode(proof['membership'] as String) as Map<String, dynamic>;
      ((certificate['body'] as Map)['recipient'] as Map)['capabilities'] = [
        'createJob',
      ];
      final aState =
          jsonDecode(utf8.decode(f.aStore.states[f.a.namespace]!.bytes)) as Map;
      final aKey = await Ed25519().newKeyPairFromSeed(
        base64Decode(aState['seed'] as String),
      );
      final certSignature = await Ed25519().sign(
        utf8.encode(
          'wiredpart.company.device.enroll@1:${canonicalNameTest(certificate['body'])}',
        ),
        keyPair: aKey,
      );
      certificate['signature'] = base64Encode(certSignature.bytes);
      proof['membership'] = canonicalNameTest(certificate);
      (proof['body'] as Map)['membership'] = digestName(certificate);
      final bState =
          jsonDecode(utf8.decode(f.bStore.states[f.b.namespace]!.bytes)) as Map;
      final bKey = await Ed25519().newKeyPairFromSeed(
        base64Decode(bState['seed'] as String),
      );
      final authSignature = await Ed25519().sign(
        utf8.encode(
          'wiredpart.job.name.authorization@2:${canonicalNameTest(proof['body'])}',
        ),
        keyPair: bKey,
      );
      proof['signature'] = base64Encode(authSignature.bytes);
      final before = digestName(await sqlSnapshot(f.bDb));
      final member = await resolveCompanyMembership(
        db: f.bDb,
        installation: f.b,
        certificateBytes: canonicalNameTest(certificate),
      );
      expect(member.device['capabilities'], ['createJob']);
      final create = CreateJob(
        companyId: command.companyId,
        shopId: command.shopId,
        jobId: const Uuid().v4(),
        requestId: const Uuid().v4(),
        name: 'Creation still allowed',
      );
      final createProof = jsonDecode(jsonEncode(proof)) as Map<String, dynamic>;
      (createProof['body'] as Map<String, dynamic>).addAll(<String, dynamic>{
        'job': create.jobId,
        'request': create.requestId,
        'command': create.commitment,
      });
      createProof['signature'] = base64Encode(
        (await Ed25519().sign(
          utf8.encode(
            'wiredpart.job.create.authorization@2:${canonicalNameTest(createProof['body'])}',
          ),
          keyPair: bKey,
        )).bytes,
      );
      final verifiedCreate =
          await CreateJobAuthorization(db: f.bDb, installation: f.b).verify(
            create,
            Uint8List.fromList(utf8.encode(canonicalNameTest(createProof))),
          );
      verifiedCreate.validateLiveOwner(pair.ownerB);
      await expectLater(
        RenameJobAuthorization(db: f.bDb, installation: f.b).verify(
          command,
          Uint8List.fromList(utf8.encode(canonicalNameTest(proof))),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(digestName(await sqlSnapshot(f.bDb)), before);
    } finally {
      await closeNamePair(pair);
    }
  });
  test('old protocol refuses with unchanged durable records', () async {
    final f = await JoinFixture.create(allowOwnerAdditions: true);
    await activateFixtureB(f);
    final pair = await openSyncPair(f);
    try {
      final before = digestName(await sqlSnapshot(f.bDb));
      final wire = await syncAttackWire(
        pair.a.controller.pairedJoinSession!,
        base64Encode(f.b.identity!.publicKey),
        const Uuid().v4(),
        'start',
        {},
        'company.job.create.sync@1',
      );
      await expectLater(
        pair.b.receive(wire),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      expect(digestName(await sqlSnapshot(f.bDb)), before);
    } finally {
      await closeNamePair(pair);
    }
  });
}

String safeNameFailure(
  ({CompanyCreatedJobSync a, CompanyCreatedJobSync b, OwnerSession ownerB})
  pair,
) {
  String safe(Object? e) => e is CompanyBootstrapRefusal
      ? e.message
      : e is JobLineRefusal
      ? e.reason
      : e.runtimeType.toString();
  return 'A:${safe(pair.a.lastFailure)} B:${safe(pair.b.lastFailure)}';
}

CompanyJobName framingNameRecord(int i, int parentCount) {
  final body = {
    'device': '10000000-0000-4000-8000-000000000000',
    'installation': '20000000-0000-4000-8000-000000000000',
    'creation': 'a' * 64,
    'parents': List.generate(
      parentCount,
      (p) => p.toRadixString(16).padLeft(64, '0'),
    ),
  };
  return CompanyJobName(
    companyId: '30000000-0000-4000-8000-000000000000',
    shopId: '40000000-0000-4000-8000-000000000000',
    jobId: '50000000-0000-4000-8000-000000000000',
    originGeneration: '60000000-0000-4000-8000-000000000000',
    requestId: '70000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
    operationCommitment: i.toRadixString(16).padLeft(64, '0'),
    commandCommitment: 'c' * 64,
    operationBytes: canonicalNameTest({'body': body}),
    receiptKey: 'd' * 64,
    receiptBytes: '',
    auditBytes: '',
    outgoing: true,
  );
}
