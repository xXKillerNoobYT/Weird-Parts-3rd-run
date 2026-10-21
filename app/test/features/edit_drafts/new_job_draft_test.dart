import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late Directory directory;
  late File file;
  late AppDatabase db;
  late String device;
  late PinService pin;
  late EditDrafts edits;

  const inputKey = 'local_edit_v1/job-new/input';
  const controlKey = 'local_edit_v1/job-new/control';

  void bind() {
    pin = PinService(db.settingsDao);
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
  }

  Future<void> reopen() async {
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
  }

  Future<NewJobEditSession> fresh() async {
    final opening = await edits.openNewJob();
    expect(opening, isA<FreshEdit<NewJobEditSession>>());
    return (opening as FreshEdit<NewJobEditSession>).session;
  }

  Future<Map<String, Object?>> draftRecord() async =>
      jsonDecode((await db.settingsDao.getSetting(inputKey))!)
          as Map<String, Object?>;

  Future<String> reservedId() async =>
      ((await draftRecord())['target'] as Map<String, Object?>)['reserved']!
          as String;

  Future<List<Map<String, Object?>>> drafts() async =>
      (await db
              .customSelect(
                "SELECT key, value FROM app_settings WHERE key LIKE 'local_edit_v1/job-new/%' ORDER BY key",
              )
              .get())
          .map((row) => row.data)
          .toList();

  Future<List<(String, String, DateTime?)>> jobRows() async =>
      (await db.select(db.jobs).get())
          .map((job) => (job.id, job.name, job.deletedAt))
          .toList();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('new-job-draft-');
    file = File('${directory.path}/synthetic.sqlite');
    db = AppDatabase.forTesting(NativeDatabase(file));
    device = await db.settingsDao.ensureDeviceId();
    bind();
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'raw name resumes after file reopen and only explicit Save creates one Job',
    () async {
      const raw = '  Riverside pump repair\nphase 2  ';
      final session = await fresh();
      session.replace(const NewJobInput(nameText: raw));
      await session.flush();
      expect(await db.select(db.jobs).get(), isEmpty);

      await reopen();
      final opening = await edits.openNewJob();
      expect(opening, isA<RecoverableEdit<NewJobEditSession>>());
      final resumed = await (opening as RecoverableEdit<NewJobEditSession>)
          .resume();
      expect(resumed.initial.nameText, raw);
      expect(await db.select(db.jobs).get(), isEmpty);

      final reserved = await reservedId();
      final created = await resumed.save();
      expect(created.id, reserved);
      expect(created.name, 'Riverside pump repair\nphase 2');
      expect(
        (await JobsRepository(db, device).getJob(created.id))!.name,
        created.name,
      );
      expect((await db.select(db.jobs).get()).length, 1);
    },
  );

  test(
    'Discard seals queued and late captures without creating a Job',
    () async {
      final session = await fresh();
      session.replace(const NewJobInput(nameText: 'queued input'));
      final flush = session.flush();
      final discard = session.leave(LeaveIntent.discard);
      session.replace(const NewJobInput(nameText: 'late input after Discard'));
      await discard;
      await flush;
      await edits.quiesce(StorageChange.exit);
      expect(await drafts(), isEmpty);
      expect(await db.select(db.jobs).get(), isEmpty);

      await reopen();
      expect(await edits.openNewJob(), isA<FreshEdit<NewJobEditSession>>());
      expect(await db.select(db.jobs).get(), isEmpty);
    },
  );

  test(
    'whitespace-only Create keeps exact input recoverable and creates no Job',
    () async {
      const raw = ' \n\t ';
      final session = await fresh();
      session.replace(const NewJobInput(nameText: raw));
      await session.flush();
      final before = await drafts();
      await expectLater(session.save(), throwsStateError);
      expect(await db.select(db.jobs).get(), isEmpty);
      expect(await drafts(), before);

      await reopen();
      final recoverable =
          await edits.openNewJob() as RecoverableEdit<NewJobEditSession>;
      expect((await recoverable.resume()).initial.nameText, raw);
      expect(await db.select(db.jobs).get(), isEmpty);
    },
  );

  test(
    'reserved Job ID collision with a tombstone preserves draft and tombstone',
    () async {
      final session = await fresh();
      session.replace(const NewJobInput(nameText: 'Collision recovery'));
      await session.flush();
      final id = await reservedId();
      final now = DateTime.utc(2026, 10, 21);
      await db
          .into(db.jobs)
          .insert(
            JobsCompanion.insert(
              id: id,
              name: 'Deleted prior Job',
              originDeviceId: device,
              createdAt: now,
              modifiedAt: now,
              deletedAt: Value(now),
            ),
          );
      final beforeJobs = await jobRows();
      final beforeDrafts = await drafts();

      await expectLater(session.save(), throwsStateError);
      expect(await jobRows(), beforeJobs);
      expect(await drafts(), beforeDrafts);
    },
  );

  test(
    'company legacy-write denial preserves draft without creating a Job',
    () async {
      final session = await fresh();
      session.replace(const NewJobInput(nameText: 'Denied local creation'));
      await session.flush();
      final beforeDrafts = await drafts();
      await db.customStatement(
        "INSERT INTO company_bootstrap_witnesses "
        "(company_id, bootstrap_id, facts_commitment, package_id, package_digest, status) "
        "VALUES ('synthetic-company', 'synthetic-bootstrap', 'facts', 'package', NULL, 'pending')",
      );

      await expectLater(session.save(), throwsStateError);
      expect(await db.select(db.jobs).get(), isEmpty);
      expect(await drafts(), beforeDrafts);
    },
  );

  test(
    'Job insert failure rolls back and leaves input recoverable for retry',
    () async {
      final session = await fresh();
      session.replace(const NewJobInput(nameText: 'Insert failure'));
      await session.flush();
      final beforeDrafts = await drafts();
      await db.customStatement(
        "CREATE TRIGGER reject_new_job BEFORE INSERT ON jobs WHEN NEW.name = 'Insert failure' BEGIN SELECT RAISE(ABORT, 'synthetic Job insert failure'); END",
      );

      await expectLater(
        session.save(),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('synthetic Job insert failure'),
          ),
        ),
      );
      expect(await db.select(db.jobs).get(), isEmpty);
      expect(await drafts(), beforeDrafts);
      await reopen();
      final resumed =
          await (await edits.openNewJob() as RecoverableEdit<NewJobEditSession>)
              .resume();
      expect(resumed.initial.nameText, 'Insert failure');
      await db.customStatement('DROP TRIGGER reject_new_job');
      expect((await resumed.save()).name, 'Insert failure');
      expect((await db.select(db.jobs).get()).length, 1);
    },
  );

  test('committed receipt SQL failure rolls back Job and input retirement together', () async {
    final session = await fresh();
    session.replace(const NewJobInput(nameText: 'Receipt failure'));
    await session.flush();
    final beforeDrafts = await drafts();
    await db.customStatement(
      "CREATE TRIGGER reject_new_job_receipt BEFORE UPDATE ON app_settings WHEN NEW.key = 'local_edit_v1/job-new/control' AND instr(NEW.value, '\"phase\":\"committed\"') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic Job receipt failure'); END",
    );

    await expectLater(
      session.save(),
      throwsA(
        predicate(
          (error) => error.toString().contains('synthetic Job receipt failure'),
        ),
      ),
    );
    expect(await db.select(db.jobs).get(), isEmpty);
    expect(await drafts(), beforeDrafts);
    await reopen();
    final opening = await edits.openNewJob();
    expect(opening, isA<RecoverableEdit<NewJobEditSession>>());
    expect(
      (await (opening as RecoverableEdit<NewJobEditSession>).resume())
          .initial
          .nameText,
      'Receipt failure',
    );
  });

  test(
    'successful Save retries the same reserved ID and creates exactly one Job',
    () async {
      final session = await fresh();
      session.replace(const NewJobInput(nameText: 'One committed Job'));
      await session.flush();
      final id = await reservedId();

      final first = await session.save();
      final retry = await session.save();
      expect(first.id, id);
      expect(retry.id, id);
      expect(retry.name, 'One committed Job');
      expect((await db.select(db.jobs).get()).map((job) => job.id), [id]);
      expect(await db.settingsDao.getSetting(inputKey), isNull);
      expect(await db.settingsDao.getSetting(controlKey), isNotNull);
    },
  );

  test('unacknowledged committed receipt reopens same Job until exact acknowledgement', () async {
    final session = await fresh();
    session.replace(const NewJobInput(nameText: 'Recover committed Job'));
    await session.flush();
    final created = await session.save();
    await reopen();

    final opening = await edits.openNewJob();
    expect(opening, isA<NewJobCreated>());
    final recovered = opening as NewJobCreated;
    expect((recovered.id, recovered.name), (created.id, created.name));
    expect((await db.select(db.jobs).get()).map((job) => job.id), [created.id]);
    await recovered.acknowledge();
    expect(await db.settingsDao.getSetting(controlKey), isNull);
    expect((await db.select(db.jobs).get()).map((job) => job.id), [created.id]);
    expect(await edits.openNewJob(), isA<FreshEdit<NewJobEditSession>>());
  });

  test('changed or deleted Job and malformed receipt block without clearing evidence', () async {
    Future<NewJobCreated> create(String name) async {
      final session = await fresh();
      session.replace(NewJobInput(nameText: name));
      await session.flush();
      return session.save();
    }

    final changed = await create('Changed after create');
    await db.customStatement('UPDATE jobs SET name = ? WHERE id = ?', [
      'External rename',
      changed.id,
    ]);
    await reopen();
    var receipt = await db.settingsDao.getSetting(controlKey);
    final blockedChanged =
        await edits.openNewJob() as BlockedEdit<NewJobEditSession>;
    expect(blockedChanged.preservedInput, receipt);
    expect(await db.settingsDao.getSetting(controlKey), receipt);
    await blockedChanged.discard();

    final deleted = await create('Deleted after create');
    await db.customStatement('DELETE FROM jobs WHERE id = ?', [deleted.id]);
    await reopen();
    receipt = await db.settingsDao.getSetting(controlKey);
    final blockedDeleted =
        await edits.openNewJob() as BlockedEdit<NewJobEditSession>;
    expect(blockedDeleted.preservedInput, receipt);
    expect(await db.settingsDao.getSetting(controlKey), receipt);
    await blockedDeleted.discard();

    final malformed = await create('Malformed receipt evidence');
    expect(malformed.id, isNotEmpty);
    await db.settingsDao.setSetting(controlKey, '{invalid-json');
    await reopen();
    final blockedMalformed =
        await edits.openNewJob() as BlockedEdit<NewJobEditSession>;
    expect(blockedMalformed.preservedInput, '{invalid-json');
    expect(await db.settingsDao.getSetting(controlKey), '{invalid-json');
  });

  test('foreign-origin draft remains blocked and preserved', () async {
    final session = await fresh();
    session.replace(const NewJobInput(nameText: 'Device-bound input'));
    await session.flush();
    final before = await drafts();
    await reopen();
    final foreign = EditDrafts(
      db: db,
      pin: pin,
      deviceId: 'synthetic-other-device',
    );

    expect(await foreign.openNewJob(), isA<BlockedEdit<NewJobEditSession>>());
    expect(await drafts(), before);
    expect(await db.select(db.jobs).get(), isEmpty);
  });

  test(
    'acknowledgement refuses a replaced receipt and leaves Job untouched',
    () async {
      final session = await fresh();
      session.replace(const NewJobInput(nameText: 'Ack exact receipt'));
      await session.flush();
      final created = await session.save();
      final replacement = '{"phase":"editing","token":"replacement"}';
      await db.settingsDao.setSetting(controlKey, replacement);

      await expectLater(created.acknowledge(), throwsStateError);
      expect(await db.settingsDao.getSetting(controlKey), replacement);
      expect((await db.select(db.jobs).get()).map((job) => job.id), [
        created.id,
      ]);
    },
  );
}
