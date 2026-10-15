import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_test_support.dart';

String canonicalTest(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: sorted(v[k])};
    }
    if (v is List) {
      return v.map(sorted).toList();
    }
    return v;
  }

  return jsonEncode(sorted(value));
}

void main() {
  late Directory root;
  late AppDatabase db;
  late JobTestStore store;
  late InstallationSecurity installation;
  late CompanyEnrollment enrollment;
  late CompanyIdentity identity;
  late OwnerSession owner;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('company-create-job-');
    db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/shop.sqlite')),
    );
    store = JobTestStore();
    installation = InstallationSecurity(
      store: store,
      namespace: 'synthetic.company-create-job',
    );
    await installation.start(db);
    enrollment = CompanyEnrollment(installation: installation, db: db);
    identity = await enrollment.create(
      companyName: 'Synthetic Job Crew',
      policy: CompanyContinuityPolicy.localContinuity,
      pin: '1234',
      recoveryPassphrase: 'synthetic authority phrase',
      recoveryFile: File('${root.path}/authority.wpca'),
    );
    owner = await enrollment.signIn('1234');
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  CreateJob command({String? id, String? request, String name = 'New Job'}) =>
      CreateJob(
        companyId: identity.companyId,
        shopId: identity.shopId,
        jobId: id ?? const Uuid().v4(),
        requestId: request ?? const Uuid().v4(),
        name: name,
      );

  test(
    'production owner creates one atomic attributed Job and exact retry',
    () async {
      final action = command(name: '  Offline Job  ');
      final commands = CompanyJobCommands(enrollment: enrollment);
      final receipt = await commands.createJob(action, ownerSession: owner);
      final jobs = await commands.listJobs(ownerSession: owner);
      expect(jobs.single.id, action.jobId);
      expect(jobs.single.name, 'Offline Job');
      final record = (await db.select(db.companyJobs).get()).single;
      expect(record.companyId, identity.companyId);
      expect(record.shopId, identity.shopId);
      expect(record.outgoing, isTrue);
      final operation = jsonDecode(record.operationBytes)['body'] as Map;
      expect(operation['contract'], 'job.create@1');
      expect(operation['user'], identity.userId);
      expect(operation['device'], identity.deviceId);
      expect(operation['generation'], installation.identity!.generation.value);
      expect(operation['job'], action.jobId);
      expect(
        operation['createdAt'],
        jobs.single.createdAt.millisecondsSinceEpoch,
      );
      expect(jsonDecode(record.auditBytes)['originalUser'], identity.userId);
      await JobLineCommandReceipt.verifyAdmissionSeal(
        receipt.bytes,
        installation.identity!,
        installation.receivingStoreGeneration!.value,
      );
      expect(
        (await commands.createJob(action, ownerSession: owner)).bytes,
        receipt.bytes,
      );
      expect(await db.select(db.jobs).get(), hasLength(1));
      expect(await db.select(db.companyJobs).get(), hasLength(1));
      expect(await db.select(db.jobLines).get(), isEmpty);
      expect(await db.select(db.jobLineOperations).get(), isEmpty);
    },
  );
  test(
    'collisions refuse without writes and identical names retain distinct IDs',
    () async {
      final action = command(name: 'Repeated name');
      final commands = CompanyJobCommands(enrollment: enrollment);
      await commands.createJob(action, ownerSession: owner);
      final before = await db.select(db.companyJobs).get();
      for (final changed in [
        command(id: action.jobId),
        command(request: action.requestId, name: 'Changed'),
        command(id: action.jobId, request: action.requestId, name: 'Changed'),
      ]) {
        await expectLater(
          commands.createJob(changed, ownerSession: owner),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(await db.select(db.companyJobs).get(), before);
        expect(await db.select(db.jobs).get(), hasLength(1));
      }
      await commands.createJob(
        command(name: 'Repeated name'),
        ownerSession: owner,
      );
      expect(
        (await commands.listJobs(ownerSession: owner)).map((j) => j.name),
        ['Repeated name', 'Repeated name'],
      );
    },
  );

  test('before commit interruption rolls back every effect and same request can retry', () async {
    final action = command();
    final originalState = store.states[installation.namespace]!;
    await expectLater(
      CompanyJobCommands(
        enrollment: enrollment,
        beforeCommit: () async => throw StateError('interrupted'),
      ).createJob(action, ownerSession: owner),
      throwsA(isA<StateError>()),
    );
    expect(await db.select(db.jobs).get(), isEmpty);
    expect(await db.select(db.companyJobs).get(), isEmpty);
    final after = jsonDecode(
      utf8.decode(store.states[installation.namespace]!.bytes),
    );
    expect(after['pendingCommand'], isNull);
    expect(
      after['identity'],
      jsonDecode(utf8.decode(originalState.bytes))['identity'],
    );
    await CompanyJobCommands(enrollment: enrollment)
        .createJob(action, ownerSession: owner);
    expect(await db.select(db.companyJobs).get(), hasLength(1));
  });

  test('committed lost reply survives reopen and new live session retries original receipt', () async {
    final action = command();
    await expectLater(
      CompanyJobCommands(
        enrollment: enrollment,
        afterCommit: () async => throw StateError('reply lost'),
      ).createJob(action, ownerSession: owner),
      throwsA(isA<StateError>()),
    );
    final before = (await db.select(db.companyJobs).get()).single;
    final oldSessionId = owner.sessionId;
    await enrollment.signOut();
    await db.close();
    db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/shop.sqlite')),
    );
    installation = InstallationSecurity(
      store: store,
      namespace: installation.namespace,
    );
    await installation.start(db);
    expect(installation.readiness, InstallationReadiness.ready);
    enrollment = CompanyEnrollment(installation: installation, db: db);
    owner = await enrollment.signIn('1234');
    expect(owner.sessionId, isNot(oldSessionId));
    final commands = CompanyJobCommands(enrollment: enrollment);
    expect(
      (await commands.createJob(action, ownerSession: owner)).bytes,
      before.receiptBytes,
    );
    expect(
      (await commands.listJobs(ownerSession: owner)).single.id,
      action.jobId,
    );
    expect((await db.select(db.companyJobs).get()).single, before);
    expect(await db.select(db.jobs).get(), hasLength(1));
  });

  test('signed out owner and wrong scope cannot write or read', () async {
    final commands = CompanyJobCommands(enrollment: enrollment);
    for (final outside in [
      CreateJob(
        companyId: const Uuid().v4(),
        shopId: identity.shopId,
        jobId: const Uuid().v4(),
        requestId: const Uuid().v4(),
        name: 'Outside',
      ),
      CreateJob(
        companyId: identity.companyId,
        shopId: const Uuid().v4(),
        jobId: const Uuid().v4(),
        requestId: const Uuid().v4(),
        name: 'Outside',
      ),
    ]) {
      await expectLater(
        commands.createJob(outside, ownerSession: owner),
        throwsA(anything),
      );
    }
    await enrollment.signOut();
    await expectLater(
      commands.createJob(command(), ownerSession: owner),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      commands.listJobs(ownerSession: owner),
      throwsA(isA<StateError>()),
    );
    expect(await db.select(db.jobs).get(), isEmpty);
    expect(await db.select(db.companyJobs).get(), isEmpty);
  });

  test(
    'session revoked during beforeCommit refuses and leaves no partial job',
    () async {
      final action = command();
      final commands = CompanyJobCommands(
        enrollment: enrollment,
        beforeCommit: () async {
          // signOut revokes immediately but waits for this command to finish.
          enrollment.signOut();
        },
      );
      await expectLater(
        commands.createJob(action, ownerSession: owner),
        throwsA(isA<StateError>()),
      );
      expect(await db.select(db.jobs).get(), isEmpty);
      expect(await db.select(db.companyJobs).get(), isEmpty);
    },
  );

  test('changed protected floor during beforeCommit rolls back', () async {
    final commands = CompanyJobCommands(
      enrollment: enrollment,
      beforeCommit: () async {
        final state = store.states[installation.namespace]!;
        final raw = jsonDecode(utf8.decode(state.bytes));
        final floors = raw['floors'] as Map;
        floors['permission.${identity.userId}'] = 2;
        store.states[installation.namespace] = ProtectedInstallationState(
          const Uuid().v4(),
          Uint8List.fromList(utf8.encode(jsonEncode(raw))),
        );
      },
    );
    await expectLater(
      commands.createJob(command(), ownerSession: owner),
      throwsA(anything),
    );
    expect(await db.select(db.jobs).get(), isEmpty);
    expect(await db.select(db.companyJobs).get(), isEmpty);
  });

  test(
    'changed projection refuses retry and list without repairing or re-signing',
    () async {
      final action = command();
      final commands = CompanyJobCommands(enrollment: enrollment);
      await commands.createJob(action, ownerSession: owner);
      final journal = (await db.select(db.companyJobs).get()).single;
      await db.customStatement('UPDATE jobs SET name = ? WHERE id = ?', [
        'tampered',
        action.jobId,
      ]);
      await expectLater(
        commands.createJob(action, ownerSession: owner),
        throwsA(isA<JobLineRefusal>()),
      );
      await expectLater(
        commands.listJobs(ownerSession: owner),
        throwsA(isA<JobLineRefusal>()),
      );
      expect((await db.select(db.companyJobs).get()).single, journal);
      expect((await db.select(db.jobs).get()).single.name, 'tampered');
    },
  );

  test(
    'blank, overlong and invalid identities refuse before effects',
    () async {
      for (final name in ['  ', 'x' * 101]) {
        expect(() => command(name: name), throwsA(isA<JobLineRefusal>()));
      }
      expect(
        () => command(id: 'caller-selected-invalid-id'),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await db.select(db.jobs).get(), isEmpty);
      expect(await db.select(db.companyJobs).get(), isEmpty);
    },
  );
  test('create receipt cannot seal a job-line protected intent', () async {
    final action = command();
    await CompanyJobCommands(enrollment: enrollment)
        .createJob(action, ownerSession: owner);
    final created = (await db.select(db.companyJobs).get()).single;
    final trust = (await installation.readCompanyTrust(db))!;
    await db.transaction(() async {
      final time = DateTime.utc(2026);
      await db
          .into(db.jobLines)
          .insert(
            JobLinesCompanion.insert(
              id: action.jobId,
              jobId: action.jobId,
              originDeviceId: identity.deviceId,
              createdAt: time,
              modifiedAt: time,
              customName: const Value('fabricated line'),
              neededQty: 1,
            ),
          );
      final line = (await db.select(db.jobLines).get()).single;
      await db
          .into(db.jobLineBaselines)
          .insert(
            JobLineBaselinesCompanion.insert(
              companyId: identity.companyId,
              lineId: action.jobId,
              shopId: identity.shopId,
              baselineId: 'irrelevant',
              baselineBytes: '{}',
              projectionBytes: canonicalTest(line.toJson()),
            ),
          );
      await db
          .into(db.jobLineOperations)
          .insert(
            JobLineOperationsCompanion.insert(
              companyId: identity.companyId,
              originGeneration: created.originGeneration,
              requestId: created.requestId,
              lineId: action.jobId,
              commitment: created.operationCommitment,
              operationBytes: created.operationBytes,
              admitted: true,
            ),
          );
      await db
          .into(db.jobLineReceipts)
          .insert(
            JobLineReceiptsCompanion.insert(
              receiptKey: created.receiptKey,
              companyId: identity.companyId,
              operationCommitment: created.operationCommitment,
              commandCommitment: created.commandCommitment,
              receiptBytes: created.receiptBytes,
            ),
          );
      await db
          .into(db.jobLineAudits)
          .insert(
            JobLineAuditsCompanion.insert(
              receiptKey: created.receiptKey,
              auditBytes: created.auditBytes,
            ),
          );
      await db
          .into(db.jobLineOutgoing)
          .insert(
            JobLineOutgoingCompanion.insert(
              companyId: identity.companyId,
              originGeneration: created.originGeneration,
              requestId: created.requestId,
              operationCommitment: created.operationCommitment,
            ),
          );
      final held = await installation.beginCompanyCommand(
        db,
        CompanyCommandIntent(
          receiptKey: created.receiptKey,
          operationCommitment: created.operationCommitment,
          commandCommitment: created.commandCommitment,
          storeGeneration: installation.receivingStoreGeneration!.value,
          companyId: identity.companyId,
          lineId: action.jobId,
          originGeneration: created.originGeneration,
          requestId: created.requestId,
        ),
        expectedTrust: trust,
        expectedFloors: installation.knownSecurityFloors,
      );
      await expectLater(
        installation.sealCompanyCommand(db, held),
        throwsA(anything),
      );
    });
  });
  test(
    'scoped 512 Job capacity refuses another create before effects',
    () async {
      final first = command();
      final commands = CompanyJobCommands(enrollment: enrollment);
      await commands.createJob(first, ownerSession: owner);
      final template = (await db.select(db.companyJobs).get()).single;
      await db.transaction(() async {
        for (var i = 1; i < kCompanyJobListLimit; i++) {
          await db
              .into(db.companyJobs)
              .insert(
                CompanyJobsCompanion.insert(
                  jobId: const Uuid().v4(),
                  companyId: identity.companyId,
                  shopId: identity.shopId,
                  originGeneration: template.originGeneration,
                  requestId: const Uuid().v4(),
                  operationCommitment: template.operationCommitment,
                  commandCommitment: template.commandCommitment,
                  operationBytes: template.operationBytes,
                  projectionBytes: template.projectionBytes,
                  receiptKey: const Uuid().v4(),
                  receiptBytes: template.receiptBytes,
                  auditBytes: template.auditBytes,
                  outgoing: true,
                ),
              );
        }
      });
      final before = await db.select(db.companyJobs).get();
      final base = store.states[installation.namespace]!;
      await expectLater(
        commands.createJob(command(), ownerSession: owner),
        throwsA(
          isA<JobLineRefusal>().having(
            (e) => e.reason,
            'capacity',
            contains('512'),
          ),
        ),
      );
      expect(await db.select(db.companyJobs).get(), before);
      expect(await db.select(db.jobs).get(), hasLength(1));
      expect(store.states[installation.namespace]!.bytes, base.bytes);
      expect(
        (await commands.createJob(first, ownerSession: owner)).bytes,
        template.receiptBytes,
      );
    },
  );

  test('closed schema6 fixture contains real signed Job history', () async {
    final action = command(name: 'Synthetic schema6 downgrade proof');
    await CompanyJobCommands(enrollment: enrollment)
        .createJob(action, ownerSession: owner);
    final rows = await db.select(db.companyJobs).get();
    expect(rows, hasLength(1));
    final destination = Platform.environment['COMPANY_JOB_DOWNGRADE_FIXTURE'];
    if (destination != null) {
      expect(File(destination).isAbsolute, isTrue);
      expect(File(destination).existsSync(), isFalse);
      await enrollment.signOut();
      await db.close();
      final fixture = await File('${root.path}/shop.sqlite').copy(destination);
      final bytes = await fixture.readAsBytes();
      File('$destination.expected.json').writeAsStringSync(
        jsonEncode({
          'schema': 6,
          'jobId': action.jobId,
          'companyId': identity.companyId,
          'jobs': 1,
          'companyJobs': 1,
          'outgoing': 1,
          'jobLines': 0,
          'sha256': hashes.sha256.convert(bytes).toString(),
          'byteLength': bytes.length,
        }),
      );
      db = AppDatabase.forTesting(
        NativeDatabase(File('${root.path}/shop.sqlite')),
      );
    }
  });
  test('additive schema5 upgrade preserves legacy rows settings and protected identity', () async {
    final file = File('${root.path}/legacy.sqlite');
    var legacy = AppDatabase.forTesting(NativeDatabase(file));
    final legacyStore = JobTestStore();
    var security = InstallationSecurity(
      store: legacyStore,
      namespace: 'synthetic.legacy-migration',
    );
    await security.start(legacy);
    final originalId = security.identity!.id.value;
    final originalState = legacyStore.states[security.namespace]!;
    final jobId = const Uuid().v4();
    final device = await legacy.settingsDao.ensureDeviceId();
    await legacy.jobsDao.insertJob(
      id: jobId,
      name: 'Legacy kept',
      deviceId: device,
    );
    await legacy.settingsDao.setSetting('migration-proof', 'keep');
    final rows = await legacy.select(legacy.jobs).get();
    final settings = await legacy.select(legacy.appSettings).get();
    await legacy.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE company_jobs');
    raw.execute('PRAGMA user_version = 5');
    raw.dispose();
    legacy = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await legacy.select(legacy.jobs).get(), rows);
      expect(await legacy.select(legacy.appSettings).get(), settings);
      expect(await legacy.select(legacy.companyJobs).get(), isEmpty);
      security = InstallationSecurity(
        store: legacyStore,
        namespace: security.namespace,
      );
      await security.start(legacy);
      expect(security.readiness, InstallationReadiness.ready);
      expect(security.identity!.id.value, originalId);
      expect(
        legacyStore.states[security.namespace]!.bytes,
        originalState.bytes,
      );
      expect(
        (await legacy.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        6,
      );
    } finally {
      await legacy.close();
    }
  });
  for (final mutation in ['receipt seal', 'audit extra']) {
    test(
      'post-hook $mutation tamper rolls back Create Job and permits same request',
      () async {
        final action = command();
        Future<Map<String, Object?>> sql() async => {
          for (final table in db.allTables)
            table.actualTableName:
                (await db
                        .customSelect(
                          'SELECT * FROM "${table.actualTableName}"',
                        )
                        .get())
                    .map((r) => canonicalTest(r.data))
                    .toList()
                  ..sort(),
        };
        final before = hashes.sha256
            .convert(utf8.encode(canonicalTest(await sql())))
            .toString();
        var reached = false;
        final service = CompanyJobCommands(
          enrollment: enrollment,
          beforeCommit: () async {
            reached = true;
            final row = (await db.select(db.companyJobs).get()).single;
            if (mutation == 'receipt seal') {
              final receipt =
                  jsonDecode(row.receiptBytes) as Map<String, dynamic>;
              receipt['seal'] = base64Encode(List<int>.filled(64, 7));
              await db.customStatement(
                'UPDATE company_jobs SET receipt_bytes = ? WHERE job_id = ?',
                [canonicalTest(receipt), action.jobId],
              );
            } else {
              final audit = jsonDecode(row.auditBytes) as Map<String, dynamic>;
              audit['extra'] = 'must refuse unsealed SQL evidence';
              await db.customStatement(
                'UPDATE company_jobs SET audit_bytes = ? WHERE job_id = ?',
                [canonicalTest(audit), action.jobId],
              );
            }
          },
        );
        await expectLater(
          service.createJob(action, ownerSession: owner),
          throwsA(anyOf(isA<StateError>(), isA<JobLineRefusal>())),
        );
        expect(reached, isTrue);
        expect(
          hashes.sha256
              .convert(utf8.encode(canonicalTest(await sql())))
              .toString(),
          before,
        );
        await installation.reconcile(db);
        expect(installation.readiness, InstallationReadiness.ready);
        final state = jsonDecode(
          utf8.decode(store.states[installation.namespace]!.bytes),
        );
        expect(state['pendingCommand'], isNull);
        final receipt = await CompanyJobCommands(enrollment: enrollment)
            .createJob(action, ownerSession: owner);
        expect(receipt.status, 'applied');
        expect((await db.select(db.jobs).get()).single.id, action.jobId);
        expect(await db.select(db.companyJobs).get(), hasLength(1));
      },
    );
  }
}
