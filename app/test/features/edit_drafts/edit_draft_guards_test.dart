import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/part_details_dialog.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late Directory directory;
  late File file;
  late AppDatabase db;
  late String device, part, job;
  late PinService pin;
  late EditDrafts edits;

  void bind() {
    pin = PinService(db.settingsDao);
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
  }

  Future<void> reopen() async {
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
  }

  Future<JobLineEditSession> line({String? id}) async =>
      (await edits.openJobLine(
        job,
        lineId: id,
      ) as FreshEdit<JobLineEditSession>).session;
  JobLineInput input({String name = 'Unfinished custom', String qty = '8'}) =>
      JobLineInput(
        useCustom: true,
        partId: null,
        brandVersionId: null,
        customNameText: name,
        neededText: qty,
        pullText: '0',
        customNotes: null,
        uom: null,
        notes: null,
        splits: const [SplitInput(supplierId: null, quantityText: '')],
      );
  Future<PartEditSession> partSession() async =>
      (await edits.openPart(part) as FreshEdit<PartEditSession>).session;
  PartInput change(PartInput p, String name) => PartInput(
    nameText: name,
    descriptionText: p.descriptionText,
    specsText: p.specsText,
    uomText: p.uomText,
    categoryId: p.categoryId,
    styleId: p.styleId,
    typeId: p.typeId,
    defaultSupplierId: p.defaultSupplierId,
    active: p.active,
  );
  Future<List<Map<String, Object?>>> drafts() async =>
      (await db
              .customSelect(
                "SELECT key,value FROM app_settings WHERE key LIKE 'local_edit_v1/%' ORDER BY key",
              )
              .get())
          .map((r) => r.data)
          .toList();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('issue134-guards-');
    file = File('${directory.path}/synthetic.sqlite');
    db = AppDatabase.forTesting(NativeDatabase(file));
    device = await db.settingsDao.ensureDeviceId();
    bind();
    await db.taxonomyDao.insertCategory(
      id: 'c',
      name: 'Electrical',
      deviceId: device,
    );
    await db.taxonomyDao.insertStyle(
      id: 's',
      categoryId: 'c',
      name: 'Outlet',
      deviceId: device,
    );
    await db.taxonomyDao.insertType(
      id: 't',
      styleId: 's',
      name: 'Duplex',
      deviceId: device,
    );
    part = await CatalogRepository(db, pin, device).createGeneralPart(
      name: 'Original',
      categoryId: 'c',
      styleId: 's',
      typeId: 't',
    );
    job = await JobsRepository(db, device).createJob('Synthetic guarded job');
  });
  tearDown(() async {
    if (BackupIo.isBusy) BackupIo.end();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'untouched visits and fresh Save continuation create no resumable input',
    () async {
      final untouched = await line();
      await untouched.flush();
      await untouched.leave(LeaveIntent.back);
      expect(await drafts(), isEmpty);
      final p = await partSession();
      p.replace(change(p.initial, 'Edited'));
      await p.flush();
      final result = await p.save();
      await result.session.flush();
      expect((await drafts()).length, 1);
      expect((await p.save()).session, same(result.session));
      result.session.replace(change(result.session.initial, 'New unfinished'));
      await result.session.flush();
      await expectLater(p.save(), throwsStateError);
      await reopen();
      final recovery =
          await edits.openPart(part) as RecoverableEdit<PartEditSession>;
      expect((await recovery.resume()).initial.nameText, 'New unfinished');
    },
  );

  test('latest capture is unacknowledged until its own SQL commit', () async {
    final session = await line();
    session.replace(input(name: 'First'));
    await session.flush();
    final oldSequence = session.status.value.durableSequence;
    final entered = Completer<void>(), release = Completer<void>();
    final held = db.transaction(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    session.replace(input(name: 'Second'));
    expect(session.status.value.phase, EditPhase.writing);
    expect(session.status.value.latestSequence, oldSequence! + 1);
    expect(session.status.value.durableSequence, isNull);
    release.complete();
    await held;
    await session.flush();
    expect(session.status.value.phase, EditPhase.durable);
    expect(session.status.value.durableSequence, oldSequence + 1);
  });

  test('Discard seals a capture while actual SQLite admission is held and permits a clean next session', () async {
    final session = await line();
    final entered = Completer<void>(), release = Completer<void>();
    final held = db.transaction(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    session.replace(input(name: 'Held old capture'));
    var discarded = false;
    final discard = session
        .leave(LeaveIntent.discard)
        .then((_) => discarded = true);
    session.replace(input(name: 'Rejected after Discard intent'));
    expect(session.status.value.phase, EditPhase.closed);
    expect(discarded, false);
    release.complete();
    await held;
    await discard;
    final current = await line();
    current.replace(input(name: 'Next session input'));
    await current.flush();
    session.replace(input(name: 'Old handle must be inert'));
    await session.flush();
    await reopen();
    final recovery =
        await edits.openJobLine(job) as RecoverableEdit<JobLineEditSession>;
    expect(
      (await recovery.resume()).initial.customNameText,
      'Next session input',
    );
  });

  test(
    'PIN denial retains Part input and ordinary Job Save remains available',
    () async {
      await pin.setPin('2468');
      final p = await partSession();
      p.replace(change(p.initial, 'Retained under lock'));
      await p.flush();
      await expectLater(p.save(), throwsStateError);
      final j = await line();
      j.replace(input());
      await j.flush();
      final id = await j.save();
      expect(
        (await JobsRepository(db, device).getJobLine(id))!.customName,
        'Unfinished custom',
      );
      expect(pin.isUnlocked, false);
      await reopen();
      expect(
        (await (await edits.openPart(
          part,
        ) as RecoverableEdit<PartEditSession>).resume()).initial.nameText,
        'Retained under lock',
      );
    },
  );

  test(
    'changed base blocks Save and stale Resume while preserving exact bytes',
    () async {
      final p = await partSession();
      p.replace(change(p.initial, 'Mine'));
      await p.flush();
      final before = await drafts();
      await CatalogRepository(db, pin, device).updatePart(
        partId: part,
        name: 'External',
        description: '',
        uom: 'ea',
        active: true,
        categoryId: 'c',
        styleId: 's',
        typeId: 't',
      );
      await expectLater(p.save(), throwsStateError);
      expect(
        (await CatalogRepository(db, pin, device).getPart(part))!.name,
        'External',
      );
      await reopen();
      final blocked = await edits.openPart(part);
      expect(blocked, isA<BlockedEdit<PartEditSession>>());
      expect(await drafts(), before);
      expect(
        (blocked as BlockedEdit<PartEditSession>).preservedInput,
        contains('Mine'),
      );
      await blocked.discard();
      expect(await drafts(), isEmpty);
    },
  );

  test(
    'foreign and malformed recovery remain preserved until explicit Discard',
    () async {
      final j = await line();
      j.replace(input());
      await j.flush();
      final stored = await drafts();
      await reopen();
      final foreign = EditDrafts(db: db, pin: pin, deviceId: 'another-device');
      expect(
        await foreign.openJobLine(job),
        isA<BlockedEdit<JobLineEditSession>>(),
      );
      expect(await drafts(), stored);
      final key =
          stored.singleWhere(
                (r) => (r['key']! as String).endsWith('/input'),
              )['key']!
              as String;
      await db.settingsDao.setSetting(key, '{invalid-json');
      final blocked =
          await edits.openJobLine(job) as BlockedEdit<JobLineEditSession>;
      expect(blocked.preservedInput, '{invalid-json');
      await blocked.discard();
      expect(await drafts(), isEmpty);
      expect(
        await edits.openJobLine(job),
        isA<FreshEdit<JobLineEditSession>>(),
      );
    },
  );

  test('oversized input stays in memory with failure status and cannot be acknowledged', () async {
    final j = await line();
    final text = List.filled(270000, 'x').join();
    j.replace(input(name: text));
    await expectLater(j.flush(), throwsStateError);
    expect(j.initial.customNameText, text);
    expect(j.status.value.phase, EditPhase.storageFailed);
    expect(await drafts(), isEmpty);
    j.replace(input(name: 'Within limit'));
    await j.flush();
    expect(j.status.value.phase, EditPhase.durable);
  });

  test('promotion returns fresh existing-line session and retry creates no duplicate', () async {
    final j = await line();
    j.replace(input());
    await j.flush();
    const details = PartDetails(
      name: 'Promoted outlet',
      categoryId: 'c',
      styleId: 's',
      typeId: 't',
    );
    final result = await j.promote(details);
    expect((await j.promote(details)).lineId, result.lineId);
    expect((await db.select(db.jobLines).get()).length, 1);
    expect((await db.select(db.parts).get()).length, 2);
    expect(result.session.initial.partId, result.partId);
    result.session.replace(
      JobLineInput(
        useCustom: false,
        partId: result.partId,
        brandVersionId: null,
        customNameText: '',
        neededText: '12',
        pullText: '0',
        customNotes: null,
        uom: null,
        notes: null,
        splits: const [],
      ),
    );
    await result.session.flush();
    await result.session.save();
    expect(
      (await JobsRepository(db, device).getJobLine(result.lineId))!.neededQty,
      12,
    );
    expect((await db.select(db.jobLines).get()).length, 1);
  });

  test('Remove failure rolls back deletion and draft settlement then retry removes once', () async {
    final id = await JobsRepository(
      db,
      device,
    ).addLine(jobId: job, customName: 'Remove me', neededQty: 2);
    final j = await line(id: id);
    j.replace(input(name: 'Unfinished removal'));
    await j.flush();
    await db.customStatement(
      "CREATE TRIGGER reject_removed_receipt BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/%/control' AND instr(NEW.value, '\"phase\":\"committed\"') > 0 BEGIN SELECT RAISE(ABORT, 'receipt rejected'); END",
    );
    await expectLater(j.remove(), throwsA(anything));
    expect(
      (await JobsRepository(db, device).getJobLine(id))!.customName,
      'Remove me',
    );
    await db.customStatement('DROP TRIGGER reject_removed_receipt');
    await j.remove();
    await j.remove();
    expect(await JobsRepository(db, device).getJobLine(id), isNull);
    expect((await db.select(db.jobLines).get()).single.deletedAt, isNotNull);
    expect((await drafts()).length, 1);
  });

  test('quiesce failure retains usable input and successful retry fences the old generation', () async {
    final j = await line();
    j.replace(input(name: 'Kept'));
    await j.flush();
    await db.customStatement(
      "CREATE TRIGGER reject_draft_flush BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/%/input' BEGIN SELECT RAISE(ABORT, 'disk refusal'); END",
    );
    await expectLater(
      edits.quiesce(StorageChange.replacement),
      throwsA(anything),
    );
    expect(j.initial.customNameText, 'Kept');
    await db.customStatement('DROP TRIGGER reject_draft_flush');
    j.replace(input(name: 'Retained owner works'));
    await j.flush();
    await edits.quiesce(StorageChange.replacement);
    final before = await drafts();
    j.replace(input(name: 'Must never persist'));
    await j.flush();
    expect(await drafts(), before);
    expect(
      await edits.openJobLine(job),
      isA<BlockedEdit<JobLineEditSession>>(),
    );
    await reopen();
    final recovery =
        await edits.openJobLine(job) as RecoverableEdit<JobLineEditSession>;
    expect(
      (await recovery.resume()).initial.customNameText,
      'Retained owner works',
    );
  });

  test('own photo reference advances only its draft base and rolls back both on draft failure', () async {
    final p = await partSession();
    p.replace(change(p.initial, 'Unfinished around photo'));
    await p.flush();
    final original = (await CatalogRepository(db, pin, device).getPart(part))!;
    await db.customStatement(
      "CREATE TRIGGER refuse_photo_draft BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/%/input' AND NEW.value != OLD.value BEGIN SELECT RAISE(ABORT, 'photo draft refusal'); END",
    );
    await expectLater(p.clearPhoto(root: directory), throwsA(anything));
    expect(
      (await CatalogRepository(db, pin, device).getPart(part))!.revision,
      original.revision,
    );
    await db.customStatement('DROP TRIGGER refuse_photo_draft');
    await p.clearPhoto(root: directory);
    expect(
      (await CatalogRepository(db, pin, device).getPart(part))!.revision,
      original.revision + 1,
    );
    expect(p.initial.nameText, 'Unfinished around photo');
    expect(
      (await drafts()).map((r) => r['value']).join(),
      isNot(contains('photo_path')),
    );
    await p.save();
    expect(
      (await CatalogRepository(db, pin, device).getPart(part))!.name,
      'Unfinished around photo',
    );
    expect(
      (await CatalogRepository(db, pin, device).getPart(part))!.revision,
      original.revision + 2,
    );
  });

  test(
    'Save rechecks target after real held SQLite mutation before its guard',
    () async {
      final p = await partSession();
      p.replace(change(p.initial, 'Stale intent'));
      await p.flush();
      final entered = Completer<void>(), release = Completer<void>();
      final competing = db.transaction(() async {
        await CatalogRepository(db, pin, device).updatePart(
          partId: part,
          name: 'Competing writer',
          description: '',
          uom: 'ea',
          active: true,
          categoryId: 'c',
          styleId: 's',
          typeId: 't',
        );
        entered.complete();
        await release.future;
      });
      await entered.future;
      final refusal = expectLater(p.save(), throwsStateError);
      release.complete();
      await competing;
      await refusal;
      expect(
        (await CatalogRepository(db, pin, device).getPart(part))!.name,
        'Competing writer',
      );
      await reopen();
      expect(await edits.openPart(part), isA<BlockedEdit<PartEditSession>>());
    },
  );

  test('slash-containing legacy identities have independent slots and exact target recovery', () async {
    await db.jobsDao.insertJob(
      id: 'group/a',
      name: 'First legacy job',
      deviceId: device,
    );
    await db.jobsDao.insertJob(
      id: 'group',
      name: 'Second legacy job',
      deviceId: device,
    );
    await JobsRepository(db, device).addLine(
      jobId: 'group/a',
      reservedLineId: 'b',
      customName: 'First baseline',
      neededQty: 1,
    );
    await JobsRepository(db, device).addLine(
      jobId: 'group',
      reservedLineId: 'a/b',
      customName: 'Second baseline',
      neededQty: 1,
    );
    final first = (await edits.openJobLine(
      'group/a',
      lineId: 'b',
    ) as FreshEdit<JobLineEditSession>).session;
    first.replace(input(name: 'First independent input'));
    await first.leave(LeaveIntent.back);
    final secondOpening = await edits.openJobLine('group', lineId: 'a/b');
    expect(secondOpening, isA<FreshEdit<JobLineEditSession>>());
    final second = (secondOpening as FreshEdit<JobLineEditSession>).session;
    second.replace(input(name: 'Second independent input'));
    await second.leave(LeaveIntent.back);
    await reopen();
    final firstRecovery = await edits.openJobLine(
      'group/a',
      lineId: 'b',
    ) as RecoverableEdit<JobLineEditSession>;
    final secondRecovery = await edits.openJobLine(
      'group',
      lineId: 'a/b',
    ) as RecoverableEdit<JobLineEditSession>;
    expect(
      (await firstRecovery.resume()).initial.customNameText,
      'First independent input',
    );
    expect(
      (await secondRecovery.resume()).initial.customNameText,
      'Second independent input',
    );
    expect((await drafts()).length, 4);
  });

  test(
    'new nonexistent selections block Resume without silently clearing IDs',
    () async {
      final j = await line();
      j.replace(
        JobLineInput(
          useCustom: false,
          partId: 'missing-part',
          brandVersionId: null,
          customNameText: 'inactive text',
          neededText: 'invalid raw',
          pullText: '0',
          customNotes: null,
          uom: null,
          notes: null,
          splits: const [],
        ),
      );
      await j.leave(LeaveIntent.back);
      final before = await drafts();
      final opening = await edits.openJobLine(job);
      expect(opening, isA<BlockedEdit<JobLineEditSession>>());
      expect(
        (opening as BlockedEdit<JobLineEditSession>).preservedInput,
        contains('missing-part'),
      );
      expect(await drafts(), before);
    },
  );

  test(
    'already missing persisted references retain existing editor behavior',
    () async {
      final id = await JobsRepository(
        db,
        device,
      ).addLine(jobId: job, partId: 'historical-missing', neededQty: 2);
      final j = await line(id: id);
      j.replace(
        JobLineInput(
          useCustom: false,
          partId: 'historical-missing',
          brandVersionId: null,
          customNameText: '',
          neededText: '3',
          pullText: '0',
          customNotes: null,
          uom: null,
          notes: null,
          splits: const [],
        ),
      );
      await j.leave(LeaveIntent.back);
      final recovery = await edits.openJobLine(
        job,
        lineId: id,
      ) as RecoverableEdit<JobLineEditSession>;
      final restored = await recovery.resume();
      await restored.save();
      expect((await JobsRepository(db, device).getJobLine(id))!.neededQty, 3);
      expect(
        (await JobsRepository(db, device).getJobLine(id))!.partId,
        'historical-missing',
      );
    },
  );

  test(
    'unavailable installation never downgrades or loses in-memory raw edits',
    () async {
      final installation = InstallationSecurity(
        store: const NativeInstallationSecureStore(),
        namespace: 'synthetic.issue134',
      );
      final owner = EditDrafts(
        db: db,
        pin: pin,
        deviceId: device,
        installation: installation,
      );
      final fresh =
          await owner.openJobLine(job) as FreshEdit<JobLineEditSession>;
      expect(fresh.session.status.value.phase, EditPhase.recoveryBlocked);
      fresh.session.replace(input(name: '  kept while unavailable  '));
      await expectLater(fresh.session.flush(), throwsStateError);
      expect(
        fresh.session.initial.customNameText,
        '  kept while unavailable  ',
      );
      expect(await drafts(), isEmpty);
      installation.readiness = InstallationReadiness.unsupported;
      await fresh.session.flush();
      expect(fresh.session.status.value.phase, EditPhase.durable);
      final saved = await drafts();
      final envelope = jsonDecode(
        saved.singleWhere(
              (r) => (r['key']! as String).endsWith('/input'),
            )['value']!
            as String,
      ) as Map<String, dynamic>;
      expect(envelope['origin'], {'mode': 'device', 'device': device});
    },
  );

  test('unsupported stored version and company activation retain input without business mutation', () async {
    final j = await line();
    j.replace(input());
    await j.flush();
    await db.customStatement(
      'INSERT INTO company_join_events (request_id,ordinal,kind,evidence_bytes) VALUES (?, ?, ?, ?)',
      ['draft-blocker', 1, 'blocked', 'synthetic marker'],
    );
    await expectLater(j.save(), throwsStateError);
    expect(await JobsRepository(db, device).listLinesForJob(job), isEmpty);
    await j.leave(LeaveIntent.back);
    final rows = await drafts();
    final inputRow = rows.singleWhere(
      (r) => (r['key']! as String).endsWith('/input'),
    );
    final envelope =
        jsonDecode(inputRow['value']! as String) as Map<String, dynamic>;
    envelope['v'] = 99;
    final invalid = jsonEncode(envelope);
    await db.settingsDao.setSetting(inputRow['key']! as String, invalid);
    final blocked =
        await edits.openJobLine(job) as BlockedEdit<JobLineEditSession>;
    expect(blocked.preservedInput, invalid);
    expect(blocked.reason, contains('version'));
  });

  test('draft input and receipts keep fresh-company admission strict with binding-only control', () async {
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      await fresh.settingsDao.setSetting(
        kInstallationBindingKey,
        'binding-only-test',
      );
      await CompanyBootstrap.preflightFreshShop(fresh);
      await fresh.settingsDao.setSetting(
        'local_edit_v1/job-line-new/synthetic/control',
        '{"phase":"committed"}',
      );
      await expectLater(
        CompanyBootstrap.preflightFreshShop(fresh),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      expect(
        await fresh.settingsDao.getSetting(kInstallationBindingKey),
        'binding-only-test',
      );
    } finally {
      await fresh.close();
    }
  });

  test('held BackupIo photo operation cannot deadlock quiesce or write the closed generation', () async {
    final p = await partSession();
    p.replace(change(p.initial, 'Raw retained'));
    await p.flush();
    expect(BackupIo.tryStart(), true);
    final failure = expectLater(
      p.clearPhoto(root: directory),
      throwsStateError,
    );
    await edits
        .quiesce(StorageChange.replacement)
        .timeout(const Duration(seconds: 2));
    final before = await drafts();
    await db.close();
    BackupIo.end();
    await failure;
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
    expect(await drafts(), before);
    expect(
      (await CatalogRepository(db, pin, device).getPart(part))!.photoPath,
      isNull,
    );
  });
}
