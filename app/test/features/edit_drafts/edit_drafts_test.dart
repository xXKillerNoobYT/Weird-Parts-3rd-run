import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late Directory directory;
  late File file;
  late AppDatabase db;
  late String device;
  late String job;
  late String part;
  late EditDrafts edits;

  void bind() {
    edits = EditDrafts(
      db: db,
      pin: PinService(db.settingsDao),
      deviceId: device,
    );
  }

  Future<void> reopen() async {
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('issue134-drafts-');
    file = File('${directory.path}/synthetic.sqlite');
    db = AppDatabase.forTesting(NativeDatabase(file));
    device = await db.settingsDao.ensureDeviceId();
    await db.taxonomyDao.insertCategory(
      id: 'cat',
      name: 'Electrical',
      deviceId: device,
    );
    await db.taxonomyDao.insertStyle(
      id: 'style',
      categoryId: 'cat',
      name: 'Outlet',
      deviceId: device,
    );
    await db.taxonomyDao.insertType(
      id: 'type',
      styleId: 'style',
      name: 'Duplex',
      deviceId: device,
    );
    await db.taxonomyDao.insertSupplier(
      id: 'supplier',
      name: 'Supply',
      deviceId: device,
    );
    part = await CatalogRepository(db, PinService(db.settingsDao), device)
        .createGeneralPart(
          name: 'Baseline outlet',
          categoryId: 'cat',
          styleId: 'style',
          typeId: 'type',
        );
    job = await JobsRepository(db, device).createJob('Synthetic draft job');
    bind();
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  JobLineInput lineInput({
    String needed = ' 7.25 ',
    String name = '  unfinished custom  ',
  }) => JobLineInput(
    useCustom: true,
    partId: null,
    brandVersionId: null,
    customNameText: name,
    neededText: needed,
    pullText: ' 2 ',
    customNotes: '  retained custom notes\n',
    uom: 'box',
    notes: '  notes  ',
    splits: const [
      SplitInput(supplierId: 'supplier', quantityText: ' 3 '),
      SplitInput(supplierId: null, quantityText: ''),
    ],
  );

  Future<JobLineEditSession> freshLine() async {
    final opening = await edits.openJobLine(job);
    expect(opening, isA<FreshEdit<JobLineEditSession>>());
    return (opening as FreshEdit<JobLineEditSession>).session;
  }

  test('file reopen requires explicit Resume and preserves raw invalid input without business mutation', () async {
    final before = await db.select(db.jobLines).get();
    final session = await freshLine();
    session.replace(lineInput(needed: '  not a number  '));
    await session.flush();
    expect(session.status.value.phase, EditPhase.durable);
    expect(
      session.status.value.durableSequence,
      session.status.value.latestSequence,
    );
    expect(await db.select(db.jobLines).get(), before);
    await reopen();
    final opening = await edits.openJobLine(job);
    expect(opening, isA<RecoverableEdit<JobLineEditSession>>());
    final recovered = await (opening as RecoverableEdit<JobLineEditSession>)
        .resume();
    expect(recovered.initial.customNameText, '  unfinished custom  ');
    expect(recovered.initial.neededText, '  not a number  ');
    expect(recovered.initial.customNotes, '  retained custom notes\n');
    expect(
      recovered.initial.splits
          .map((s) => (s.supplierId, s.quantityText))
          .toList(),
      [('supplier', ' 3 '), (null, '')],
    );
    expect(await db.select(db.jobLines).get(), before);
  });

  test(
    'Part raw fields survive file reopen without changing the Part',
    () async {
      final before = await CatalogRepository(
        db,
        PinService(db.settingsDao),
        device,
      ).getPart(part);
      final opening = await edits.openPart(part);
      final session = (opening as FreshEdit<PartEditSession>).session;
      session.replace(
        const PartInput(
          nameText: '  Outlet unfinished ',
          descriptionText: '\nraw description ',
          specsText: '  spec\n',
          uomText: '  box ',
          categoryId: 'cat',
          styleId: 'style',
          typeId: 'type',
          defaultSupplierId: 'supplier',
          active: false,
        ),
      );
      await session.flush();
      expect(session.status.value.phase, EditPhase.durable);
      await reopen();
      final recovery = await edits.openPart(part);
      expect(recovery, isA<RecoverableEdit<PartEditSession>>());
      final resumed = await (recovery as RecoverableEdit<PartEditSession>)
          .resume();
      expect(resumed.initial.nameText, '  Outlet unfinished ');
      expect(resumed.initial.descriptionText, '\nraw description ');
      expect(resumed.initial.specsText, '  spec\n');
      expect(resumed.initial.uomText, '  box ');
      expect(resumed.initial.defaultSupplierId, 'supplier');
      expect(resumed.initial.active, false);
      expect(
        await CatalogRepository(
          db,
          PinService(db.settingsDao),
          device,
        ).getPart(part),
        before,
      );
    },
  );

  test(
    'queued capture cannot resurrect Discard or delete a newer session',
    () async {
      final old = await freshLine();
      old.replace(lineInput(name: 'old input'));
      final oldFlush = old.flush();
      final discard = old.leave(LeaveIntent.discard);
      old.replace(lineInput(name: 'late old input'));
      await discard;
      await oldFlush;
      final current = await freshLine();
      current.replace(lineInput(name: 'new input'));
      await current.flush();
      old.replace(lineInput(name: 'even later old input'));
      await old.flush();
      await reopen();
      final opening = await edits.openJobLine(job);
      expect(opening, isA<RecoverableEdit<JobLineEditSession>>());
      final resumed = await (opening as RecoverableEdit<JobLineEditSession>)
          .resume();
      expect(resumed.initial.customNameText, 'new input');
      expect(await db.select(db.jobLines).get(), isEmpty);
    },
  );

  test('real repository Save and draft deletion roll back together when receipt SQL fails', () async {
    final session = await freshLine();
    session.replace(lineInput());
    await session.flush();
    expect(session.status.value.phase, EditPhase.durable);
    final beforeDrafts = await db
        .customSelect(
          "SELECT key, value FROM app_settings WHERE key LIKE 'local_edit_v1/%' ORDER BY key",
        )
        .get();
    final before = beforeDrafts.map((r) => r.data).toList();
    await db.customStatement(
      "CREATE TRIGGER fail_draft_receipt BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/%/control' AND instr(NEW.value, '\"phase\":\"committed\"') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END",
    );
    await expectLater(
      session.save(),
      throwsA(
        predicate((e) => e.toString().contains('synthetic receipt failure')),
      ),
    );
    await reopen();
    expect(await db.select(db.jobLines).get(), isEmpty);
    expect(await db.select(db.orderSplits).get(), isEmpty);
    expect(
      (await db
              .customSelect(
                "SELECT key, value FROM app_settings WHERE key LIKE 'local_edit_v1/%' ORDER BY key",
              )
              .get())
          .map((r) => r.data)
          .toList(),
      before,
    );
    final opening = await edits.openJobLine(job);
    expect(opening, isA<RecoverableEdit<JobLineEditSession>>());
    final resumed = await (opening as RecoverableEdit<JobLineEditSession>)
        .resume();
    expect(resumed.initial.neededText, ' 7.25 ');
  });

  test('lost Save reply retries one stable line and leaves no resumable settled input', () async {
    final session = await freshLine();
    session.replace(lineInput());
    await session.flush();
    final committed = await session.save();
    session.replace(lineInput(name: 'late after save'));
    final retry = await session.save();
    expect(retry, committed);
    final lines = await db.select(db.jobLines).get();
    expect(lines, hasLength(1));
    expect(lines.single.id, committed);
    expect(lines.single.customName, 'unfinished custom');
    expect(lines.single.neededQty, 7.25);
    expect(lines.single.customNotes, '  retained custom notes\n');
    expect(
      (await JobsRepository(db, device).orderSplitsForLine(committed))
          .single
          .quantity,
      3,
    );
    await reopen();
    expect(await edits.openJobLine(job), isA<FreshEdit<JobLineEditSession>>());
    expect(await db.select(db.jobLines).get(), lines);
  });
}
