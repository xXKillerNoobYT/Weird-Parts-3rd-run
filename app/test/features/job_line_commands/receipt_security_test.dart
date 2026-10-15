import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'atomic_job_line_support.dart';

Map<String, Object?> snapshot(File file) {
  final db = sqlite.sqlite3.open(file.path);
  try {
    return {
      for (final name in [
        'job_lines',
        'order_splits',
        'job_line_baselines',
        'job_line_operations',
        'job_line_receipts',
        'job_line_audits',
        'job_line_outgoing',
        'job_line_conflicts',
      ])
        name: db.select('SELECT * FROM $name').map((r) => canonical(r)).toList()
          ..sort(),
    };
  } finally {
    db.dispose();
  }
}

// Frozen schema-3 migration from 034e200. Its downgrade branch must reject
// schema 4 before Drift can retag the file or an old writer can touch its rows.
class Schema3Database extends AppDatabase {
  Schema3Database(super.executor) : super.forTesting();
  @override
  int get schemaVersion => 3;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from > to) {
        throw StateError('A newer database requires a compatible app');
      }
      await transaction(() async {
        if (from < 2) {
          await m.addColumn(brandVersions, brandVersions.varianceName);
          await m.addColumn(brandVersions, brandVersions.isMain);
        }
        if (from < 3) {
          await m.createTable(companyAuthorityFacts);
          await m.createTable(jobLineBaselines);
          await m.createTable(jobLineOperations);
          await m.createTable(jobLineReceipts);
          await m.createTable(jobLineAudits);
          await m.createTable(jobLineOutgoing);
          await m.createTable(jobLineConflicts);
        }
      });
    },
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AtomicFixture fixture;
  setUp(() async {
    fixture = await AtomicFixture.create();
  });
  tearDown(() async {
    await fixture.dispose();
  });

  Future<void> rotate({
    bool revokeAuthor = false,
    bool revokeReceiver = false,
  }) async {
    fixture.facts['authority'] = (fixture.facts['authority'] as int) + 1;
    final devices = fixture.facts['devices'] as List;
    if (revokeAuthor) {
      devices[0]['revoked'] = true;
      (fixture.facts['users'] as List)[0]['revoked'] = true;
    }
    if (revokeReceiver) devices[1]['revoked'] = true;
    await fixture.publishFacts();
  }

  for (final character in ['x', '界']) {
    test(
      'full length $character notes preserve large local incoming and replay receipts',
      () async {
        final notes = character * 4096;
        final command = fixture.command(JobLinePatch(notes: SetField(notes)));
        final local = await fixture.commit(0, command);
        expect(local.status, 'applied');
        final envelope = jsonDecode(local.bytes) as Map;
        expect((envelope['bytes'] as String).length, greaterThan(4096));
        expect(local.operationBytes.length, lessThanOrEqualTo(65536));
        expect(
          utf8.encode(local.bytes).length,
          lessThanOrEqualTo(kJobLineReceiptMaximumBytes),
        );
        final incoming = await fixture
            .commands(1)
            .applyIncoming(local.operationBytes);
        expect(incoming.status, 'applied');
        expect(incoming.operationBytes, local.operationBytes);
        for (var i = 0; i < 2; i++) {
          expect((await fixture.row(i)).notes, notes);
          final before = snapshot(fixture.files[i]);
          await fixture.reopen(i);
          final replay = i == 0
              ? await fixture.commit(0, command)
              : await fixture.commands(1).applyIncoming(local.operationBytes);
          expect(replay.bytes, i == 0 ? local.bytes : incoming.bytes);
          expect(replay.operationBytes, local.operationBytes);
          expect(snapshot(fixture.files[i]), before);
        }
      },
    );
  }

  test('large deferred receipt and semantic retry preserve original operation bytes', () async {
    final parent = await fixture.commit(
      0,
      fixture.command(const JobLinePatch(notes: SetField('Parent'))),
    );
    final child = await fixture.commit(
      0,
      fixture.command(
        JobLinePatch(notes: SetField('x' * 4096)),
        parents: [operationKey(parent)],
      ),
    );
    final deferred = await fixture
        .commands(1)
        .applyIncoming(child.operationBytes);
    expect(deferred.status, 'deferred');
    expect(deferred.operationBytes, child.operationBytes);
    final body =
        (jsonDecode(utf8.decode(child.operationBytes)) as Map)['body'] as Map;
    Future<JobLineCommandReceipt> retry() => fixture
        .commands(1)
        .retryDeferred(
          companyId: company,
          originGeneration: body['generation'] as String,
          requestId: body['request'] as String,
        );
    expect((await retry()).bytes, deferred.bytes);
    await fixture.commands(1).applyIncoming(parent.operationBytes);
    final applied = await retry();
    expect(applied.status, 'applied');
    expect(applied.operationBytes, child.operationBytes);
    expect((await retry()).bytes, applied.bytes);
    expect(
      (await fixture.commands(1).applyIncoming(child.operationBytes)).bytes,
      deferred.bytes,
    );
  });

  for (final malformed in ['type', 'base64', 'oversized', 'noncanonical']) {
    test(
      'receipt embedded operation $malformed refuses before effects',
      () async {
        final local = await fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('Original'))),
        );
        final value = jsonDecode(local.bytes) as Map<String, dynamic>;
        value['bytes'] = switch (malformed) {
          'type' => 7,
          'base64' => '???',
          'oversized' => base64Encode(List.filled(65537, 0)),
          _ => base64Encode(
            utf8.encode(' ${utf8.decode(local.operationBytes)}'),
          ),
        };
        final before = snapshot(fixture.files[0]);
        expect(
          () => decodeJobLineReceipt(canonical(value)),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(snapshot(fixture.files[0]), before);
      },
    );
  }

  test('v2 receipts carry installation admission seals', () async {
    final receipt = await fixture.commit(
      0,
      fixture.command(const JobLinePatch(notes: SetField('Sealed'))),
    );
    final value = jsonDecode(receipt.bytes) as Map;
    expect(value['v'], 2);
    expect(base64Decode(value['seal'] as String), hasLength(64));
  });

  test('sealed incoming exact replay survives historical author revocation and facts rotation', () async {
    final command = fixture.command(
      const JobLinePatch(notes: SetField('Admitted')),
    );
    final authored = await fixture.commit(0, command);
    final saved = await fixture
        .commands(1)
        .applyIncoming(authored.operationBytes);
    final unseen = await fixture.commit(
      0,
      fixture.command(const JobLinePatch(notes: SetField('Unseen'))),
    );
    await rotate(revokeAuthor: true);
    final before = snapshot(fixture.files[1]);
    final replay = await fixture
        .commands(1)
        .applyIncoming(authored.operationBytes);
    expect(replay.bytes, saved.bytes);
    expect(snapshot(fixture.files[1]), before);
    await expectLater(
      fixture.commands(1).applyIncoming(unseen.operationBytes),
      throwsA(isA<JobLineRefusal>()),
    );
    expect(snapshot(fixture.files[1]), before);
  });

  test('fresh current local session retries original bytes after authority rotation', () async {
    final command = fixture.command(
      const JobLinePatch(notes: SetField('Original')),
    );
    final saved = await fixture.commit(0, command);
    await rotate();
    final before = snapshot(fixture.files[0]);
    expect((await fixture.commit(0, command)).bytes, saved.bytes);
    expect(snapshot(fixture.files[0]), before);
    final differentActor = await fixture.session(
      0,
      command,
      changes: {'user': secondUser},
    );
    await expectLater(
      fixture.commands(0).patchJobLine(differentActor, command),
      throwsA(isA<JobLineRefusal>()),
    );
    expect(snapshot(fixture.files[0]), before);
  });

  test(
    'revoked current receiver cannot disclose a sealed historical receipt',
    () async {
      final authored = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Admitted'))),
      );
      await fixture.commands(1).applyIncoming(authored.operationBytes);
      await rotate(revokeReceiver: true);
      final before = snapshot(fixture.files[1]);
      await expectLater(
        fixture.commands(1).applyIncoming(authored.operationBytes),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test(
    'local retry revalidates fresh user inside the owning transaction',
    () async {
      final command = fixture.command(
        const JobLinePatch(notes: SetField('Original')),
      );
      await fixture.commit(0, command);
      await fixture.databases[0].close();
      final interceptor = FixtureQueryInterceptor();
      final db = AppDatabase.forTesting(
        NativeDatabase(fixture.files[0]).interceptWith(interceptor),
      );
      fixture.databases[0] = db;
      await fixture.installations[0].start(db);
      final session = await fixture.session(0, command);
      var changed = false;
      interceptor.beforeCustom = (statement) async {
        if (!statement.startsWith('UPDATE app_settings')) return;
        interceptor.beforeCustom = null;
        (fixture.facts['users'] as List)[0]['revoked'] = true;
        await fixture.publishFacts();
        changed = true;
      };
      final before = snapshot(fixture.files[0]);
      await expectLater(
        fixture.commands(0).patchJobLine(session, command),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(changed, isTrue);
      expect(snapshot(fixture.files[0]), before);
    },
  );

  test('sealed deferral replays after author revocation but cannot semantically resume', () async {
    final parent = await fixture.commit(
      0,
      fixture.command(const JobLinePatch(notes: SetField('Parent'))),
    );
    final child = await fixture.commit(
      0,
      fixture.command(
        const JobLinePatch(notes: SetField('Child')),
        parents: [operationKey(parent)],
      ),
    );
    final deferred = await fixture
        .commands(1)
        .applyIncoming(child.operationBytes);
    await rotate(revokeAuthor: true);
    final body =
        (jsonDecode(utf8.decode(child.operationBytes)) as Map)['body'] as Map;
    final before = snapshot(fixture.files[1]);
    final retry = await fixture
        .commands(1)
        .retryDeferred(
          companyId: company,
          originGeneration: body['generation'] as String,
          requestId: body['request'] as String,
        );
    expect(retry.bytes, deferred.bytes);
    expect(
      (await fixture.commands(1).applyIncoming(child.operationBytes)).bytes,
      deferred.bytes,
    );
    expect(snapshot(fixture.files[1]), before);
    await expectLater(
      fixture.commands(1).applyIncoming(parent.operationBytes),
      throwsA(isA<JobLineRefusal>()),
    );
  });

  for (final field in ['status', 'parent', 'bytes', 'seal', 'legacy']) {
    test(
      'tampered receipt $field refuses exact replay without effects',
      () async {
        final authored = await fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('Admitted'))),
        );
        final saved = await fixture
            .commands(1)
            .applyIncoming(authored.operationBytes);
        final value = jsonDecode(saved.bytes) as Map<String, dynamic>;
        switch (field) {
          case 'status':
            value['status'] = 'conflict';
          case 'parent':
            value['parent'] = saved.key;
          case 'bytes':
            value['bytes'] = base64Encode(utf8.encode('{}'));
          case 'seal':
            value['seal'] = base64Encode(List.filled(64, 0));
          case 'legacy':
            value['v'] = 1;
            value.remove('seal');
        }
        final db = fixture.databases[1];
        await (db.update(
          db.jobLineReceipts,
        )..where((t) => t.receiptKey.equals(saved.key))).write(
          JobLineReceiptsCompanion(receiptBytes: Value(canonical(value))),
        );
        final before = snapshot(fixture.files[1]);
        await expectLater(
          fixture.commands(1).applyIncoming(authored.operationBytes),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(snapshot(fixture.files[1]), before);
      },
    );
  }

  test(
    'alternate seal encoding cannot change exact saved receipt bytes',
    () async {
      final authored = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Original'))),
      );
      final saved = await fixture
          .commands(1)
          .applyIncoming(authored.operationBytes);
      final value = jsonDecode(saved.bytes) as Map<String, dynamic>;
      final original = value['seal'] as String;
      value['seal'] = original.replaceAll('=', '%3D');
      expect(value['seal'], isNot(original));
      expect(base64Decode(value['seal'] as String), base64Decode(original));
      final db = fixture.databases[1];
      await db
          .update(db.jobLineReceipts)
          .write(
            JobLineReceiptsCompanion(receiptBytes: Value(canonical(value))),
          );
      final before = snapshot(fixture.files[1]);
      await expectLater(
        fixture.commands(1).applyIncoming(authored.operationBytes),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test('linked transition requires its exact sealed parent', () async {
    final parent = await fixture.commit(
      0,
      fixture.command(const JobLinePatch(notes: SetField('Parent'))),
    );
    final child = await fixture.commit(
      0,
      fixture.command(
        const JobLinePatch(notes: SetField('Child')),
        parents: [operationKey(parent)],
      ),
    );
    final deferred = await fixture
        .commands(1)
        .applyIncoming(child.operationBytes);
    await fixture.commands(1).applyIncoming(parent.operationBytes);
    final body =
        (jsonDecode(utf8.decode(child.operationBytes)) as Map)['body'] as Map;
    Future<JobLineCommandReceipt> retry() => fixture
        .commands(1)
        .retryDeferred(
          companyId: company,
          originGeneration: body['generation'] as String,
          requestId: body['request'] as String,
        );
    final applied = await retry();
    expect((jsonDecode(applied.bytes) as Map)['parent'], deferred.key);
    await rotate(revokeAuthor: true);
    expect((await retry()).bytes, applied.bytes);
    final db = fixture.databases[1];
    await (db.update(
      db.jobLineReceipts,
    )..where((t) => t.receiptKey.equals(deferred.key))).write(
      JobLineReceiptsCompanion(
        receiptBytes: Value(
          canonical({
            ...jsonDecode(deferred.bytes) as Map,
            'status': 'applied',
          }),
        ),
      ),
    );
    await expectLater(retry(), throwsA(isA<JobLineRefusal>()));
  });

  test(
    'deferred new semantic admission still requires current original author',
    () async {
      final parent = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Parent'))),
      );
      final child = await fixture.commit(
        0,
        fixture.command(
          const JobLinePatch(notes: SetField('Child')),
          parents: [operationKey(parent)],
        ),
      );
      await fixture.commands(1).applyIncoming(child.operationBytes);
      await fixture.commands(1).applyIncoming(parent.operationBytes);
      await rotate(revokeAuthor: true);
      final body =
          (jsonDecode(utf8.decode(child.operationBytes)) as Map)['body'] as Map;
      final before = snapshot(fixture.files[1]);
      await expectLater(
        fixture
            .commands(1)
            .retryDeferred(
              companyId: company,
              originGeneration: body['generation'] as String,
              requestId: body['request'] as String,
            ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test(
    'coherent multirow forgery cannot reuse the admitted receipt seal',
    () async {
      final command = fixture.command(
        const JobLinePatch(notes: SetField('Original')),
      );
      final authored = await fixture.commit(0, command);
      final saved = await fixture
          .commands(1)
          .applyIncoming(authored.operationBytes);
      final forgedCommand = fixture.command(
        const JobLinePatch(notes: SetField('Forged')),
        requestId: command.requestId,
      );
      final envelope = jsonDecode(
        utf8.decode(authored.operationBytes),
      ) as Map<String, dynamic>;
      final body = envelope['body'] as Map<String, dynamic>;
      body['units'] = {'notes': 'Forged'};
      body['command'] = forgedCommand.commitment;
      final forgedBytes = canonical(envelope);
      final commitment = digest(body);
      final value = jsonDecode(saved.bytes) as Map<String, dynamic>;
      value['operation'] = commitment;
      value['command'] = forgedCommand.commitment;
      value['bytes'] = base64Encode(utf8.encode(forgedBytes));
      final db = fixture.databases[1];
      await db
          .update(db.jobLineOperations)
          .write(
            JobLineOperationsCompanion(
              commitment: Value(commitment),
              operationBytes: Value(forgedBytes),
            ),
          );
      await db
          .update(db.jobLineReceipts)
          .write(
            JobLineReceiptsCompanion(
              operationCommitment: Value(commitment),
              commandCommitment: Value(forgedCommand.commitment),
              receiptBytes: Value(canonical(value)),
            ),
          );
      final audit = jsonDecode(
        (await db.select(db.jobLineAudits).getSingle()).auditBytes,
      ) as Map<String, dynamic>;
      audit['operation'] = commitment;
      await db
          .update(db.jobLineAudits)
          .write(JobLineAuditsCompanion(auditBytes: Value(canonical(audit))));
      await db
          .update(db.jobLines)
          .write(const JobLinesCompanion(notes: Value('Forged')));
      final before = snapshot(fixture.files[1]);
      await expectLater(
        fixture
            .commands(1)
            .applyIncoming(Uint8List.fromList(utf8.encode(forgedBytes))),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test(
    'a seal copied from another receiver cannot cover this receipt',
    () async {
      final authored = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Original'))),
      );
      final saved = await fixture
          .commands(1)
          .applyIncoming(authored.operationBytes);
      final value = jsonDecode(saved.bytes) as Map<String, dynamic>;
      value['seal'] = (jsonDecode(authored.bytes) as Map)['seal'];
      final db = fixture.databases[1];
      await db
          .update(db.jobLineReceipts)
          .write(
            JobLineReceiptsCompanion(receiptBytes: Value(canonical(value))),
          );
      final before = snapshot(fixture.files[1]);
      await expectLater(
        fixture.commands(1).applyIncoming(authored.operationBytes),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test(
    'a changed receiving store generation cannot reuse an old admission',
    () async {
      final authored = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Original'))),
      );
      await fixture.commands(1).applyIncoming(authored.operationBytes);
      await rotate(revokeAuthor: true);
      final store = fixture.secureStores[1];
      final namespace = fixture.installations[1].namespace;
      final record = jsonDecode(
        utf8.decode(store.states[namespace]!.bytes),
      ) as Map<String, dynamic>;
      record['store'] = const Uuid().v4();
      store.states[namespace] = ProtectedInstallationState(
        const Uuid().v4(),
        Uint8List.fromList(utf8.encode(jsonEncode(record))),
      );
      await fixture.publishFacts();
      final before = snapshot(fixture.files[1]);
      await expectLater(
        fixture.commands(1).applyIncoming(authored.operationBytes),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test(
    'retry in a new generation creates a base deferral without a self parent',
    () async {
      final parent = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Parent'))),
      );
      final child = await fixture.commit(
        0,
        fixture.command(
          const JobLinePatch(notes: SetField('Child')),
          parents: [operationKey(parent)],
        ),
      );
      final first = await fixture
          .commands(1)
          .applyIncoming(child.operationBytes);
      final store = fixture.secureStores[1];
      final namespace = fixture.installations[1].namespace;
      final record = jsonDecode(
        utf8.decode(store.states[namespace]!.bytes),
      ) as Map<String, dynamic>;
      record['store'] = const Uuid().v4();
      store.states[namespace] = ProtectedInstallationState(
        const Uuid().v4(),
        Uint8List.fromList(utf8.encode(jsonEncode(record))),
      );
      await fixture.publishFacts();
      final body =
          (jsonDecode(utf8.decode(child.operationBytes)) as Map)['body'] as Map;
      Future<JobLineCommandReceipt> retry() => fixture
          .commands(1)
          .retryDeferred(
            companyId: company,
            originGeneration: body['generation'] as String,
            requestId: body['request'] as String,
          );
      final second = await retry();
      expect(second.status, 'deferred');
      expect(second.key, isNot(first.key));
      expect((jsonDecode(second.bytes) as Map)['parent'], isNull);
      expect(await fixture.counts(1), [1, 1, 2, 2, 0, 0]);
      final before = snapshot(fixture.files[1]);
      expect((await retry()).bytes, second.bytes);
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test(
    'oversized receipt refuses before JSON decoding without effects',
    () async {
      final authored = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Original'))),
      );
      await fixture.commands(1).applyIncoming(authored.operationBytes);
      final db = fixture.databases[1];
      await db
          .update(db.jobLineReceipts)
          .write(
            JobLineReceiptsCompanion(
              receiptBytes: Value('[' * (kJobLineReceiptMaximumBytes + 1)),
            ),
          );
      final before = snapshot(fixture.files[1]);
      await expectLater(
        fixture.commands(1).applyIncoming(authored.operationBytes),
        throwsA(
          predicate(
            (e) =>
                e is JobLineRefusal && e.reason == 'receipt exceeds byte limit',
          ),
        ),
      );
      expect(snapshot(fixture.files[1]), before);
    },
  );

  test('oversized pending receipt holds recovery without clearing protected intent', () async {
    final command = fixture.command(
      const JobLinePatch(notes: SetField('Committed')),
    );
    await expectLater(
      fixture
          .commands(
            0,
            afterCommit: () async {
              throw StateError('lost');
            },
          )
          .patchJobLine(await fixture.session(0, command), command),
      throwsStateError,
    );
    final db = fixture.databases[0];
    await db
        .update(db.jobLineReceipts)
        .write(
          JobLineReceiptsCompanion(
            receiptBytes: Value('[' * (kJobLineReceiptMaximumBytes + 1)),
          ),
        );
    final protected =
        fixture.secureStores[0].states[fixture.installations[0].namespace]!;
    final before = snapshot(fixture.files[0]);
    await fixture.reopen(0);
    expect(
      fixture.installations[0].readiness,
      InstallationReadiness.needsRecovery,
    );
    expect(
      fixture.secureStores[0].states[fixture.installations[0].namespace]!.bytes,
      protected.bytes,
    );
    expect(snapshot(fixture.files[0]), before);
  });

  test(
    'changed unsigned candidate cannot obtain a seal despite a held intent',
    () async {
      await fixture.databases[0].close();
      final interceptor = FixtureQueryInterceptor();
      final db = AppDatabase.forTesting(
        NativeDatabase(fixture.files[0]).interceptWith(interceptor),
      );
      fixture.databases[0] = db;
      await fixture.installations[0].start(db);
      var changed = false;
      interceptor.beforeSelect = (statement) async {
        if (!statement.contains('job_line_receipts')) return;
        final state =
            fixture.secureStores[0].states[fixture.installations[0].namespace]!;
        final record = jsonDecode(utf8.decode(state.bytes)) as Map;
        if (record['pendingCommand'] == null) return;
        interceptor.beforeSelect = null;
        final saved = await db.select(db.jobLineReceipts).getSingle();
        final value = jsonDecode(saved.receiptBytes) as Map<String, dynamic>;
        value['status'] = 'conflict';
        await db
            .update(db.jobLineReceipts)
            .write(
              JobLineReceiptsCompanion(receiptBytes: Value(canonical(value))),
            );
        changed = true;
      };
      final before = snapshot(fixture.files[0]);
      await expectLater(
        fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('Refused'))),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(changed, isTrue);
      expect(snapshot(fixture.files[0]), before);
      expect(fixture.installations[0].readiness, InstallationReadiness.ready);
    },
  );

  test(
    'frozen schema3 migration refuses schema4 without row or version changes',
    () async {
      await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Kept'))),
      );
      await fixture.databases[0].close();
      final before = snapshot(fixture.files[0]);
      final old = Schema3Database(NativeDatabase(fixture.files[0]));
      try {
        await expectLater(old.customSelect('SELECT 1').get(), throwsStateError);
      } finally {
        await old.close();
      }
      final raw = sqlite.sqlite3.open(fixture.files[0].path);
      expect(raw.select('PRAGMA user_version').single.values.single, 4);
      raw.dispose();
      expect(snapshot(fixture.files[0]), before);
    },
  );

  test('populated experimental schema3 refuses upgrade before retag or history writes', () async {
    await fixture.commit(
      0,
      fixture.command(const JobLinePatch(notes: SetField('Legacy evidence'))),
    );
    await fixture.databases[0].close();
    final raw = sqlite.sqlite3.open(fixture.files[0].path);
    raw.execute('PRAGMA user_version = 3');
    raw.dispose();
    final before = snapshot(fixture.files[0]);
    final newer = AppDatabase.forTesting(NativeDatabase(fixture.files[0]));
    try {
      await expectLater(newer.customSelect('SELECT 1').get(), throwsStateError);
    } finally {
      await newer.close();
    }
    final check = sqlite.sqlite3.open(fixture.files[0].path);
    expect(check.select('PRAGMA user_version').single.values.single, 3);
    check.dispose();
    expect(snapshot(fixture.files[0]), before);
  });

  test(
    'empty experimental schema3 upgrades without business row changes',
    () async {
      await fixture.databases[0].close();
      final raw = sqlite.sqlite3.open(fixture.files[0].path);
      raw.execute('PRAGMA user_version = 3');
      raw.dispose();
      final before = snapshot(fixture.files[0]);
      final newer = AppDatabase.forTesting(NativeDatabase(fixture.files[0]));
      try {
        expect(
          (await newer.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          4,
        );
        expect(snapshot(fixture.files[0]), before);
      } finally {
        await newer.close();
      }
    },
  );
}
