import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

void main() {
  late Directory directory;
  late File file;
  late WarehouseFixture fixture;
  late AppDatabase db;
  late String device;
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

  Future<EditOpening<WarehouseCountEditSession>> open({
    String? prior,
    String? location,
    String? part,
    String uom = 'ea',
  }) => edits.openWarehouseCount(
    locationId: location ?? fixture.locationId,
    partId: part ?? fixture.partId,
    uom: uom,
    expectedPriorCountId: prior,
  );

  Future<WarehouseCountEditSession> fresh({String? prior}) async {
    final opening = await open(prior: prior);
    expect(opening, isA<FreshEdit<WarehouseCountEditSession>>());
    return (opening as FreshEdit<WarehouseCountEditSession>).session;
  }

  WarehouseCountInput input({
    String quantity = ' 7.25 ',
    String note = '  count note  ',
    DateTime? observedAt,
  }) => WarehouseCountInput(
    quantityText: quantity,
    noteText: note,
    observedAt: observedAt ?? DateTime.utc(2026, 10, 21, 13, 14, 15),
  );

  Future<List<Map<String, Object?>>> countRows() async =>
      (await db.select(db.warehouseCounts).get())
          .map(
            (row) => {
              'id': row.id,
              'location': row.locationId,
              'part': row.partId,
              'prior': row.priorCountId,
              'ordinal': row.ordinal,
              'quantity': row.quantity,
              'uom': row.uom,
              'observedAt': row.observedAt,
              'note': row.note,
              'origin': row.originDeviceId,
            },
          )
          .toList();

  String inputKey() =>
      'local_edit_v1/warehouse-count/${Uri.encodeComponent(fixture.locationId)}/${Uri.encodeComponent(fixture.partId)}/input';
  String controlKey() =>
      'local_edit_v1/warehouse-count/${Uri.encodeComponent(fixture.locationId)}/${Uri.encodeComponent(fixture.partId)}/control';

  Future<List<Map<String, Object?>>> draftRows() async =>
      (await db
              .customSelect(
                "SELECT key, value FROM app_settings WHERE key LIKE 'local_edit_v1/warehouse-count/%' ORDER BY key",
              )
              .get())
          .map((row) => row.data)
          .toList();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'warehouse-count-draft-core-',
    );
    file = File('${directory.path}/synthetic.sqlite');
    fixture = await WarehouseFixture.create(file: file);
    db = fixture.db;
    device = fixture.device;
    bind();
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'raw invalid fields and exact instant survive file reopen without a count',
    () async {
      const rawQuantity = '  not-a-number\n  ';
      const rawNote = '  first line\nsecond line · exact  ';
      final observedAt = DateTime.utc(2026, 9, 15, 10, 30, 45, 321);
      final session = await fresh();
      session.replace(
        input(quantity: rawQuantity, note: rawNote, observedAt: observedAt),
      );
      await session.flush();
      final reserved = session.countId;
      expect(await db.select(db.warehouseCounts).get(), isEmpty);

      await reopen();
      final recovery = await open();
      expect(recovery, isA<RecoverableEdit<WarehouseCountEditSession>>());
      final resumed =
          await (recovery as RecoverableEdit<WarehouseCountEditSession>)
              .resume();
      expect(resumed.countId, reserved);
      expect(resumed.initial.quantityText, rawQuantity);
      expect(resumed.initial.noteText, rawNote);
      expect(resumed.initial.observedAt, observedAt);
      expect(await db.select(db.warehouseCounts).get(), isEmpty);
    },
  );

  test('valid zero saves once with its reserved ID and causal head; retry is idempotent', () async {
    final prior = await fixture.repo.recordCount(
      fixture.draft(quantity: 8, note: 'Prior'),
    );
    final session = await fresh(prior: prior.id);
    final reserved = session.countId;
    final observedAt = DateTime.utc(2026, 10, 21, 13, 14, 15);
    session.replace(
      input(quantity: ' 0 ', note: '  zero check\n ', observedAt: observedAt),
    );
    await session.flush();

    final saved = await session.save();
    expect(saved.count.id, reserved);
    expect(saved.count.quantity, 0);
    expect(saved.count.priorCountId, prior.id);
    expect(saved.count.ordinal, prior.ordinal + 1);
    expect(saved.count.note, 'zero check');
    expect(saved.count.observedAt.isAtSameMomentAs(observedAt), isTrue);
    expect((await session.save()).count.id, reserved);
    expect((await db.select(db.warehouseCounts).get()).map((row) => row.id), [
      prior.id,
      reserved,
    ]);
    await saved.acknowledge();
    expect(await db.settingsDao.getSetting(inputKey()), isNull);
    expect(await db.settingsDao.getSetting(controlKey()), isNull);
  });

  test(
    'invalid quantity save preserves exact input and does not create a count',
    () async {
      const raw = ' \n  NaN  ';
      final session = await fresh();
      session.replace(input(quantity: raw));
      await session.flush();
      final beforeDraft = await draftRows();
      await expectLater(session.save(), throwsStateError);
      expect(await db.select(db.warehouseCounts).get(), isEmpty);
      expect(await draftRows(), beforeDraft);
      await reopen();
      final recovered =
          await open() as RecoverableEdit<WarehouseCountEditSession>;
      expect((await recovered.resume()).initial.quantityText, raw);
      expect(await db.select(db.warehouseCounts).get(), isEmpty);
    },
  );

  test(
    'reserved count ID collision preserves the competing count and draft',
    () async {
      final session = await fresh();
      session.replace(input(quantity: '9'));
      await session.flush();
      final reserved = session.countId;
      final otherLocation = await fixture.repo.createLocation(
        id: newId(),
        name: 'Collision location',
      );
      final collision = await fixture.repo.recordCount(
        fixture.draft(
          id: reserved,
          locationId: otherLocation.id,
          quantity: 77,
          note: 'Competing row',
        ),
      );
      final beforeRows = await countRows();
      final beforeDrafts = await draftRows();

      await expectLater(session.save(), throwsStateError);
      expect(await countRows(), beforeRows);
      expect(collision.id, reserved);
      expect(await draftRows(), beforeDrafts);
    },
  );

  test(
    'locked PIN refuses save without changing the draft or count rows',
    () async {
      await pin.setPin('1234');
      final session = await fresh();
      session.replace(input(quantity: '4', note: '  keep this  '));
      await session.flush();
      final beforeDrafts = await draftRows();
      pin.lock();

      await expectLater(session.save(), throwsStateError);
      expect(await db.select(db.warehouseCounts).get(), isEmpty);
      expect(await draftRows(), beforeDrafts);
      await reopen();
      final recovery =
          await open() as RecoverableEdit<WarehouseCountEditSession>;
      final resumed = await recovery.resume();
      expect(resumed.initial.quantityText, '4');
      expect(resumed.initial.noteText, '  keep this  ');
    },
  );

  test(
    'company legacy-write denial preserves input and does not write a count',
    () async {
      final session = await fresh();
      session.replace(
        input(quantity: '5', note: 'Denied write remains editable'),
      );
      await session.flush();
      final beforeDrafts = await draftRows();
      await db.customStatement(
        "INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES ('synthetic-refusal', 1, 'blocked', 'synthetic-marker')",
      );
      final beforeCounts = await countRows();

      await expectLater(session.save(), throwsStateError);
      expect(await countRows(), beforeCounts);
      expect(await draftRows(), beforeDrafts);
    },
  );

  test('stale head cannot be adopted by a later editor session', () async {
    final prior = await fixture.repo.recordCount(fixture.draft(quantity: 2));
    final session = await fresh(prior: prior.id);
    session.replace(input(quantity: '99'));
    await session.flush();
    final concurrent = await fixture.repo.recordCount(
      fixture.draft(prior: prior.id, quantity: 7),
    );
    final beforeRows = await countRows();
    final beforeDrafts = await draftRows();

    await expectLater(session.save(), throwsStateError);
    expect(await countRows(), beforeRows);
    expect(await draftRows(), beforeDrafts);
    expect(
      (await fixture.repo.latestCount(fixture.locationId, fixture.partId))!.id,
      concurrent.id,
    );
    await reopen();
    expect(
      await open(prior: concurrent.id),
      isA<BlockedEdit<WarehouseCountEditSession>>(),
    );
    expect(await countRows(), beforeRows);
  });

  test(
    'changed UOM blocks save and preserves the draft without conversion',
    () async {
      final session = await fresh();
      session.replace(input(quantity: '3'));
      await session.flush();
      final beforeRows = await countRows();
      final beforeDrafts = await draftRows();
      await (db.update(db.parts)..where((row) => row.id.equals(fixture.partId)))
          .write(const PartsCompanion(uom: Value('box')));

      await expectLater(session.save(), throwsStateError);
      expect(await countRows(), beforeRows);
      expect(await draftRows(), beforeDrafts);
      await reopen();
      expect(
        await open(uom: 'ea'),
        isA<BlockedEdit<WarehouseCountEditSession>>(),
      );
    },
  );

  test('removed location blocks save and keeps the raw input', () async {
    final session = await fresh();
    session.replace(input(quantity: '3'));
    await session.flush();
    final beforeCounts = await countRows();
    final beforeDrafts = await draftRows();
    await (db.update(
      db.warehouseLocations,
    )..where((row) => row.id.equals(fixture.locationId))).write(
      WarehouseLocationsCompanion(deletedAt: Value(DateTime.now().toUtc())),
    );

    await expectLater(session.save(), throwsStateError);
    expect(await countRows(), beforeCounts);
    expect(await draftRows(), beforeDrafts);
    await reopen();
    expect(
      await open(location: fixture.locationId),
      isA<BlockedEdit<WarehouseCountEditSession>>(),
    );
  });

  test('removed Part blocks save and preserves unfinished input', () async {
    final session = await fresh();
    session.replace(input(quantity: '3'));
    await session.flush();
    final beforeCounts = await countRows();
    final beforeDrafts = await draftRows();
    await (db.update(db.parts)..where((row) => row.id.equals(fixture.partId)))
        .write(PartsCompanion(deletedAt: Value(DateTime.now().toUtc())));

    await expectLater(session.save(), throwsStateError);
    expect(await countRows(), beforeCounts);
    expect(await draftRows(), beforeDrafts);
    await reopen();
    expect(await open(), isA<BlockedEdit<WarehouseCountEditSession>>());
  });

  test('receipt SQL failure rolls back count insert and input retirement together', () async {
    final session = await fresh();
    session.replace(input(quantity: '12'));
    await session.flush();
    final beforeDrafts = await draftRows();
    await db.customStatement(
      "CREATE TRIGGER reject_warehouse_count_receipt BEFORE UPDATE ON app_settings WHEN NEW.key = '${controlKey()}' AND instr(NEW.value, '\"phase\":\"committed\"') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic warehouse receipt failure'); END",
    );

    await expectLater(
      session.save(),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('synthetic warehouse receipt failure'),
        ),
      ),
    );
    expect(await db.select(db.warehouseCounts).get(), isEmpty);
    expect(await draftRows(), beforeDrafts);
    await reopen();
    final recovery = await open() as RecoverableEdit<WarehouseCountEditSession>;
    expect((await recovery.resume()).initial.quantityText, '12');
    expect(await db.select(db.warehouseCounts).get(), isEmpty);
  });

  test('lost reply resolves the saved count after restart even when a newer head exists', () async {
    final session = await fresh();
    session.replace(input(quantity: '11', note: 'Committed before lost reply'));
    await session.flush();
    final created = await session.save();
    expect(await db.settingsDao.getSetting(inputKey()), isNull);
    expect(await db.settingsDao.getSetting(controlKey()), isNotNull);
    final later = await fixture.repo.recordCount(
      fixture.draft(prior: created.count.id, quantity: 13),
    );
    await reopen();

    final recovered = await open(prior: later.id);
    expect(recovered, isA<WarehouseCountSaved>());
    final receipt = recovered as WarehouseCountSaved;
    expect(receipt.count.id, created.count.id);
    expect(receipt.count.quantity, 11);
    expect(receipt.count.note, 'Committed before lost reply');
    expect((await db.select(db.warehouseCounts).get()).map((row) => row.id), [
      created.count.id,
      later.id,
    ]);
    await receipt.acknowledge();
    expect(await db.settingsDao.getSetting(controlKey()), isNull);
    expect((await db.select(db.warehouseCounts).get()).last.id, later.id);
  });

  test('foreign draft and malformed committed receipt remain blocked and preserved', () async {
    final session = await fresh();
    session.replace(input(quantity: '  8  '));
    await session.flush();
    final before = await draftRows();
    await reopen();
    final foreign = EditDrafts(
      db: db,
      pin: pin,
      deviceId: 'another-synthetic-device',
    );
    final blocked = await foreign.openWarehouseCount(
      locationId: fixture.locationId,
      partId: fixture.partId,
      uom: 'ea',
      expectedPriorCountId: null,
    );
    expect(blocked, isA<BlockedEdit<WarehouseCountEditSession>>());
    expect(await draftRows(), before);
    expect(await db.select(db.warehouseCounts).get(), isEmpty);

    final localRecovery =
        await open() as RecoverableEdit<WarehouseCountEditSession>;
    await localRecovery.discard();
    final localSession = await fresh();
    localSession.replace(input(quantity: '8'));
    await localSession.flush();
    final saved = await localSession.save();
    expect(await db.select(db.warehouseCounts).get(), hasLength(1));

    await (db.update(
      db.warehouseCounts,
    )..where((row) => row.id.equals(saved.count.id))).write(
      const WarehouseCountsCompanion(note: Value('Changed externally')),
    );
    final receiptBefore = await db.settingsDao.getSetting(controlKey());
    await reopen();
    final changedRow = await open();
    expect(changedRow, isA<BlockedEdit<WarehouseCountEditSession>>());
    expect(
      (changedRow as BlockedEdit<WarehouseCountEditSession>).preservedInput,
      receiptBefore,
    );
    expect(await db.settingsDao.getSetting(controlKey()), receiptBefore);
    expect(
      (await db.select(db.warehouseCounts).get()).single.note,
      'Changed externally',
    );

    await db.settingsDao.setSetting(controlKey(), '{malformed');
    await reopen();
    final malformed = await open();
    expect(malformed, isA<BlockedEdit<WarehouseCountEditSession>>());
    expect(
      (malformed as BlockedEdit<WarehouseCountEditSession>).preservedInput,
      '{malformed',
    );
    expect(await db.settingsDao.getSetting(controlKey()), '{malformed');
    expect(
      (await db.select(db.warehouseCounts).get()).single.id,
      saved.count.id,
    );
  });

  test(
    'acknowledgement refuses a replaced receipt without changing count rows',
    () async {
      final session = await fresh();
      session.replace(input(quantity: '6'));
      await session.flush();
      final saved = await session.save();
      final beforeRows = await countRows();
      const replacement = '{"phase":"editing","token":"replacement"}';
      await db.settingsDao.setSetting(controlKey(), replacement);

      await expectLater(saved.acknowledge(), throwsStateError);
      expect(await db.settingsDao.getSetting(controlKey()), replacement);
      expect(await countRows(), beforeRows);
    },
  );
}
