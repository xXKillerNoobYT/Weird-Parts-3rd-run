import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late Directory directory;
  late File file;
  late AppDatabase db;
  late String device, job, category, style, variant, supplier;
  late PinService pin;
  late EditDrafts edits;
  late JobsRepository jobs;

  void bind() {
    pin = PinService(db.settingsDao);
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
    jobs = JobsRepository(db, device);
  }

  Future<void> reopen() async {
    await edits.quiesce(StorageChange.exit);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
  }

  JobLineInput input({String needed = '09.50', bool custom = true}) =>
      JobLineInput(
        useCustom: custom,
        partId: null,
        brandVersionId: null,
        customNameText: '  Parent raw name  ',
        neededText: needed,
        pullText: '02.0',
        customNotes: 'raw custom notes',
        uom: 'box',
        notes: 'raw notes',
        splits: [SplitInput(supplierId: supplier, quantityText: '03.00')],
      );

  NewPartInput details({
    String? categoryId,
    String name = '  Nested raw name  ',
  }) => NewPartInput(
    nameText: name,
    categoryId: categoryId ?? category,
    styleId: style,
    typeId: variant,
  );

  Future<JobLineEditSession> parent({String? id}) async {
    final opening = await edits.openJobLine(job, lineId: id);
    final session = (opening as FreshEdit<JobLineEditSession>).session;
    session.replace(input());
    await session.flush();
    return session;
  }

  Future<JobLinePromotion> pending(JobLineEditSession parent) async {
    final child = await parent.openPromotion();
    child.replace(details());
    await child.flush();
    return child;
  }

  Future<String> inputKey() async =>
      (await db
              .customSelect(
                "SELECT key FROM app_settings WHERE key LIKE 'local_edit_v1/job-line%/input'",
              )
              .get())
          .single
          .read<String>('key');

  Future<Map<String, dynamic>> stored(String key) async =>
      jsonDecode((await db.settingsDao.getSetting(key))!)
          as Map<String, dynamic>;

  Future<Map<String, Object?>> business() async => {
    'parts': await db.select(db.parts).get(),
    'lines': await db.select(db.jobLines).get(),
    'splits': await db.select(db.orderSplits).get(),
  };

  Future<List<Map<String, Object?>>> drafts() async =>
      (await db
              .customSelect(
                "SELECT key,value FROM app_settings WHERE key LIKE 'local_edit_v1/%' ORDER BY key",
              )
              .get())
          .map((row) => row.data)
          .toList();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('promotion-details-');
    file = File('${directory.path}/synthetic.sqlite');
    db = AppDatabase.forTesting(NativeDatabase(file));
    device = await db.settingsDao.ensureDeviceId();
    bind();
    final maintenance = MaintenanceRepository(db, pin, device);
    category = await maintenance.createCategory('Category');
    style = await maintenance.createStyle(categoryId: category, name: 'Type');
    variant = await maintenance.createType(styleId: style, name: 'Variant');
    supplier = await maintenance.createSupplier('Supplier');
    job = await jobs.createJob('Promotion job');
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  for (final existing in [false, true]) {
    test(
      '${existing ? 'existing' : 'fresh'} pending recovery and cold completion preserve exact raw continuation',
      () async {
        final original = existing
            ? await jobs.addLine(
                jobId: job,
                customName: 'Existing',
                neededQty: 4,
              )
            : null;
        final owner = await parent(id: original);
        await pending(owner);
        final key = await inputKey();
        final raw = await stored(key);
        final reservedLine = (raw['target'] as Map)['reserved'];
        final reservedPart =
            ((raw['input'] as Map)['promotion'] as Map)['part'];
        await reopen();
        final recovery = await edits.openJobLine(job, lineId: original);
        expect(recovery, isA<RecoverableEdit<JobLineEditSession>>());
        final restored = await (recovery as RecoverableEdit<JobLineEditSession>)
            .resume();
        expect(restored.initial.neededText, '09.50');
        expect(restored.initial.pullText, '02.0');
        expect(restored.initial.splits.single.quantityText, '03.00');
        final child = await restored.openPromotion();
        expect(child.initial.nameText, '  Nested raw name  ');
        expect(
          (
            child.initial.categoryId,
            child.initial.styleId,
            child.initial.typeId,
          ),
          (category, style, variant),
        );
        expect(await db.select(db.parts).get(), isEmpty);
        expect((await db.select(db.jobLines).get()).length, existing ? 1 : 0);
        final first = await child.promote();
        expect(first.partId, reservedPart);
        expect(first.lineId, reservedLine);
        expect((await child.promote()).lineId, first.lineId);
        expect((await db.select(db.parts).get()).length, 1);
        expect((await db.select(db.jobLines).get()).length, 1);
        await reopen();
        final before = await drafts();
        final completion = await edits.openJobLine(job, lineId: original);
        expect(completion, isA<JobLinePromoted>());
        final receipt = completion as JobLinePromoted;
        expect(receipt.name, 'Nested raw name');
        expect(await drafts(), before);
        final continuation = await receipt.acknowledgeAndContinue();
        expect(continuation.initial.neededText, '09.50');
        expect(continuation.initial.pullText, '02.0');
        expect(continuation.initial.splits.single.quantityText, '03.00');
        expect(continuation.initial.customNotes, 'raw custom notes');
        expect(continuation.initial.uom, 'box');
        expect(continuation.initial.notes, 'raw notes');
        expect(continuation.initial.partId, reservedPart);
        expect(continuation.initial.useCustom, false);
        expect(await receipt.acknowledgeAndContinue(), same(continuation));
        await reopen();
        final recovered = await edits.openJobLine(job, lineId: receipt.lineId);
        expect(recovered, isA<RecoverableEdit<JobLineEditSession>>());
        final resumed = await (recovered as RecoverableEdit<JobLineEditSession>)
            .resume();
        expect(resumed.initial.neededText, '09.50');
        expect((await db.select(db.parts).get()).length, 1);
        expect((await db.select(db.jobLines).get()).length, 1);
      },
    );

    for (final phase in ['part', 'line', 'split', 'retirement', 'receipt']) {
      test(
        '${existing ? 'existing' : 'fresh'} $phase transaction failure rolls back and retries once',
        () async {
          final id = existing
              ? await jobs.addLine(
                  jobId: job,
                  customName: 'Existing',
                  neededQty: 4,
                )
              : null;
          final owner = await parent(id: id);
          final child = await pending(owner);
          final beforeBusiness = await business();
          final beforeDrafts = await drafts();
          final trigger = switch (phase) {
            'part' => 'BEFORE INSERT ON parts',
            'line' => 'BEFORE ${existing ? 'UPDATE' : 'INSERT'} ON job_lines',
            'split' => 'BEFORE INSERT ON order_splits',
            'retirement' => "BEFORE DELETE ON app_settings WHEN OLD.key LIKE 'local_edit_v1/job-line%/input'",
            _ => "BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/job-line%/control' AND instr(NEW.value, 'line-promote-v2/') > 0",
          };
          await db.customStatement(
            "CREATE TRIGGER reject_promotion $trigger BEGIN SELECT RAISE(ABORT, 'synthetic $phase failure'); END",
          );
          await expectLater(child.promote(), throwsA(anything));
          expect(await business(), beforeBusiness);
          expect(await drafts(), beforeDrafts);
          expect(child.initial.nameText, '  Nested raw name  ');
          await db.customStatement('DROP TRIGGER reject_promotion');
          final receipt = await child.promote();
          expect((await db.select(db.parts).get()).length, 1);
          expect(
            (await db.select(db.jobLines).get()).single.id,
            receipt.lineId,
          );
        },
      );
    }

    test(
      '${existing ? 'existing' : 'fresh'} acknowledgment failure retains receipt and retries atomically',
      () async {
        final id = existing
            ? await jobs.addLine(
                jobId: job,
                customName: 'Existing',
                neededQty: 4,
              )
            : null;
        final child = await pending(await parent(id: id));
        final receipt = await child.promote();
        final before = await drafts();
        await db.customStatement(
          "CREATE TRIGGER reject_continuation BEFORE INSERT ON app_settings WHEN NEW.key LIKE 'local_edit_v1/job-line/%/input' BEGIN SELECT RAISE(ABORT, 'continuation failure'); END",
        );
        await expectLater(receipt.acknowledgeAndContinue(), throwsA(anything));
        expect(await drafts(), before);
        await db.customStatement('DROP TRIGGER reject_continuation');
        expect(
          (await receipt.acknowledgeAndContinue()).initial.neededText,
          '09.50',
        );
      },
    );
  }

  test(
    'Cancel changes only nested input and a failed Cancel remains retryable',
    () async {
      final owner = await parent();
      final child = await pending(owner);
      final other =
          (await edits.openNewJob() as FreshEdit<NewJobEditSession>).session;
      other.replace(const NewJobInput(nameText: 'Unrelated draft'));
      await other.flush();
      final savedTaxonomy = await MaintenanceRepository(
        db,
        pin,
        device,
      ).createCategory('Independent');
      final beforeBusiness = await business();
      final before = await drafts();
      await db.customStatement(
        "CREATE TRIGGER reject_cancel BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/job-line%/input' BEGIN SELECT RAISE(ABORT, 'Cancel failure'); END",
      );
      await expectLater(child.cancel(), throwsA(anything));
      expect(child.initial.nameText, '  Nested raw name  ');
      expect(await drafts(), before);
      await db.customStatement('DROP TRIGGER reject_cancel');
      await child.cancel();
      expect(owner.initial.neededText, '09.50');
      expect(owner.initial.splits.single.quantityText, '03.00');
      expect(await business(), beforeBusiness);
      expect(
        (await db.taxonomyDao.listCategories()).any(
          (row) => row.id == savedTaxonomy,
        ),
        true,
      );
      expect(other.initial.nameText, 'Unrelated draft');
      final next = await owner.openPromotion();
      expect(next.initial.nameText, 'Parent raw name');
      await expectLater(child.cancel(), throwsStateError);
      expect(next.initial.nameText, 'Parent raw name');
    },
  );

  for (final action in ['flush', 'Cancel', 'promote', 'Discard']) {
    test(
      'same-token externally replaced input refuses $action before any write',
      () async {
        final owner = await parent();
        final child = await pending(owner);
        final key = await inputKey();
        final replacement = await stored(key);
        (((replacement['input'] as Map)['promotion'] as Map)['details']
                as Map)['name'] =
            'External replacement';
        final replaced = jsonEncode(replacement);
        await db.settingsDao.setSetting(key, replaced);
        final beforeDrafts = await drafts();
        final before = await business();
        if (action == 'flush') child.replace(details(name: 'Local newer name'));
        final beforeChild = jsonEncode([
          child.initial.nameText,
          child.initial.categoryId,
          child.initial.styleId,
          child.initial.typeId,
        ]);
        await expectLater(switch (action) {
          'flush' => child.flush(),
          'Cancel' => child.cancel(),
          'Discard' => owner.leave(LeaveIntent.discard),
          _ => child.promote(),
        }, throwsStateError);
        expect(await db.settingsDao.getSetting(key), replaced);
        expect(await drafts(), beforeDrafts);
        expect(await business(), before);
        expect(
          jsonEncode([
            child.initial.nameText,
            child.initial.categoryId,
            child.initial.styleId,
            child.initial.typeId,
          ]),
          beforeChild,
        );
      },
    );
  }

  for (final action in ['flush', 'Cancel', 'promote', 'Discard']) {
    test(
      'malformed same-token editing control refuses $action without writes',
      () async {
        final owner = await parent();
        final child = await pending(owner);
        final key = await inputKey();
        final controlKey = key.replaceFirst('/input', '/control');
        final control = await stored(controlKey);
        control['unexpected'] = true;
        final replaced = jsonEncode(control);
        await db.settingsDao.setSetting(controlKey, replaced);
        final beforeDrafts = await drafts();
        final beforeBusiness = await business();
        if (action == 'flush') child.replace(details(name: 'Local newer name'));
        final beforeChild = jsonEncode([
          child.initial.nameText,
          child.initial.categoryId,
          child.initial.styleId,
          child.initial.typeId,
        ]);
        await expectLater(switch (action) {
          'flush' => child.flush(),
          'Cancel' => child.cancel(),
          'Discard' => owner.leave(LeaveIntent.discard),
          _ => child.promote(),
        }, throwsA(isA<FormatException>()));
        expect(await db.settingsDao.getSetting(controlKey), replaced);
        expect(await drafts(), beforeDrafts);
        expect(await business(), beforeBusiness);
        expect(
          jsonEncode([
            child.initial.nameText,
            child.initial.categoryId,
            child.initial.styleId,
            child.initial.typeId,
          ]),
          beforeChild,
        );
        expect(
          child.initial.nameText,
          action == 'flush' ? 'Local newer name' : '  Nested raw name  ',
        );
      },
    );
  }

  for (final priorSave in [false, true]) {
    test(
      '${priorSave ? 'prior line-save' : 'empty'} control replacement blocks first promotion admission with no input',
      () async {
        final line = await jobs.addLine(
          jobId: job,
          customName: 'Original line',
          neededQty: 4,
        );
        final key =
            '${editDraftPrefix}job-line/${Uri.encodeComponent(job)}/${Uri.encodeComponent(line)}/input';
        final controlKey = key.replaceFirst('/input', '/control');
        if (priorSave) await (await parent(id: line)).save();
        final admittedControl = await db.settingsDao.getSetting(controlKey);
        expect(admittedControl, priorSave ? isNotNull : isNull);
        final owner = (await edits.openJobLine(
          job,
          lineId: line,
        ) as FreshEdit<JobLineEditSession>).session;
        expect(await db.settingsDao.getSetting(key), isNull);
        expect(await db.settingsDao.getSetting(controlKey), admittedControl);
        const replaced = '{"phase":"editing","token":"replacement"}';
        await db.settingsDao.setSetting(controlKey, replaced);
        final beforeDrafts = await drafts();
        final beforeBusiness = await business();
        await expectLater(owner.openPromotion(), throwsStateError);
        expect(await db.settingsDao.getSetting(key), isNull);
        expect(await db.settingsDao.getSetting(controlKey), replaced);
        expect(await drafts(), beforeDrafts);
        expect(await business(), beforeBusiness);
      },
    );
  }

  test(
    'valid prior ordinary Save permits promotion of the original line once',
    () async {
      final original = await jobs.addLine(
        jobId: job,
        customName: 'Original line',
        neededQty: 4,
      );
      final ordinary = await parent(id: original);
      final key = await inputKey();
      final controlKey = key.replaceFirst('/input', '/control');
      expect(await ordinary.save(), original);
      final savedControl = await db.settingsDao.getSetting(controlKey);
      expect((await stored(controlKey))['command'], 'line-save');
      expect(await db.settingsDao.getSetting(key), isNull);
      final opening = await edits.openJobLine(job, lineId: original);
      expect(opening, isA<FreshEdit<JobLineEditSession>>());
      expect(await db.settingsDao.getSetting(controlKey), savedControl);
      final child = await pending(
        (opening as FreshEdit<JobLineEditSession>).session,
      );
      final receipt = await child.promote();
      expect(receipt.lineId, original);
      expect((await child.promote()).lineId, original);
      expect((await db.select(db.parts).get()).single.id, receipt.partId);
      final line = (await db.select(db.jobLines).get()).single;
      expect(line.id, original);
      expect(line.partId, receipt.partId);
    },
  );

  test(
    'control replaced after promotion persistence refuses business settlement',
    () async {
      final child = await pending(await parent());
      final key = await inputKey();
      final controlKey = key.replaceFirst('/input', '/control');
      final originalControl = (await db.settingsDao.getSetting(controlKey))!;
      final control = await stored(controlKey);
      control['unexpected'] = true;
      final replaced = jsonEncode(control);
      const counterKey = 'synthetic_promotion_persist_count';
      await db.settingsDao.setSetting(counterKey, '0');
      final beforeInput = await db.settingsDao.getSetting(key);
      final beforeBusiness = await business();
      await db.customStatement(
        'CREATE TRIGGER replace_promotion_control AFTER UPDATE ON app_settings '
        "WHEN NEW.key = '${key.replaceAll("'", "''")}' "
        'BEGIN UPDATE app_settings '
        "SET value = '${replaced.replaceAll("'", "''")}' "
        "WHERE key = '${controlKey.replaceAll("'", "''")}' "
        "AND (SELECT value FROM app_settings WHERE key = '$counterKey') = '1'; "
        'UPDATE app_settings SET value = CAST(value AS INTEGER) + 1 '
        "WHERE key = '$counterKey'; END",
      );
      await expectLater(child.promote(), throwsA(isA<FormatException>()));
      expect(await db.settingsDao.getSetting(counterKey), '2');
      expect(await db.settingsDao.getSetting(key), beforeInput);
      expect(await db.settingsDao.getSetting(controlKey), replaced);
      expect(await business(), beforeBusiness);
      expect(child.initial.nameText, '  Nested raw name  ');
      await db.customStatement('DROP TRIGGER replace_promotion_control');
      await db.settingsDao.setSetting(controlKey, originalControl);
      final receipt = await child.promote();
      expect((await db.select(db.parts).get()).single.id, receipt.partId);
      expect((await db.select(db.jobLines).get()).single.id, receipt.lineId);
    },
  );

  for (final refusal in [
    'invalid quantity',
    'locked PIN',
    'company marker',
    'base',
    'reparented',
    'deleted',
    'fingerprint',
  ]) {
    test('$refusal retains raw promotion and all business rows', () async {
      final owner = await parent();
      final child = await pending(owner);
      if (refusal == 'invalid quantity') {
        owner.replace(input(needed: '8..4'));
        await owner.flush();
      }
      if (refusal == 'locked PIN') {
        await pin.setPin('2468');
        pin.lock();
      }
      if (refusal == 'company marker') {
        await db.customStatement(
          'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
          ['promotion-refusal', 1, 'blocked', 'synthetic'],
        );
      }
      if (refusal == 'base') {
        await db.customStatement('UPDATE jobs SET name = ? WHERE id = ?', [
          'Changed',
          job,
        ]);
      }
      if (refusal == 'reparented') {
        final other = await MaintenanceRepository(
          db,
          pin,
          device,
        ).createCategory('Other');
        await db.customStatement(
          'UPDATE styles SET category_id = ? WHERE id = ?',
          [other, style],
        );
      }
      if (refusal == 'deleted') {
        await db.customStatement(
          'UPDATE types SET deleted_at = 1 WHERE id = ?',
          [variant],
        );
      }
      if (refusal == 'fingerprint') {
        await db.customStatement(
          'UPDATE categories SET name = ? WHERE id = ?',
          ['Renamed', category],
        );
      }
      final before = await business();
      final beforeDrafts = await drafts();
      await expectLater(child.promote(), throwsA(anything));
      expect(await business(), before);
      expect(await drafts(), beforeDrafts);
      expect(child.initial.nameText, '  Nested raw name  ');
      if (refusal == 'invalid quantity') {
        expect(owner.initial.neededText, '8..4');
      }
    });
  }

  test(
    'stale nested references permit parent recovery, Cancel and ordinary Save',
    () async {
      final owner = await parent();
      await pending(owner);
      await db.customStatement('UPDATE types SET deleted_at = 1 WHERE id = ?', [
        variant,
      ]);
      await reopen();
      final recovery =
          await edits.openJobLine(job) as RecoverableEdit<JobLineEditSession>;
      final restored = await recovery.resume();
      final child = await restored.openPromotion();
      expect(child.initial.typeId, variant);
      await expectLater(child.promote(), throwsStateError);
      await child.cancel();
      final line = await restored.save();
      expect((await jobs.getJobLine(line))!.customName, 'Parent raw name');
    },
  );

  test('switching modes preserves nested input inertly and terminal Save consumes it', () async {
    final owner = await parent();
    final child = await pending(owner);
    owner.replace(input(custom: false));
    await owner.flush();
    await expectLater(owner.openPromotion(), throwsStateError);
    await expectLater(child.promote(), throwsStateError);
    owner.replace(input());
    expect(
      (await owner.openPromotion()).initial.nameText,
      '  Nested raw name  ',
    );
    await owner.save();
    expect(await db.select(db.parts).get(), isEmpty);
    final next = await edits.openJobLine(job);
    expect(next, isA<FreshEdit<JobLineEditSession>>());
  });

  for (final deleted in [false, true]) {
    test(
      '${deleted ? 'tombstoned' : 'live'} reserved Part collision cannot be overwritten',
      () async {
        final child = await pending(await parent());
        final raw = await stored(await inputKey());
        final reserved =
            ((raw['input'] as Map)['promotion'] as Map)['part'] as String;
        await db.partsDao.insertGeneralPart(
          id: reserved,
          name: 'Collision',
          deviceId: device,
        );
        if (deleted) await db.partsDao.softDeletePart(reserved);
        final before = await business();
        await expectLater(child.promote(), throwsStateError);
        expect(await business(), before);
        expect(child.initial.nameText, '  Nested raw name  ');
      },
    );
  }

  test(
    'mutable Part changes do not strand receipt delivery or continuation',
    () async {
      final receipt = await (await pending(await parent())).promote();
      await db.customStatement(
        'UPDATE parts SET name = ?, category_id = NULL, style_id = NULL, type_id = NULL WHERE id = ?',
        ['Later catalog name', receipt.partId],
      );
      await reopen();
      final cold = await edits.openJobLine(job) as JobLinePromoted;
      expect(cold.name, 'Nested raw name');
      final continuation = await cold.acknowledgeAndContinue();
      expect(continuation.initial.partId, receipt.partId);
    },
  );

  for (final drift in ['line', 'splits', 'Part link']) {
    test(
      '$drift drift preserves the deliverable receipt and refuses continuation',
      () async {
        final receipt = await (await pending(await parent())).promote();
        if (drift == 'line') {
          await db.customStatement(
            'UPDATE job_lines SET notes = ? WHERE id = ?',
            ['Changed later', receipt.lineId],
          );
        } else if (drift == 'splits') {
          await db.customStatement(
            'UPDATE order_splits SET quantity = 1 WHERE job_line_id = ?',
            [receipt.lineId],
          );
        } else {
          const replacement = 'synthetic-other-valid-part';
          await db.partsDao.insertGeneralPart(
            id: replacement,
            name: 'Other valid Part',
            deviceId: device,
          );
          await db.customStatement(
            'UPDATE job_lines SET part_id = ? WHERE id = ?',
            [replacement, receipt.lineId],
          );
        }
        final before = await drafts();
        final beforeBusiness = await business();
        await reopen();
        final opening = await edits.openJobLine(job);
        expect(opening, isA<JobLinePromoted>());
        final cold = opening as JobLinePromoted;
        expect(cold.partId, receipt.partId);
        expect(cold.lineId, receipt.lineId);
        expect(cold.name, 'Nested raw name');
        expect(await drafts(), before);
        await expectLater(cold.acknowledgeAndContinue(), throwsStateError);
        await expectLater(cold.acknowledgeAndContinue(), throwsStateError);
        expect(await drafts(), before);
        expect(await business(), beforeBusiness);
        expect(await edits.openJobLine(job), isA<JobLinePromoted>());
        expect(await drafts(), before);
      },
    );
  }

  for (final entity in ['Part', 'line']) {
    for (final fault in ['missing', 'deleted', 'foreign device']) {
      test('$fault $entity blocks cold receipt delivery without writes', () async {
        final receipt = await (await pending(await parent())).promote();
        final table = entity == 'Part' ? 'parts' : 'job_lines';
        final id = entity == 'Part' ? receipt.partId : receipt.lineId;
        final statement = switch (fault) {
          'missing' => 'DELETE FROM $table WHERE id = ?',
          'deleted' => 'UPDATE $table SET deleted_at = 1 WHERE id = ?',
          _ =>
            "UPDATE $table SET origin_device_id = 'foreign-device' WHERE id = ?",
        };
        await db.customStatement(statement, [id]);
        final beforeDrafts = await drafts();
        final beforeBusiness = await business();
        await reopen();
        expect(
          await edits.openJobLine(job),
          isA<BlockedEdit<JobLineEditSession>>(),
        );
        expect(await drafts(), beforeDrafts);
        expect(await business(), beforeBusiness);
      });
    }
  }

  test('fresh destination collision blocks acknowledgment without changing either record', () async {
    final receipt = await (await pending(await parent())).promote();
    final collision = await parent(id: receipt.lineId);
    final before = await drafts();
    await expectLater(receipt.acknowledgeAndContinue(), throwsStateError);
    expect(await drafts(), before);
    expect(collision.initial.neededText, '09.50');
  });

  test('repeated acknowledgment preserves later raw edits and cannot resurrect retired state', () async {
    final receipt = await (await pending(await parent())).promote();
    final continuation = await receipt.acknowledgeAndContinue();
    continuation.replace(
      JobLineInput(
        useCustom: false,
        partId: receipt.partId,
        brandVersionId: null,
        customNameText: '',
        neededText: '0012.0',
        pullText: '02.0',
        customNotes: null,
        uom: null,
        notes: null,
        splits: [SplitInput(supplierId: supplier, quantityText: '03.00')],
      ),
    );
    await continuation.flush();
    expect(await receipt.acknowledgeAndContinue(), same(continuation));
    expect(continuation.initial.neededText, '0012.0');
    await continuation.save();
    final before = await drafts();
    await expectLater(receipt.acknowledgeAndContinue(), throwsStateError);
    expect(await drafts(), before);
  });

  test('legacy plain parent payload recovers without a child', () async {
    final owner = await parent();
    final key = await inputKey();
    await owner.leave(LeaveIntent.back);
    final raw = await stored(key);
    raw['input'] = (raw['input'] as Map)['line'];
    await db.settingsDao.setSetting(key, jsonEncode(raw));
    final resumed = await (await edits.openJobLine(
      job,
    ) as RecoverableEdit<JobLineEditSession>).resume();
    expect(resumed.initial.neededText, '09.50');
    expect((await resumed.openPromotion()).initial.nameText, 'Parent raw name');
  });

  test(
    'unsupported old promotion receipts remain blocked and retained',
    () async {
      final owner = await parent();
      final key = await inputKey();
      final raw = await stored(key);
      await owner.leave(LeaveIntent.back);
      await db.customStatement('DELETE FROM app_settings WHERE key = ?', [key]);
      final controlKey = key.replaceFirst('/input', '/control');
      final control = jsonEncode({
        'phase': 'committed',
        'token': raw['token'],
        'command': 'line-promote/old',
        'result': {'part': 'old-part', 'line': 'old-line'},
        'origin': raw['origin'],
      });
      await db.settingsDao.setSetting(controlKey, control);
      expect(
        await edits.openJobLine(job),
        isA<BlockedEdit<JobLineEditSession>>(),
      );
      expect(await db.settingsDao.getSetting(controlKey), control);
    },
  );

  for (final field in [
    'generation',
    'origin',
    'unknown input',
    'control token',
  ]) {
    test(
      'malformed or replaced $field remains blocked with all evidence retained',
      () async {
        final owner = await parent();
        await pending(owner);
        final key = await inputKey();
        await owner.leave(LeaveIntent.back);
        final raw = await stored(key);
        if (field == 'generation') {
          (((raw['input'] as Map)['promotion'] as Map))['generation'] = '';
        }
        if (field == 'origin') (raw['origin'] as Map)['device'] = 'foreign';
        if (field == 'unknown input') {
          (raw['input'] as Map)['unexpected'] = true;
        }
        await db.settingsDao.setSetting(key, jsonEncode(raw));
        if (field == 'control token') {
          await db.settingsDao.setSetting(
            key.replaceFirst('/input', '/control'),
            jsonEncode({'phase': 'editing', 'token': 'replacement'}),
          );
        }
        final before = await drafts();
        expect(
          await edits.openJobLine(job),
          isA<BlockedEdit<JobLineEditSession>>(),
        );
        expect(await drafts(), before);
      },
    );
  }
  test('bounded receipt failure rolls back valid admitted input and business writes', () async {
    final owner = await parent();
    final child = await owner.openPromotion();
    child.replace(details(name: 'n' * 140000));
    await child.flush();
    final before = await drafts();
    final beforeBusiness = await business();
    await expectLater(child.promote(), throwsStateError);
    expect(await drafts(), before);
    expect(await business(), beforeBusiness);
    expect(child.initial.nameText.length, 140000);
    child.replace(details());
    expect((await child.promote()).name, 'Nested raw name');
  });

  for (final deleted in [false, true]) {
    test(
      '${deleted ? 'tombstoned' : 'live'} reserved line collision blocks promotion',
      () async {
        final child = await pending(await parent());
        final record = await stored(await inputKey());
        final reserved = (record['target'] as Map)['reserved'] as String;
        await jobs.addLine(
          jobId: job,
          reservedLineId: reserved,
          customName: 'Collision',
          neededQty: 1,
        );
        if (deleted) await jobs.removeLine(reserved);
        final before = await business();
        final beforeDrafts = await drafts();
        await expectLater(child.promote(), throwsStateError);
        expect(await business(), before);
        expect(await drafts(), beforeDrafts);
      },
    );
  }

  for (final terminal in ['Save', 'remove', 'Discard']) {
    test(
      '$terminal consumes the parent and nested input despite stale child references',
      () async {
        final line = await jobs.addLine(
          jobId: job,
          customName: 'Existing',
          neededQty: 4,
        );
        final owner = await parent(id: line);
        await pending(owner);
        await db.customStatement(
          'UPDATE types SET deleted_at = 1 WHERE id = ?',
          [variant],
        );
        if (terminal == 'Save') {
          await owner.save();
        } else if (terminal == 'remove') {
          await owner.remove();
        } else {
          await owner.leave(LeaveIntent.discard);
        }
        final inputs = await db
            .customSelect(
              "SELECT key FROM app_settings WHERE key LIKE 'local_edit_v1/job-line%/input'",
            )
            .get();
        expect(inputs, isEmpty);
        expect(await db.select(db.parts).get(), isEmpty);
        if (terminal == 'Save') {
          expect(
            await edits.openJobLine(job, lineId: line),
            isA<FreshEdit<JobLineEditSession>>(),
          );
        }
        if (terminal == 'remove') {
          expect(
            await edits.openJobLine(job, lineId: line),
            isA<BlockedEdit<JobLineEditSession>>(),
          );
        }
      },
    );
  }

  test('promotion wrapper keeps the existing supplier split bound', () async {
    final owner = await parent();
    final child = await pending(owner);
    owner.replace(
      JobLineInput(
        useCustom: true,
        partId: null,
        brandVersionId: null,
        customNameText: 'Parent',
        neededText: '2',
        pullText: '0',
        customNotes: null,
        uom: null,
        notes: null,
        splits: List.filled(
          513,
          const SplitInput(supplierId: null, quantityText: ''),
        ),
      ),
    );
    await expectLater(child.flush(), throwsStateError);
    expect(owner.initial.splits.length, 513);
    expect(await db.select(db.parts).get(), isEmpty);
  });
}
