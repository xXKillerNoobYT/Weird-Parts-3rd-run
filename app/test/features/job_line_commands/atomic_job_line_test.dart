import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import 'atomic_job_line_support.dart';

void main() {
  // Every fixture deliberately owns two independent file-backed executors.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  Map<String, Object?> businessRows(File file) {
    final db = raw_sqlite.sqlite3.open(file.path);
    try {
      return {
        for (final name in [
          'device_profiles',
          'app_settings',
          'categories',
          'styles',
          'types',
          'devices',
          'brands',
          'suppliers',
          'parts',
          'part_devices',
          'brand_versions',
          'supplier_listings',
          'jobs',
          'job_lines',
          'order_splits',
        ])
          name:
              (db
                  .select('SELECT * FROM "$name"')
                  .map((row) => canonical(row))
                  .toList()
                ..sort()),
      };
    } finally {
      db.dispose();
    }
  }

  test(
    'new stores retain immutable job-line history separately from rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wp-atomic-line-',
      );
      final db = AppDatabase.forTesting(
        NativeDatabase(File('${directory.path}/shop.db')),
      );
      try {
        final rows = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get();
        expect(
          rows.map((row) => row.read<String>('name')),
          containsAll([
            'job_line_baselines',
            'job_line_operations',
            'job_line_receipts',
            'job_line_audits',
            'job_line_outgoing',
            'job_line_conflicts',
            'company_authority_facts',
          ]),
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  group('authenticated atomic job-line command', () {
    late AtomicFixture fixture;
    setUp(() async {
      fixture = await AtomicFixture.create();
    });
    tearDown(() async {
      await fixture.dispose();
    });

    test('authority update during witness cannot be overwritten using a mutable revision', () async {
      await fixture.databases[0].close();
      final interceptor = FixtureQueryInterceptor();
      final db = AppDatabase.forTesting(
        NativeDatabase(File('${fixture.directory.path}/0.db'))
            .interceptWith(interceptor),
      );
      fixture.databases[0] = db;
      await fixture.installations[0].reconcile(db);
      var changed = false;
      interceptor.beforeSelect = (statement) async {
        if (!statement.startsWith('SELECT * FROM job_line_baselines')) return;
        interceptor.beforeSelect = null;
        final security = fixture.installations[0];
        final store = fixture.secureStores[0];
        final old = store.states[security.namespace]!;
        final record =
            jsonDecode(utf8.decode(old.bytes)) as Map<String, dynamic>;
        record['floors'] = {'authority.$company': 2};
        await store.compareAndSwapState(
          security.namespace,
          expectedRevision: old.revision,
          nextRevision: const Uuid().v4(),
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
        );
        await security.reconcile(db);
        changed = true;
      };
      await expectLater(
        fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(notes: SetField('Stale authority')),
          ),
        ),
        throwsStateError,
      );
      expect(changed, isTrue);
      final protected = jsonDecode(
        utf8.decode(
          fixture
              .secureStores[0]
              .states[fixture.installations[0].namespace]!
              .bytes,
        ),
      ) as Map;
      expect(protected['floors'], {'authority.$company': 2});
      expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
      expect((await fixture.row(0)).notes, 'Old note');
    });

    test(
      'archive predicate and write exclude adoption on a second connection',
      () async {
        await fixture.databases[0].close();
        final interceptor = FixtureQueryInterceptor();
        final db = AppDatabase.forTesting(
          NativeDatabase(File('${fixture.directory.path}/0.db'))
              .interceptWith(interceptor),
        );
        fixture.databases[0] = db;
        final other = AppDatabase.forTesting(
          NativeDatabase(File('${fixture.directory.path}/0.db')),
        );
        try {
          final otherSecurity = InstallationSecurity(
            store: fixture.secureStores[0],
            namespace: fixture.installations[0].namespace,
          );
          await otherSecurity.start(other);
          final otherService = JobLineCommands(
            authorization: JobLineAuthorization(
              db: other,
              installation: otherSecurity,
            ),
          );
          final command = fixture.command(
            const JobLinePatch(notes: SetField('Racing adoption')),
          );
          final session = await otherService.authorization.verify(
            command,
            await fixture.assertion(0, command),
          );
          var raced = false;
          interceptor.afterSelect = (statement) async {
            if (!statement.contains('job_line_baselines b JOIN job_lines')) {
              return;
            }
            interceptor.afterSelect = null;
            await expectLater(
              otherService.patchJobLine(session, command),
              throwsA(predicate((e) => '$e'.contains('locked'))),
            );
            raced = true;
          };
          await db.jobsDao.archiveJob(job);
          expect(raced, isTrue);
          expect((await db.select(db.jobs).getSingle()).status, 'archived');
          expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
        } finally {
          await other.close();
        }
      },
    );

    test(
      'pending command excludes a second same-file writer and reset/restore',
      () async {
        final other = AppDatabase.forTesting(
          NativeDatabase(File('${fixture.directory.path}/0.db')),
        );
        try {
          final otherSecurity = InstallationSecurity(
            store: fixture.secureStores[0],
            namespace: fixture.installations[0].namespace,
          );
          await otherSecurity.start(other);
          final otherService = JobLineCommands(
            authorization: JobLineAuthorization(
              db: other,
              installation: otherSecurity,
            ),
          );
          final competing = fixture.command(
            const JobLinePatch(notes: SetField('Second writer')),
          );
          final session = await otherService.authorization.verify(
            competing,
            await fixture.assertion(0, competing),
          );
          final command = fixture.command(
            const JobLinePatch(notes: SetField('First writer')),
          );
          final service = fixture.commands(
            0,
            beforeCommit: () async {
              await expectLater(
                fixture.installations[0].prepareReset(),
                throwsStateError,
              );
              await expectLater(
                fixture.installations[0].prepareBusinessRestore(
                  fixture.databases[0],
                ),
                throwsStateError,
              );
              await expectLater(
                otherService.patchJobLine(session, competing),
                throwsA(predicate((e) => '$e'.contains('locked'))),
              );
            },
          );
          await service.patchJobLine(
            await fixture.session(0, command),
            command,
          );
          expect((await fixture.row(0)).notes, 'First writer');
          expect(await fixture.counts(0), [1, 1, 1, 1, 1, 0]);
        } finally {
          await other.close();
        }
      },
    );

    test('local missing parents refuse instead of losing eventual outgoing provenance', () async {
      final missing = '${const Uuid().v4()}/${const Uuid().v4()}';
      await expectLater(
        fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(notes: SetField('Missing')),
            parents: [missing],
          ),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
    });

    test('revoked receiving membership refuses a currently authorized original author', () async {
      (fixture.facts['devices'] as List)[1]['revoked'] = true;
      fixture.facts['authority'] = 2;
      await fixture.publishFacts();
      final receipt = await fixture.commit(
        0,
        fixture.command(
          const JobLinePatch(notes: SetField('Authorized author')),
        ),
      );
      await expectLater(
        fixture.commands(1).applyIncoming(receipt.operationBytes),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await fixture.counts(1), [0, 0, 0, 0, 0, 0]);
    });

    for (final field in ['id', 'grant']) {
      for (final mutation in ['missing', 'null', 'malformed']) {
        test(
          'incoming rejects $mutation receiver $field before real floor lookups',
          () async {
            final receivers = List<Object?>.from(
              fixture.facts['devices'] as List,
            );
            fixture.facts['devices'] = receivers;
            final receiver = Map<String, Object?>.from(receivers[1] as Map);
            receivers[1] = receiver;
            if (mutation == 'missing') {
              receiver.remove(field);
            } else {
              receiver[field] = mutation == 'null' ? null : 'malformed';
            }
            fixture.facts['authority'] = 2;
            await fixture.publishFacts(
              floors: {
                if (field == 'id') 'revocation.device.${fixture.devices[1]}': 1,
                if (field == 'grant') ...{
                  'revocation.grant.${fixture.grants[1]}': 1,
                  'grant.${fixture.grants[1]}': 2,
                },
              },
            );
            final before =
                (await fixture.databases[1]
                        .customSelect('SELECT * FROM job_lines')
                        .getSingle())
                    .data;
            final receipt = await fixture.commit(
              0,
              fixture.command(
                const JobLinePatch(notes: SetField('Denied incoming')),
              ),
            );
            await expectLater(
              fixture.commands(1).applyIncoming(receipt.operationBytes),
              throwsA(isA<JobLineRefusal>()),
            );
            expect(await fixture.counts(1), [0, 0, 0, 0, 0, 0]);
            expect(
              (await fixture.databases[1]
                      .customSelect('SELECT * FROM job_lines')
                      .getSingle())
                  .data,
              before,
            );
          },
        );
      }
    }

    for (final version in [null, 0, -1, 1.5]) {
      test('incoming rejects invalid receiver version $version', () async {
        final receivers = List<Object?>.from(fixture.facts['devices'] as List);
        fixture.facts['devices'] = receivers;
        final receiver = Map<String, Object?>.from(receivers[1] as Map);
        receivers[1] = receiver;
        receiver['version'] = version;
        fixture.facts['authority'] = 2;
        await fixture.publishFacts();
        final receipt = await fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(notes: SetField('Denied version')),
          ),
        );
        final before = await fixture.row(1);
        await expectLater(
          fixture.commands(1).applyIncoming(receipt.operationBytes),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(await fixture.counts(1), [0, 0, 0, 0, 0, 0]);
        expect(await fixture.row(1), before);
      });
    }

    test(
      'new receiving generation cannot reuse an old semantic receipt',
      () async {
        final a = await fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(
              quantities: JobLineQuantities(needed: 8, shopPull: 3, unit: 'ea'),
            ),
          ),
        );
        final first = await fixture.commands(1).applyIncoming(a.operationBytes);
        final security = fixture.installations[1];
        final store = fixture.secureStores[1];
        final current = store.states[security.namespace]!;
        final record =
            jsonDecode(utf8.decode(current.bytes)) as Map<String, dynamic>;
        record['store'] = const Uuid().v4();
        await store.compareAndSwapState(
          security.namespace,
          expectedRevision: current.revision,
          nextRevision: const Uuid().v4(),
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
        );
        final binding = jsonDecode(
          (await fixture.databases[1].settingsDao.getSetting(
            kInstallationBindingKey,
          ))!,
        ) as Map;
        binding['store'] = record['store'];
        await fixture.databases[1].settingsDao.setSetting(
          kInstallationBindingKey,
          jsonEncode(binding),
        );
        final second = await fixture
            .commands(1)
            .applyIncoming(a.operationBytes);
        expect(second.key, isNot(first.key));
        expect(second.status, 'applied');
        expect((await fixture.row(1)).neededQty, 8);
        expect((await fixture.row(1)).shopPullQty, 3);
        expect((await fixture.row(1)).revision, 2);
        expect(await fixture.counts(1), [1, 1, 2, 2, 0, 0]);
      },
    );

    test('two file stores apply once with exact original bytes and replay receipts', () async {
      final command = fixture.command(
        const JobLinePatch(
          quantities: JobLineQuantities(needed: 9, shopPull: 15, unit: 'ea'),
          notes: SetField(null),
        ),
      );
      final a = await fixture.commit(0, command);
      expect(a.status, 'applied');
      expect(await fixture.counts(0), [1, 1, 1, 1, 1, 0]);
      expect((await fixture.row(0)).neededQty, 9);
      expect((await fixture.row(0)).shopPullQty, 15);
      expect((await fixture.row(0)).notes, isNull);
      expect((await fixture.row(0)).customNotes, 'Old custom note');
      final b = await fixture.commands(1).applyIncoming(a.operationBytes);
      expect(b.status, 'applied');
      expect(b.operationBytes, a.operationBytes);
      expect(b.key, isNot(a.key));
      expect(await fixture.counts(1), [1, 1, 1, 1, 0, 0]);
      expect((await fixture.commit(0, command)).bytes, a.bytes);
      expect(
        (await fixture.commands(1).applyIncoming(a.operationBytes)).bytes,
        b.bytes,
      );
      expect((await fixture.row(1)).shopPullQty, 15);
      await fixture.reopen(1);
      expect(
        (await fixture.commands(1).applyIncoming(a.operationBytes)).bytes,
        b.bytes,
      );
      expect(fixture.secureStores.every((s) => s.maximumBytes <= 2048), isTrue);
    });

    test(
      'omitted notes preserve state while explicit null clears it',
      () async {
        final first = await fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(customNotes: SetField('New custom note')),
          ),
        );
        expect((await fixture.row(0)).notes, 'Old note');
        expect((await fixture.row(0)).customNotes, 'New custom note');
        await fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(notes: SetField(null)),
            parents: [operationKey(first)],
          ),
        );
        expect((await fixture.row(0)).notes, isNull);
        expect((await fixture.row(0)).customNotes, 'New custom note');
      },
    );

    for (final invalid in <String, Map<String, Object?>>{
      'unknown user': {'user': '20000000-0000-4000-8000-000000000001'},
      'unknown device': {'device': '20000000-0000-4000-8000-000000000002'},
      'wrong installation': {
        'installation': '20000000-0000-4000-8000-000000000003',
      },
      'wrong grant': {'grant': '20000000-0000-4000-8000-000000000004'},
      'wrong user version': {'permission': 99},
      'unsupported authorization': {'v': 2},
    }.entries) {
      test('${invalid.key} is denied before any history mutation', () async {
        final command = fixture.command(
          const JobLinePatch(notes: SetField('Denied')),
        );
        await expectLater(
          fixture.session(0, command, changes: invalid.value),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
        expect((await fixture.row(0)).notes, 'Old note');
      });
    }
    test(
      'wrong company and shop signed assertions do not adopt legacy rows',
      () async {
        for (final command in [
          fixture.command(
            const JobLinePatch(notes: SetField('Denied')),
            companyId: '20000000-0000-4000-8000-000000000001',
          ),
          fixture.command(
            const JobLinePatch(notes: SetField('Denied')),
            shopId: '20000000-0000-4000-8000-000000000002',
          ),
        ]) {
          await expectLater(
            fixture.session(0, command),
            throwsA(isA<JobLineRefusal>()),
          );
        }
        expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
      },
    );
    test(
      'absent company pin and unsigned proof cannot issue a session',
      () async {
        final command = fixture.command(
          const JobLinePatch(notes: SetField('Denied')),
        );
        final store = fixture.secureStores[0];
        final security = fixture.installations[0];
        final existing = store.states[security.namespace]!;
        final record =
            jsonDecode(utf8.decode(existing.bytes)) as Map<String, dynamic>;
        record.remove('companyTrust');
        record.remove('pendingCommand');
        record.remove('storePath');
        record['v'] = 1;
        store.states[security.namespace] = ProtectedInstallationState(
          const Uuid().v4(),
          Uint8List.fromList(utf8.encode(jsonEncode(record))),
        );
        await fixture.databases[0].settingsDao.setSetting(
          kInstallationBindingKey,
          jsonEncode({
            'v': 1,
            'id': record['id'],
            'generation': record['generation'],
            'key': record['key'],
            'public': record['public'],
            'store': record['store'],
          }),
        );
        await expectLater(
          fixture.session(0, command),
          throwsA(isA<JobLineRefusal>()),
        );
        final signed =
            jsonDecode(utf8.decode(await fixture.assertion(0, command))) as Map;
        signed['signature'] = base64Encode(List.filled(64, 0));
        await fixture.publishFacts();
        await expectLater(
          fixture
              .commands(0)
              .authorization
              .verify(
                command,
                Uint8List.fromList(utf8.encode(canonical(signed))),
              ),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
      },
    );
    test(
      'known revocation and denied capability reject incoming original author',
      () async {
        final a = await fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('Authored'))),
        );
        await fixture.publishFacts(
          floors: {'revocation.device.${fixture.devices[0]}': 1},
        );
        await expectLater(
          fixture.commands(1).applyIncoming(a.operationBytes),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(await fixture.counts(1), [0, 0, 0, 0, 0, 0]);
        (fixture.facts['users'] as List).first['capabilities'] = <String>[];
        fixture.facts['authority'] = 2;
        await fixture.publishFacts();
        await expectLater(
          fixture.session(
            1,
            fixture.command(const JobLinePatch(notes: SetField('Denied'))),
          ),
          throwsA(isA<JobLineRefusal>()),
        );
      },
    );
    test(
      'same ID different content and author refuse without another receipt',
      () async {
        final request = const Uuid().v4();
        final command = fixture.command(
          const JobLinePatch(notes: SetField('First')),
          requestId: request,
        );
        await fixture.commit(0, command);
        await expectLater(
          fixture.commit(
            0,
            fixture.command(
              const JobLinePatch(notes: SetField('Second')),
              requestId: request,
            ),
          ),
          throwsA(isA<JobLineRefusal>()),
        );
        final otherUser = await fixture.session(
          0,
          command,
          changes: {'user': secondUser},
        );
        await expectLater(
          fixture.commands(0).patchJobLine(otherUser, command),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(await fixture.counts(0), [1, 1, 1, 1, 1, 0]);
      },
    );
    test(
      'independent notes and quantity edits converge under reversed delivery',
      () async {
        final a = await fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('A'))),
        );
        final b = await fixture.commit(
          1,
          fixture.command(
            const JobLinePatch(
              quantities: JobLineQuantities(
                needed: 12,
                shopPull: 7,
                unit: 'ft',
              ),
            ),
          ),
        );
        await fixture.commands(0).applyIncoming(b.operationBytes);
        await fixture.commands(1).applyIncoming(a.operationBytes);
        for (var i = 0; i < 2; i++) {
          expect((await fixture.row(i)).notes, 'A');
          expect((await fixture.row(i)).neededQty, 12);
          expect((await fixture.row(i)).uom, 'ft');
          expect(
            await fixture.databases[i]
                .select(fixture.databases[i].jobLineConflicts)
                .get(),
            isEmpty,
          );
        }
      },
    );
    test('same-unit alternatives have one order-independent issue and common-base value', () async {
      final a = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('A'))),
      );
      final b = await fixture.commit(
        1,
        fixture.command(const JobLinePatch(notes: SetField('B'))),
      );
      expect(
        (await fixture.commands(0).applyIncoming(b.operationBytes)).status,
        'conflict',
      );
      expect(
        (await fixture.commands(1).applyIncoming(a.operationBytes)).status,
        'conflict',
      );
      final ca = await fixture.databases[0]
          .select(fixture.databases[0].jobLineConflicts)
          .getSingle();
      final cb = await fixture.databases[1]
          .select(fixture.databases[1].jobLineConflicts)
          .getSingle();
      expect(ca.conflictId, cb.conflictId);
      expect(ca.alternativesBytes, cb.alternativesBytes);
      expect((await fixture.row(0)).notes, 'Old note');
      expect((await fixture.row(1)).notes, 'Old note');
      expect(
        await fixture.databases[0]
            .select(fixture.databases[0].jobLineOperations)
            .get(),
        hasLength(2),
      );
    });
    test('two deletes and one edit retain a single complete lifecycle candidate set', () async {
      final a = await fixture.commit(0, fixture.command(const DeleteJobLine()));
      final b = await fixture.commit(1, fixture.command(const DeleteJobLine()));
      // Build a third signed concurrent edit before either delete reaches it.
      final third = await AtomicFixture.create();
      try {
        // The test reuses this fixture's original device key and signed facts,
        // but restores only the disposable pre-delete business row in store 1.
        final original = await third.row(0);
        await fixture.databases[1]
            .delete(fixture.databases[1].jobLineBaselines)
            .go();
        await fixture.databases[1]
            .delete(fixture.databases[1].jobLineOperations)
            .go();
        await fixture.databases[1]
            .delete(fixture.databases[1].jobLineReceipts)
            .go();
        await fixture.databases[1]
            .delete(fixture.databases[1].jobLineAudits)
            .go();
        await fixture.databases[1]
            .delete(fixture.databases[1].jobLineOutgoing)
            .go();
        await fixture.databases[1]
            .update(fixture.databases[1].jobLines)
            .replace(original);
        final edit = await fixture.commit(
          1,
          fixture.command(const JobLinePatch(notes: SetField('Concurrent'))),
        );
        await fixture.commands(0).applyIncoming(b.operationBytes);
        await fixture.commands(0).applyIncoming(edit.operationBytes);
        await fixture.commands(1).applyIncoming(a.operationBytes);
        await fixture.commands(1).applyIncoming(b.operationBytes);
        final ca = await fixture.databases[0]
            .select(fixture.databases[0].jobLineConflicts)
            .getSingle();
        final candidates =
            (jsonDecode(ca.alternativesBytes) as Map)['candidates'] as List;
        expect(candidates.toSet(), {
          operationKey(a),
          operationKey(b),
          operationKey(edit),
        });
        final cb = await (fixture.databases[1].select(
          fixture.databases[1].jobLineConflicts,
        )..where((t) => t.conflictId.equals(ca.conflictId))).getSingle();
        expect(ca.alternativesBytes, cb.alternativesBytes);
      } finally {
        await third.dispose();
      }
    });
    test(
      'common-base frontier includes every shared maximal ancestor',
      () async {
        final a = await fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('A'))),
        );
        final b = await fixture.commit(
          1,
          fixture.command(const JobLinePatch(notes: SetField('B'))),
        );
        await fixture.commands(0).applyIncoming(b.operationBytes);
        await fixture.commands(1).applyIncoming(a.operationBytes);
        final parents = [operationKey(a), operationKey(b)]..sort();
        final r1 = await fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(notes: SetField('R1')),
            parents: parents,
          ),
        );
        final r2 = await fixture.commit(
          1,
          fixture.command(
            const JobLinePatch(notes: SetField('R2')),
            parents: parents,
          ),
        );
        await fixture.commands(0).applyIncoming(r2.operationBytes);
        await fixture.commands(1).applyIncoming(r1.operationBytes);
        final all = await fixture.databases[0]
            .select(fixture.databases[0].jobLineConflicts)
            .get();
        final issue = all.singleWhere(
          (c) =>
              ((jsonDecode(c.alternativesBytes) as Map)['candidates'] as List)
                  .contains(operationKey(r1)),
        );
        expect(
          (jsonDecode(issue.alternativesBytes) as Map)['frontier'],
          parents,
        );
        expect(
          await fixture.databases[1]
              .select(fixture.databases[1].jobLineConflicts)
              .get(),
          hasLength(2),
        );
      },
    );
    test(
      'second signed company cannot rebind a globally managed legacy line',
      () async {
        await fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('First company'))),
        );
        const nextCompany = '20000000-0000-4000-8000-000000000001';
        fixture.facts['company'] = nextCompany;
        (fixture.facts['entities'] as List).first['baseline'] =
            jobLineLegacyBaselineCommitment(
              companyId: nextCompany,
              shopId: shop,
              row: await fixture.row(0),
            );
        await fixture.publishFacts();
        await expectLater(
          fixture.commit(
            0,
            fixture.command(
              const JobLinePatch(notes: SetField('Rebound')),
              companyId: nextCompany,
            ),
          ),
          throwsA(isA<JobLineRefusal>()),
        );
        expect((await fixture.row(0)).notes, 'First company');
        expect(await fixture.counts(0), [1, 1, 1, 1, 1, 0]);
      },
    );
    test(
      'operation signer cannot mint login assertions or substitute an author',
      () async {
        final command = fixture.command(
          const JobLinePatch(notes: SetField('Allowed')),
        );
        final session = await fixture.session(0, command);
        final proof =
            jsonDecode(utf8.decode(await fixture.assertion(0, command))) as Map;
        await expectLater(
          fixture.installations[0].signCompanyOperation(
            fixture.databases[0],
            session,
            Uint8List.fromList(utf8.encode(canonical(proof['body']))),
          ),
          throwsA(isA<JobLineRefusal>()),
        );
        final receipt = await fixture.commit(0, command);
        final body =
            (jsonDecode(utf8.decode(receipt.operationBytes)) as Map)['body']
                as Map;
        body['user'] = secondUser;
        await expectLater(
          fixture.installations[0].signCompanyOperation(
            fixture.databases[0],
            session,
            Uint8List.fromList(utf8.encode(canonical(body))),
          ),
          throwsA(isA<JobLineRefusal>()),
        );
      },
    );
    test(
      'identity and custom notes are independent complete editing units',
      () async {
        final a = await fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(
              identity: CatalogJobLine(part, brandVersionId: version),
            ),
          ),
        );
        final b = await fixture.commit(
          1,
          fixture.command(
            const JobLinePatch(customNotes: SetField('Kept custom note')),
          ),
        );
        await fixture.commands(0).applyIncoming(b.operationBytes);
        await fixture.commands(1).applyIncoming(a.operationBytes);
        expect((await fixture.row(0)).partId, part);
        expect((await fixture.row(0)).customName, isNull);
        expect((await fixture.row(0)).customNotes, 'Kept custom note');
        expect(
          await fixture.databases[0]
              .select(fixture.databases[0].jobLineConflicts)
              .get(),
          isEmpty,
        );
      },
    );
    test(
      'edit/delete retains both alternatives and forbids ordinary resurrection',
      () async {
        final a = await fixture.commit(
          0,
          fixture.command(const DeleteJobLine()),
        );
        final b = await fixture.commit(
          1,
          fixture.command(const JobLinePatch(notes: SetField('Concurrent'))),
        );
        await fixture.commands(0).applyIncoming(b.operationBytes);
        await fixture.commands(1).applyIncoming(a.operationBytes);
        for (var i = 0; i < 2; i++) {
          expect((await fixture.row(i)).deletedAt, isNotNull);
          expect(
            (await fixture.databases[i]
                    .select(fixture.databases[i].jobLineConflicts)
                    .getSingle())
                .unit,
            'lifecycle',
          );
        }
        await expectLater(
          fixture.commit(
            0,
            fixture.command(
              const JobLinePatch(notes: SetField('Restore')),
              parents: [operationKey(a), operationKey(b)],
            ),
          ),
          throwsA(isA<JobLineRefusal>()),
        );
      },
    );
    test(
      'missing parent defers durably then resumes with linked semantic receipt',
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
        final deferred = await fixture
            .commands(1)
            .applyIncoming(child.operationBytes);
        expect(deferred.status, 'deferred');
        expect((await fixture.row(1)).notes, 'Old note');
        await fixture.reopen(1);
        await fixture.commands(1).applyIncoming(parent.operationBytes);
        final origin =
            (jsonDecode(utf8.decode(child.operationBytes)) as Map)['body']
                as Map;
        final resumed = await fixture
            .commands(1)
            .retryDeferred(
              companyId: company,
              originGeneration: origin['generation'] as String,
              requestId: origin['request'] as String,
            );
        expect(resumed.status, 'applied');
        expect((await fixture.row(1)).notes, 'Child');
        expect(
          (await fixture.commands(1).applyIncoming(child.operationBytes)).bytes,
          deferred.bytes,
        );
        expect(resumed.key, isNot(deferred.key));
      },
    );
    test('precommit failure rolls back every database effect and clears only proven no-commit', () async {
      final command = fixture.command(
        const JobLinePatch(notes: SetField('Never committed')),
      );
      final service = fixture.commands(
        0,
        beforeCommit: () async {
          throw StateError('fixture before commit');
        },
      );
      await expectLater(
        service.patchJobLine(await fixture.session(0, command), command),
        throwsStateError,
      );
      expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
      expect((await fixture.row(0)).notes, 'Old note');
      expect(fixture.installations[0].readiness, InstallationReadiness.ready);
      final receipt = await fixture.commit(0, command);
      expect(receipt.status, 'applied');
    });
    test(
      'commit then lost response is reconciled after reopen and exact retry',
      () async {
        final command = fixture.command(
          const JobLinePatch(notes: SetField('Committed')),
        );
        final service = fixture.commands(
          0,
          afterCommit: () async {
            throw StateError('fixture lost response');
          },
        );
        await expectLater(
          service.patchJobLine(await fixture.session(0, command), command),
          throwsStateError,
        );
        expect(await fixture.counts(0), [1, 1, 1, 1, 1, 0]);
        final saved = await fixture.databases[0]
            .select(fixture.databases[0].jobLineReceipts)
            .getSingle();
        await expectLater(
          fixture.installations[0].prepareReset(),
          throwsStateError,
        );
        await fixture.reopen(0);
        expect(fixture.installations[0].readiness, InstallationReadiness.ready);
        expect((await fixture.commit(0, command)).bytes, saved.receiptBytes);
      },
    );
    test(
      'clear failure returns durable result and restart does not duplicate',
      () async {
        final command = fixture.command(
          const JobLinePatch(notes: SetField('Committed')),
        );
        fixture.secureStores[0].failClear = true;
        final receipt = await fixture.commit(0, command);
        expect(receipt.status, 'applied');
        expect(
          fixture.installations[0].readiness,
          InstallationReadiness.needsRecovery,
        );
        fixture.secureStores[0].failClear = false;
        await fixture.reopen(0);
        expect((await fixture.commit(0, command)).bytes, receipt.bytes);
        expect(await fixture.counts(0), [1, 1, 1, 1, 1, 0]);
      },
    );
    test('lost native CAS response and admission failure cannot leak SQLite effects', () async {
      for (final loseReply in [false, true]) {
        final command = fixture.command(
          const JobLinePatch(notes: SetField('Failed CAS')),
        );
        if (loseReply) {
          fixture.secureStores[0].loseWriteReply = true;
        } else {
          fixture.secureStores[0].failBeforeWrite = true;
        }
        await expectLater(fixture.commit(0, command), throwsStateError);
        expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
        expect((await fixture.row(0)).notes, 'Old note');
      }
    });
    test(
      'outer transaction refuses before protected or business admission',
      () async {
        final command = fixture.command(
          const JobLinePatch(notes: SetField('Outer rollback')),
        );
        final session = await fixture.session(0, command);
        final prior = fixture
            .secureStores[0]
            .states[fixture.installations[0].namespace]!
            .revision;
        await expectLater(
          fixture.databases[0].transaction(() async {
            await expectLater(
              fixture.commands(0).patchJobLine(session, command),
              throwsA(isA<JobLineRefusal>()),
            );
            throw StateError('fixture outer transaction rollback');
          }),
          throwsStateError,
        );
        expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
        expect(
          fixture
              .secureStores[0]
              .states[fixture.installations[0].namespace]!
              .revision,
          prior,
        );
      },
    );
    test('copied database cannot use the same protected store to reconcile pending command', () async {
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
      await fixture.databases[0].close();
      final copy = File('${fixture.directory.path}/wrong.db');
      await File('${fixture.directory.path}/0.db').copy(copy.path);
      final wrong = AppDatabase.forTesting(NativeDatabase(copy));
      try {
        final security = InstallationSecurity(
          store: fixture.secureStores[0],
          namespace: 'synthetic.atomic-0',
        );
        await security.start(wrong);
        expect(security.readiness, InstallationReadiness.needsRecovery);
      } finally {
        await wrong.close();
      }
      await fixture.reopen(0);
      expect(fixture.installations[0].readiness, InstallationReadiness.ready);
    });
    test(
      'partial or corrupt committed recovery evidence holds protected intent',
      () async {
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
        await fixture.databases[0]
            .delete(fixture.databases[0].jobLineAudits)
            .go();
        await fixture.reopen(0);
        expect(
          fixture.installations[0].readiness,
          InstallationReadiness.needsRecovery,
        );
      },
    );
    test('legacy scalar, deletion and split writers refuse managed lines without side effects', () async {
      await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('Managed'))),
      );
      final db = fixture.databases[0];
      final before = canonical((await fixture.row(0)).toJson());
      for (final action in <Future<void> Function()>[
        () => db.jobsDao.setShopPull(line, 99),
        () => db.jobsDao.softDeleteJobLine(line),
        () => db.jobsDao.replaceOrderSplits(
          lineId: line,
          splits: [],
          deviceId: legacyDevice,
        ),
        () async {
          await db.jobsDao.insertOrderSplit(
            id: const Uuid().v4(),
            jobLineId: line,
            supplierId: const Uuid().v4(),
            qty: 2,
            deviceId: legacyDevice,
          );
        },
        () => db.jobsDao.updateJobLine(
          id: line,
          partId: null,
          brandVersionId: null,
          customName: 'Legacy overwrite',
          neededQty: 5,
          shopPullQty: 1,
        ),
      ]) {
        await expectLater(action(), throwsStateError);
      }
      expect(canonical((await fixture.row(0)).toJson()), before);
      expect(await db.select(db.orderSplits).get(), isEmpty);
    });
    test('unsupported operation, missing/deleted references and invalid quantities refuse', () async {
      final receipt = await fixture.commit(
        0,
        fixture.command(const JobLinePatch(notes: SetField('First'))),
      );
      final op = jsonDecode(utf8.decode(receipt.operationBytes)) as Map;
      (op['body'] as Map)['v'] = 2;
      await expectLater(
        fixture
            .commands(1)
            .applyIncoming(Uint8List.fromList(utf8.encode(canonical(op)))),
        throwsA(isA<JobLineRefusal>()),
      );
      await expectLater(
        fixture.commit(
          1,
          fixture.command(
            JobLinePatch(identity: CatalogJobLine(const Uuid().v4())),
          ),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      await (fixture.databases[1].update(fixture.databases[1].parts)
            ..where((t) => t.id.equals(part)))
          .write(PartsCompanion(deletedAt: Value(DateTime.utc(2026))));
      await expectLater(
        fixture.commit(
          1,
          fixture.command(const JobLinePatch(identity: CatalogJobLine(part))),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(
        () => fixture.command(
          const JobLinePatch(
            quantities: JobLineQuantities(
              needed: double.nan,
              shopPull: 0,
              unit: 'ea',
            ),
          ),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(
        () => fixture.command(
          const JobLinePatch(
            quantities: JobLineQuantities(needed: 1, shopPull: -1, unit: 'ea'),
          ),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await fixture.counts(1), [0, 0, 0, 0, 0, 0]);
    });
    test('deleted parent and mismatched variance parent are refused', () async {
      final db = fixture.databases[0];
      await (db.update(db.brandVersions)..where((t) => t.id.equals(version)))
          .write(const BrandVersionsCompanion(partId: Value(job)));
      await expectLater(
        fixture.commit(
          0,
          fixture.command(
            const JobLinePatch(
              identity: CatalogJobLine(part, brandVersionId: version),
            ),
          ),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      await (db.update(db.jobs)..where((t) => t.id.equals(job))).write(
        JobsCompanion(deletedAt: Value(DateTime.utc(2026))),
      );
      await expectLater(
        fixture.commit(
          0,
          fixture.command(const JobLinePatch(notes: SetField('Denied'))),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await fixture.counts(0), [0, 0, 0, 0, 0, 0]);
      expect(
        () => fixture.command(
          const JobLinePatch(notes: SetField('Bad parent')),
          parents: ['invalid-causal-id'],
        ),
        throwsA(isA<JobLineRefusal>()),
      );
    });
    test('backup export, incoming/outgoing replacement and low-level reset refuse company history', () async {
      final legacy = await Directory.systemTemp.createTemp('wp-legacy-copy-');
      final legacyFile = File('${legacy.path}/legacy.db');
      final db = AppDatabase.forTesting(NativeDatabase(legacyFile));
      await db.settingsDao.setSetting('fixture', 'Legacy');
      await db.close();
      final legacyPayload = BackupPayload(
        createdAt: DateTime.utc(2026),
        sourceDeviceId: legacyDevice,
        sqliteBytes: await legacyFile.readAsBytes(),
        photos: {},
      );
      await fixture.databases[0].close();
      final bytes = await File('${fixture.directory.path}/0.db').readAsBytes();
      final store = BackupStore(supportDir: fixture.directory);
      await expectLater(
        store.collect(
          sourceDeviceId: legacyDevice,
          createdAt: DateTime.utc(2026),
          sqliteBytes: bytes,
        ),
        throwsA(isA<BackupFormatException>()),
      );
      final companyPayload = BackupPayload(
        createdAt: DateTime.utc(2026),
        sourceDeviceId: legacyDevice,
        sqliteBytes: bytes,
        photos: {},
      );
      await expectLater(
        store.writePayload(companyPayload),
        throwsA(isA<BackupFormatException>()),
      );
      await expectLater(
        store.replaceWithPayload(payload: companyPayload),
        throwsA(isA<BackupFormatException>()),
      );
      final liveName = File('${fixture.directory.path}/wired_parts.sqlite');
      await File('${fixture.directory.path}/0.db').copy(liveName.path);
      await expectLater(
        store.replaceWithPayload(payload: legacyPayload),
        throwsA(isA<BackupFormatException>()),
      );
      await expectLater(
        LocalDataReset(
          supportDir: fixture.directory,
          documentsDir: legacy,
        ).wipeFiles(),
        throwsA(isA<BackupFormatException>()),
      );
      expect(await liveName.readAsBytes(), bytes);
      await fixture.reopen(0);
      await legacy.delete(recursive: true);
    });
  });

  test('populated schema2 upgrade preserves IDs/relationships and newer schema cannot retag', () async {
    final fixture = await AtomicFixture.create();
    try {
      await fixture.databases[1].close();
      final file = File('${fixture.directory.path}/1.db');
      var raw = raw_sqlite.sqlite3.open(file.path);
      for (final table in [
        'company_authority_facts',
        'job_line_baselines',
        'job_line_operations',
        'job_line_receipts',
        'job_line_audits',
        'job_line_outgoing',
        'job_line_conflicts',
      ]) {
        raw.execute('DROP TABLE $table');
      }
      raw.execute('PRAGMA user_version = 2');
      raw.dispose();
      final before = businessRows(file);
      fixture.databases[1] = AppDatabase.forTesting(NativeDatabase(file));
      expect((await fixture.row(1)).id, line);
      expect((await fixture.row(1)).jobId, job);
      expect((await fixture.row(1)).revision, 1);
      expect(await fixture.counts(1), [0, 0, 0, 0, 0, 0]);
      await fixture.databases[1].close();
      expect(businessRows(file), before);
      raw = raw_sqlite.sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 4');
      raw.dispose();
      fixture.databases[1] = AppDatabase.forTesting(NativeDatabase(file));
      await expectLater(
        fixture.databases[1].select(fixture.databases[1].jobLines).get(),
        throwsStateError,
      );
      await fixture.databases[1].close();
      raw = raw_sqlite.sqlite3.open(file.path);
      expect(raw.select('PRAGMA user_version').single.values.first, 4);
      expect(raw.select('SELECT id,job_id FROM job_lines').single['id'], line);
      raw.dispose();
    } finally {
      await fixture.dispose();
    }
  });
  test('mid-DDL schema2 upgrade failure leaves every legacy row and version untouched', () async {
    final fixture = await AtomicFixture.create();
    try {
      await fixture.databases[1].close();
      final file = fixture.files[1];
      final raw = raw_sqlite.sqlite3.open(file.path);
      const history = [
        'company_authority_facts',
        'job_line_baselines',
        'job_line_operations',
        'job_line_receipts',
        'job_line_audits',
        'job_line_outgoing',
        'job_line_conflicts',
      ];
      for (final table in history) {
        raw.execute('DROP TABLE $table');
      }
      raw.execute('PRAGMA user_version = 2');
      // SQLite's shared table/index namespace makes the fourth additive CREATE
      // fail after the first three DDL statements, using the actual engine.
      raw.execute('CREATE INDEX job_line_receipts ON jobs(name)');
      raw.dispose();
      final before = businessRows(file);
      fixture.databases[1] = AppDatabase.forTesting(NativeDatabase(file));
      await expectLater(
        fixture.databases[1].select(fixture.databases[1].jobLines).get(),
        throwsA(isA<raw_sqlite.SqliteException>()),
      );
      await fixture.databases[1].close();
      final after = raw_sqlite.sqlite3.open(file.path);
      expect(after.select('PRAGMA user_version').single.values.first, 2);
      expect(
        after
            .select("SELECT name FROM sqlite_master WHERE type = 'table'")
            .map((r) => r['name'])
            .where(history.contains),
        isEmpty,
      );
      expect(
        after.select(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'job_line_receipts'",
        ),
        hasLength(1),
      );
      after.dispose();
      expect(businessRows(file), before);
    } finally {
      await fixture.dispose();
    }
  });
}
