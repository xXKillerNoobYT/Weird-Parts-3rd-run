import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/warehouse/warehouse_integrity.dart';
import 'package:wired_parts/features/warehouse/warehouse_repository.dart';

import '../warehouse/warehouse_test_support.dart';

void main() {
  late Directory directory;
  late File file;
  late WarehouseFixture fixture;
  late AppDatabase db;
  late String device;
  late PinService pin;
  late EditDrafts edits;

  const createSlot = 'warehouse-location-new';
  String renameSlot(String id) =>
      'warehouse-location-rename/${Uri.encodeComponent(id)}';
  String inputKey(String slot) => 'local_edit_v1/$slot/input';
  String controlKey(String slot) => 'local_edit_v1/$slot/control';

  void bind() {
    pin = PinService(db.settingsDao);
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
  }

  Future<void> reopen() async {
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
  }

  WarehouseRepository repository() => WarehouseRepository(db, pin, device);
  Future<List<WarehouseLocation>> locations() => repository().loadLocations();
  Future<List<WarehouseLocation>> locationRows() =>
      db.select(db.warehouseLocations).get();
  Future<List<WarehouseCount>> countRows() =>
      db.select(db.warehouseCounts).get();

  Future<List<Map<String, Object?>>> draftRows() async =>
      (await db
              .customSelect(
                "SELECT key, value FROM app_settings "
                "WHERE key LIKE 'local_edit_v1/warehouse-location-%' "
                'ORDER BY key',
              )
              .get())
          .map((row) => row.data)
          .toList();

  Future<EditOpening<WarehouseLocationEditSession>> openCreate() =>
      edits.openNewWarehouseLocation();

  Future<EditOpening<WarehouseLocationEditSession>> openRename({
    String? id,
    int? revision,
  }) async {
    final location = (await locationRows()).firstWhere(
      (row) => row.id == (id ?? fixture.locationId),
    );
    return edits.openWarehouseLocationRename(
      locationId: id ?? location.id,
      expectedRevision: revision ?? location.revision,
    );
  }

  Future<WarehouseLocationEditSession> fresh({bool rename = false}) async {
    final opening = rename ? await openRename() : await openCreate();
    expect(opening, isA<FreshEdit<WarehouseLocationEditSession>>());
    return (opening as FreshEdit<WarehouseLocationEditSession>).session;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'warehouse-location-draft-core-',
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
    'raw create name survives file reopen without a placeholder location',
    () async {
      const raw = '  North bay · pending\nsecond line  ';
      final session = await fresh();
      expect(session.isRename, isFalse);
      final reservedId = session.locationId;
      session.replace(const WarehouseLocationNameInput(nameText: raw));
      await session.flush();
      expect((await locations()).map((row) => row.name), ['Shop shelf']);

      await reopen();
      final opening = await openCreate();
      expect(opening, isA<RecoverableEdit<WarehouseLocationEditSession>>());
      final resumed =
          await (opening as RecoverableEdit<WarehouseLocationEditSession>)
              .resume();
      expect(resumed.locationId, reservedId);
      expect(resumed.initial.nameText, raw);
      expect((await locations()).map((row) => row.name), ['Shop shelf']);
    },
  );

  test('create trims once, retries its reserved identity, and acknowledges exactly', () async {
    final session = await fresh();
    final reservedId = session.locationId;
    session.replace(
      const WarehouseLocationNameInput(nameText: '  North bay  '),
    );
    await session.flush();

    final saved = await session.save();
    expect(saved.location.id, reservedId);
    expect(saved.location.name, 'North bay');
    expect((await session.save()).location.id, reservedId);
    expect(
      (await locations()).where((row) => row.id == reservedId),
      hasLength(1),
    );
    await saved.acknowledge();
    expect(await db.settingsDao.getSetting(inputKey(createSlot)), isNull);
    expect(await db.settingsDao.getSetting(controlKey(createSlot)), isNull);
    expect((await locations()).map((row) => row.name), [
      'North bay',
      'Shop shelf',
    ]);
  });

  test('rename preserves ID and creator, increments revision, and retains count history', () async {
    final original = (await locations()).single;
    final count = await repository().recordCount(fixture.draft(quantity: 6.25));
    await (db.update(
      db.warehouseLocations,
    )..where((row) => row.id.equals(original.id))).write(
      const WarehouseLocationsCompanion(
        originDeviceId: Value('synthetic-original-device'),
      ),
    );
    final beforeCounts = await countRows();
    final session = await fresh(rename: true);
    expect(session.isRename, isTrue);
    expect(session.locationId, original.id);
    session.replace(const WarehouseLocationNameInput(nameText: '  Rack A  '));
    await session.flush();

    final saved = await session.save();
    expect(saved.location.id, original.id);
    expect(saved.location.originDeviceId, 'synthetic-original-device');
    expect(saved.location.name, 'Rack A');
    expect(saved.location.revision, original.revision + 1);
    expect(await countRows(), beforeCounts);
    expect(
      (await repository().loadCountHistory(
        original.id,
        fixture.partId,
      )).single.id,
      count.id,
    );
    await saved.acknowledge();
  });

  test('counting permits rename and rename preserves a stale count draft', () async {
    final rename = await fresh(rename: true);
    rename.replace(const WarehouseLocationNameInput(nameText: 'Renamed shelf'));
    await rename.flush();
    final prior = await repository().recordCount(fixture.draft(quantity: 6));
    final count = (await edits.openWarehouseCount(
      locationId: fixture.locationId,
      partId: fixture.partId,
      uom: 'ea',
      expectedPriorCountId: prior.id,
    ) as FreshEdit<WarehouseCountEditSession>).session;
    count.replace(
      WarehouseCountInput(
        quantityText: ' 9.. ',
        noteText: '  preserve this count  ',
        observedAt: DateTime.utc(2026, 10, 21),
      ),
    );
    await count.flush();
    final countKey =
        'local_edit_v1/warehouse-count/${Uri.encodeComponent(fixture.locationId)}/${Uri.encodeComponent(fixture.partId)}/input';
    final raw = await db.settingsDao.getSetting(countKey);
    final beforeCounts = await countRows();
    final saved = await rename.save();
    expect(saved.location.name, 'Renamed shelf');
    await saved.acknowledge();
    await expectLater(count.save(), throwsStateError);
    expect(await countRows(), beforeCounts);
    expect(await db.settingsDao.getSetting(countKey), raw);
    await reopen();
    final opening = await edits.openWarehouseCount(
      locationId: fixture.locationId,
      partId: fixture.partId,
      uom: 'ea',
      expectedPriorCountId: prior.id,
    );
    expect(opening, isA<BlockedEdit<WarehouseCountEditSession>>());
    expect(
      (opening as BlockedEdit<WarehouseCountEditSession>).preservedInput,
      raw,
    );
    expect(await countRows(), beforeCounts);
  });

  test('rename to the current name is a no-op on revision and rows', () async {
    final original = (await locations()).single;
    final before = await locationRows();
    final session = await fresh(rename: true);
    session.replace(
      const WarehouseLocationNameInput(nameText: '  Shop shelf  '),
    );
    await session.flush();

    final saved = await session.save();
    expect(saved.location.id, original.id);
    expect(saved.location.name, original.name);
    expect(saved.location.revision, original.revision);
    expect(await locationRows(), before);
    await saved.acknowledge();
  });

  test(
    'multiline domain name remains raw until Save trims only the ends',
    () async {
      const raw = '  north\nbay · exact  ';
      final session = await fresh();
      session.replace(const WarehouseLocationNameInput(nameText: raw));
      await session.flush();
      await reopen();

      final recovered =
          await openCreate() as RecoverableEdit<WarehouseLocationEditSession>;
      final resumed = await recovered.resume();
      expect(resumed.initial.nameText, raw);
      final saved = await resumed.save();
      expect(saved.location.name, 'north\nbay · exact');
      expect((await locations()).map((row) => row.name), [
        'north\nbay · exact',
        'Shop shelf',
      ]);
    },
  );

  test('whitespace-only create and rename preserve exact input without business changes', () async {
    for (final rename in [false, true]) {
      final session = await fresh(rename: rename);
      const raw = ' \n\t  ';
      session.replace(const WarehouseLocationNameInput(nameText: raw));
      await session.flush();
      final beforeLocations = await locationRows();
      final beforeDrafts = await draftRows();

      await expectLater(session.save(), throwsStateError);
      expect(await locationRows(), beforeLocations);
      expect(await draftRows(), beforeDrafts);
    }
  });

  test('normalized duplicate name refuses create and rename while preserving drafts', () async {
    await repository().createLocation(id: newId(), name: 'Truck shelf');
    for (final rename in [false, true]) {
      final session = await fresh(rename: rename);
      session.replace(
        const WarehouseLocationNameInput(nameText: '  TRUCK SHELF  '),
      );
      await session.flush();
      final beforeLocations = await locationRows();
      final beforeDrafts = await draftRows();

      await expectLater(session.save(), throwsStateError);
      expect(await locationRows(), beforeLocations);
      expect(await draftRows(), beforeDrafts);
    }
  });

  test(
    'locked PIN refuses create and rename without changing drafts or locations',
    () async {
      await pin.setPin('1234');
      for (final rename in [false, true]) {
        final session = await fresh(rename: rename);
        session.replace(
          const WarehouseLocationNameInput(nameText: 'PIN blocked'),
        );
        await session.flush();
        final beforeLocations = await locationRows();
        final beforeDrafts = await draftRows();
        pin.lock();

        await expectLater(session.save(), throwsStateError);
        expect(await locationRows(), beforeLocations);
        expect(await draftRows(), beforeDrafts);
        await pin.unlock('1234');
      }
    },
  );

  test('company legacy-write marker refuses create and rename without changing drafts', () async {
    final sessions = [await fresh(), await fresh(rename: true)];
    for (final session in sessions) {
      session.replace(
        const WarehouseLocationNameInput(nameText: 'Company blocked'),
      );
      await session.flush();
    }
    final beforeDrafts = await draftRows();
    final beforeLocations = await locationRows();
    await db.customStatement(
      'INSERT INTO company_join_events '
      '(request_id, ordinal, kind, evidence_bytes) '
      "VALUES ('synthetic-location-refusal', 1, 'blocked', 'synthetic-marker')",
    );

    for (final session in sessions) {
      await expectLater(session.save(), throwsStateError);
    }
    expect(await locationRows(), beforeLocations);
    expect(await draftRows(), beforeDrafts);
  });

  test(
    'stale rename revision refuses save and preserves unfinished input',
    () async {
      final original = (await locations()).single;
      final session = await fresh(rename: true);
      session.replace(
        const WarehouseLocationNameInput(nameText: 'Stale rename'),
      );
      await session.flush();
      await repository().renameLocation(
        id: original.id,
        expectedRevision: original.revision,
        name: 'Concurrent rename',
      );
      final beforeLocations = await locationRows();
      final beforeDrafts = await draftRows();

      await expectLater(session.save(), throwsStateError);
      expect(await locationRows(), beforeLocations);
      expect(await draftRows(), beforeDrafts);
      await reopen();
      expect(
        await openRename(id: original.id, revision: original.revision),
        isA<BlockedEdit<WarehouseLocationEditSession>>(),
      );
      expect((await locations()).single.name, 'Concurrent rename');
    },
  );

  test('deleted location blocks rename and retains raw input', () async {
    final original = (await locations()).single;
    final session = await fresh(rename: true);
    session.replace(const WarehouseLocationNameInput(nameText: 'Resurrect?'));
    await session.flush();
    await (db.update(
      db.warehouseLocations,
    )..where((row) => row.id.equals(original.id))).write(
      WarehouseLocationsCompanion(deletedAt: Value(DateTime.utc(2026, 10, 21))),
    );
    final beforeLocations = await locationRows();
    final beforeDrafts = await draftRows();

    await expectLater(session.save(), throwsStateError);
    expect(await locationRows(), beforeLocations);
    expect(await draftRows(), beforeDrafts);
    await reopen();
    expect(
      await openRename(id: original.id),
      isA<BlockedEdit<WarehouseLocationEditSession>>(),
    );
  });

  test(
    'reserved create ID collision preserves the competing row and draft',
    () async {
      final session = await fresh();
      session.replace(
        const WarehouseLocationNameInput(nameText: 'Collision draft'),
      );
      await session.flush();
      final now = DateTime.utc(2026, 10, 21);
      await db
          .into(db.warehouseLocations)
          .insert(
            WarehouseLocationsCompanion.insert(
              id: session.locationId,
              originDeviceId: 'synthetic-competing-device',
              createdAt: now,
              modifiedAt: now,
              name: 'Competing location',
              nameKey: warehouseNameKey('Competing location'),
            ),
          );
      final beforeLocations = await locationRows();
      final beforeDrafts = await draftRows();

      await expectLater(session.save(), throwsStateError);
      expect(await locationRows(), beforeLocations);
      expect(await draftRows(), beforeDrafts);
      expect(
        (await locationRows())
            .singleWhere((row) => row.id == session.locationId)
            .name,
        'Competing location',
      );
    },
  );

  test('receipt SQL failure rolls back both create and rename with their drafts', () async {
    final create = await fresh();
    create.replace(
      const WarehouseLocationNameInput(nameText: 'Receipt failure create'),
    );
    await create.flush();
    final rename = await fresh(rename: true);
    rename.replace(
      const WarehouseLocationNameInput(nameText: 'Receipt failure rename'),
    );
    await rename.flush();

    for (final session in [create, rename]) {
      final slot = session.isRename
          ? renameSlot(session.locationId)
          : createSlot;
      final beforeLocations = await locationRows();
      final beforeDrafts = await draftRows();
      final key = controlKey(slot).replaceAll("'", "''");
      await db.customStatement(
        'CREATE TRIGGER reject_location_receipt BEFORE UPDATE ON app_settings '
        "WHEN NEW.key = '$key' AND instr(NEW.value, '"
        '"phase":"committed"'
        "') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic location receipt failure'); END",
      );

      await expectLater(
        session.save(),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('synthetic location receipt failure'),
          ),
        ),
      );
      expect(await locationRows(), beforeLocations);
      expect(await draftRows(), beforeDrafts);
      await db.customStatement('DROP TRIGGER reject_location_receipt');
    }
  });

  test('unacknowledged create and rename receipts survive reopen and acknowledge exact rows', () async {
    final create = await fresh();
    create.replace(
      const WarehouseLocationNameInput(nameText: 'Receipt create'),
    );
    await create.flush();
    final created = await create.save();
    final rename = await fresh(rename: true);
    rename.replace(
      const WarehouseLocationNameInput(nameText: 'Receipt rename'),
    );
    await rename.flush();
    final renamed = await rename.save();
    final createdId = created.location.id;
    final renamedId = renamed.location.id;
    final before = await locationRows();

    await reopen();
    final createOpening = await openCreate();
    expect(createOpening, isA<WarehouseLocationSaved>());
    final recoveredCreate = createOpening as WarehouseLocationSaved;
    expect(recoveredCreate.location.id, createdId);
    final renameOpening = await openRename(id: renamedId);
    expect(renameOpening, isA<WarehouseLocationSaved>());
    final recoveredRename = renameOpening as WarehouseLocationSaved;
    expect(recoveredRename.location.id, renamedId);
    expect(await locationRows(), before);

    await recoveredCreate.acknowledge();
    await recoveredRename.acknowledge();
    expect(await db.settingsDao.getSetting(controlKey(createSlot)), isNull);
    expect(
      await db.settingsDao.getSetting(controlKey(renameSlot(renamedId))),
      isNull,
    );
    expect(await locationRows(), before);
  });

  test(
    'changed saved location blocks receipt and preserves its evidence',
    () async {
      final session = await fresh();
      session.replace(
        const WarehouseLocationNameInput(nameText: 'Receipt changed row'),
      );
      await session.flush();
      final saved = await session.save();
      final receiptKey = controlKey(createSlot);
      final receipt = await db.settingsDao.getSetting(receiptKey);
      await repository().renameLocation(
        id: saved.location.id,
        expectedRevision: saved.location.revision,
        name: 'Externally changed',
      );
      await reopen();

      final blocked = await openCreate();
      expect(blocked, isA<BlockedEdit<WarehouseLocationEditSession>>());
      expect(
        (blocked as BlockedEdit<WarehouseLocationEditSession>).preservedInput,
        receipt,
      );
      expect(await db.settingsDao.getSetting(receiptKey), receipt);
      expect(
        (await locationRows())
            .singleWhere((row) => row.id == saved.location.id)
            .name,
        'Externally changed',
      );
    },
  );

  test(
    'acknowledgement refuses a replaced receipt without changing the row',
    () async {
      final session = await fresh();
      session.replace(
        const WarehouseLocationNameInput(
          nameText: 'Ack exact location receipt',
        ),
      );
      await session.flush();
      final saved = await session.save();
      final beforeLocations = await locationRows();
      const replacement = '{"phase":"editing","token":"replacement"}';
      await db.settingsDao.setSetting(controlKey(createSlot), replacement);

      await expectLater(saved.acknowledge(), throwsStateError);
      expect(
        await db.settingsDao.getSetting(controlKey(createSlot)),
        replacement,
      );
      expect(await locationRows(), beforeLocations);
    },
  );

  test(
    'foreign draft and unsupported version stay blocked and preserved',
    () async {
      final session = await fresh();
      session.replace(
        const WarehouseLocationNameInput(nameText: 'Foreign draft'),
      );
      await session.flush();
      final beforeDrafts = await draftRows();
      await reopen();
      final foreign = EditDrafts(
        db: db,
        pin: pin,
        deviceId: 'synthetic-other-device',
      );
      expect(
        await foreign.openNewWarehouseLocation(),
        isA<BlockedEdit<WarehouseLocationEditSession>>(),
      );
      expect(await draftRows(), beforeDrafts);
      expect((await locations()).map((row) => row.name), ['Shop shelf']);

      final raw = (await db.settingsDao.getSetting(inputKey(createSlot)))!;
      final malformed = Map<String, Object?>.from(jsonDecode(raw) as Map)
        ..['v'] = 999;
      final malformedRaw = jsonEncode(malformed);
      await db.settingsDao.setSetting(inputKey(createSlot), malformedRaw);
      await reopen();
      final blocked = await openCreate();
      expect(blocked, isA<BlockedEdit<WarehouseLocationEditSession>>());
      expect(
        (blocked as BlockedEdit<WarehouseLocationEditSession>).preservedInput,
        malformedRaw,
      );
      expect(
        await db.settingsDao.getSetting(inputKey(createSlot)),
        malformedRaw,
      );
      expect((await locations()).map((row) => row.name), ['Shop shelf']);
    },
  );

  test(
    'create and rename drafts occupy independent recoverable slots',
    () async {
      final create = await fresh();
      final rename = await fresh(rename: true);
      create.replace(
        const WarehouseLocationNameInput(nameText: 'Independent create'),
      );
      rename.replace(
        const WarehouseLocationNameInput(nameText: 'Independent rename'),
      );
      await create.flush();
      await rename.flush();
      final beforeLocations = await locationRows();
      expect(await draftRows(), hasLength(4));

      await reopen();
      final recoveredCreate =
          await openCreate() as RecoverableEdit<WarehouseLocationEditSession>;
      final recoveredRename =
          await openRename() as RecoverableEdit<WarehouseLocationEditSession>;
      expect(
        (await recoveredCreate.resume()).initial.nameText,
        'Independent create',
      );
      expect(
        (await recoveredRename.resume()).initial.nameText,
        'Independent rename',
      );
      expect(await locationRows(), beforeLocations);
    },
  );
}
