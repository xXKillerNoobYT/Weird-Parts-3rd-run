import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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

  Future<List<Map<String, Object?>>> taxonomyRows() async => [
    for (final row in await db.select(db.categories).get())
      {
        'kind': 'category',
        'id': row.id,
        'parent': null,
        'name': row.name,
        'origin': row.originDeviceId,
        'revision': row.revision,
        'deleted': row.deletedAt?.toIso8601String(),
      },
    for (final row in await db.select(db.styles).get())
      {
        'kind': 'type',
        'id': row.id,
        'parent': row.categoryId,
        'name': row.name,
        'origin': row.originDeviceId,
        'revision': row.revision,
        'deleted': row.deletedAt?.toIso8601String(),
      },
    for (final row in await db.select(db.types).get())
      {
        'kind': 'variant',
        'id': row.id,
        'parent': row.styleId,
        'name': row.name,
        'origin': row.originDeviceId,
        'revision': row.revision,
        'deleted': row.deletedAt?.toIso8601String(),
      },
  ];

  Future<List<Map<String, Object?>>> draftRows() async =>
      (await db
              .customSelect(
                "SELECT key, value FROM app_settings "
                "WHERE key LIKE 'local_edit_v1/catalog-name-%' ORDER BY key",
              )
              .get())
          .map((row) => row.data)
          .toList();

  Future<List<String>> names(CatalogNameKind kind, String? parent) async {
    switch (kind) {
      case CatalogNameKind.category:
        return (await db.taxonomyDao.listCategories())
            .map((r) => r.name)
            .toList();
      case CatalogNameKind.type:
        return (await db.taxonomyDao.listStyles(categoryId: parent))
            .map((r) => r.name)
            .toList();
      case CatalogNameKind.variant:
        return (await db.taxonomyDao.listTypes(styleId: parent))
            .map((r) => r.name)
            .toList();
    }
  }

  String createSlot(CatalogNameKind kind, String? parent) =>
      'catalog-name-new/${kind.name}${parent == null ? '' : '/${Uri.encodeComponent(parent)}'}';

  String renameSlot(CatalogNameKind kind, String id) =>
      'catalog-name-rename/${kind.name}/${Uri.encodeComponent(id)}';

  String inputKey(String slot) => 'local_edit_v1/$slot/input';
  String controlKey(String slot) => 'local_edit_v1/$slot/control';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('catalog-name-draft-');
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

  test('raw input for all six operations resumes after file reopen without business writes', () async {
    final category = (await db.select(db.categories).get()).single;
    final type = (await db.select(db.styles).get()).single;
    final variant = (await db.select(db.types).get()).single;
    final cases = [
      (
        target: const CatalogNameTarget.newCategory(),
        kind: CatalogNameKind.category,
        rename: false,
        id: null,
        raw: '  New category\npending · exact  ',
      ),
      (
        target: CatalogNameTarget.newType(category.id),
        kind: CatalogNameKind.type,
        rename: false,
        id: null,
        raw: '  New type\npending · exact  ',
      ),
      (
        target: CatalogNameTarget.newVariant(type.id),
        kind: CatalogNameKind.variant,
        rename: false,
        id: null,
        raw: '  New variant\npending · exact  ',
      ),
      (
        target: CatalogNameTarget.renameCategory(category.id),
        kind: CatalogNameKind.category,
        rename: true,
        id: category.id,
        raw: '  Rename category\npending · exact  ',
      ),
      (
        target: CatalogNameTarget.renameType(type.id),
        kind: CatalogNameKind.type,
        rename: true,
        id: type.id,
        raw: '  Rename type\npending · exact  ',
      ),
      (
        target: CatalogNameTarget.renameVariant(variant.id),
        kind: CatalogNameKind.variant,
        rename: true,
        id: variant.id,
        raw: '  Rename variant\npending · exact  ',
      ),
    ];
    final before = await taxonomyRows();
    final reservedIds = <String>[];
    for (final c in cases) {
      final opening = await edits.openCatalogName(c.target);
      expect(
        opening,
        isA<FreshEdit<CatalogNameEditSession>>(),
        reason: '${c.kind} rename=${c.rename}',
      );
      final session = (opening as FreshEdit<CatalogNameEditSession>).session;
      expect(session.kind, c.kind);
      expect(session.isRename, c.rename);
      if (c.id != null) expect(session.recordId, c.id);
      session.replace(CatalogNameInput(nameText: c.raw));
      await session.flush();
      reservedIds.add(session.recordId);
    }
    expect(await taxonomyRows(), before);

    await reopen();
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final opening = await edits.openCatalogName(c.target);
      expect(
        opening,
        isA<RecoverableEdit<CatalogNameEditSession>>(),
        reason: '${c.kind} rename=${c.rename}',
      );
      final resumed = await (opening as RecoverableEdit<CatalogNameEditSession>)
          .resume();
      expect(resumed.recordId, reservedIds[i]);
      expect(resumed.initial.nameText, c.raw);
      expect(resumed.kind, c.kind);
      expect(resumed.isRename, c.rename);
    }
    expect(await taxonomyRows(), before);
  });

  test('create trims names, permits existing duplicates, retries one identity, and acknowledges its receipt', () async {
    final category = (await db.select(db.categories).get()).single;
    final type = (await db.select(db.styles).get()).single;
    final variant = (await db.select(db.types).get()).single;
    final cases = [
      (
        target: const CatalogNameTarget.newCategory(),
        kind: CatalogNameKind.category,
        parent: null,
        duplicate: category.name,
      ),
      (
        target: CatalogNameTarget.newType(category.id),
        kind: CatalogNameKind.type,
        parent: category.id,
        duplicate: type.name,
      ),
      (
        target: CatalogNameTarget.newVariant(type.id),
        kind: CatalogNameKind.variant,
        parent: type.id,
        duplicate: variant.name,
      ),
    ];
    for (final c in cases) {
      final opening = await edits.openCatalogName(c.target);
      final session = (opening as FreshEdit<CatalogNameEditSession>).session;
      final reserved = session.recordId;
      session.replace(CatalogNameInput(nameText: '  ${c.duplicate}  '));
      await session.flush();
      expect(await names(c.kind, c.parent), [c.duplicate]);

      final saved = await session.save();
      expect(saved.kind, c.kind);
      expect(saved.id, reserved);
      expect(saved.name, c.duplicate);
      expect(await names(c.kind, c.parent), [c.duplicate, c.duplicate]);
      expect((await session.save()).id, reserved);
      expect(await names(c.kind, c.parent), [c.duplicate, c.duplicate]);

      final slot = createSlot(c.kind, c.parent);
      await reopen();
      final recovered = await edits.openCatalogName(c.target);
      expect(recovered, isA<CatalogNameSaved>());
      final receipt = recovered as CatalogNameSaved;
      expect(
        (receipt.kind, receipt.id, receipt.name),
        (c.kind, reserved, c.duplicate),
      );
      await receipt.acknowledge();
      expect(await db.settingsDao.getSetting(inputKey(slot)), isNull);
      expect(await db.settingsDao.getSetting(controlKey(slot)), isNull);
      expect(await names(c.kind, c.parent), [c.duplicate, c.duplicate]);
    }
  });

  test('rename keeps stable identity and original creator while applying one revision', () async {
    final category = (await db.select(db.categories).get()).single;
    final type = (await db.select(db.styles).get()).single;
    final variant = (await db.select(db.types).get()).single;
    await db.customStatement(
      'UPDATE categories SET origin_device_id = ? WHERE id = ?',
      ['synthetic-original-category-device', category.id],
    );
    await db.customStatement(
      'UPDATE styles SET origin_device_id = ? WHERE id = ?',
      ['synthetic-original-type-device', type.id],
    );
    await db.customStatement(
      'UPDATE types SET origin_device_id = ? WHERE id = ?',
      ['synthetic-original-variant-device', variant.id],
    );
    final cases = [
      (
        target: CatalogNameTarget.renameCategory(category.id),
        kind: CatalogNameKind.category,
        id: category.id,
        originalName: category.name,
        origin: 'synthetic-original-category-device',
      ),
      (
        target: CatalogNameTarget.renameType(type.id),
        kind: CatalogNameKind.type,
        id: type.id,
        originalName: type.name,
        origin: 'synthetic-original-type-device',
      ),
      (
        target: CatalogNameTarget.renameVariant(variant.id),
        kind: CatalogNameKind.variant,
        id: variant.id,
        originalName: variant.name,
        origin: 'synthetic-original-variant-device',
      ),
    ];
    for (final c in cases) {
      final beforeRows = await taxonomyRows();
      final before = beforeRows.singleWhere((row) => row['id'] == c.id);
      final opening = await edits.openCatalogName(c.target);
      final session = (opening as FreshEdit<CatalogNameEditSession>).session;
      expect(session.recordId, c.id);
      expect(session.initial.nameText, c.originalName);
      session.replace(CatalogNameInput(nameText: '  Renamed ${c.kind.name}  '));
      await session.flush();

      final saved = await session.save();
      expect(
        (saved.kind, saved.id, saved.name),
        (c.kind, c.id, 'Renamed ${c.kind.name}'),
      );
      expect((await session.save()).id, c.id);
      final after = (await taxonomyRows()).singleWhere(
        (row) => row['id'] == c.id,
      );
      expect(after['name'], 'Renamed ${c.kind.name}');
      expect(after['origin'], c.origin);
      expect(after['revision'], (before['revision'] as int) + 1);
      expect((await taxonomyRows()).length, beforeRows.length);
      await reopen();
      final recovered = await edits.openCatalogName(c.target);
      expect(recovered, isA<CatalogNameSaved>());
      final receipt = recovered as CatalogNameSaved;
      expect(
        (receipt.kind, receipt.id, receipt.name),
        (c.kind, c.id, 'Renamed ${c.kind.name}'),
      );
      await receipt.acknowledge();
      expect(
        await db.settingsDao.getSetting(controlKey(renameSlot(c.kind, c.id))),
        isNull,
      );
    }
  });

  test(
    'rename to the existing trimmed name keeps the DAO revision behavior',
    () async {
      final category = (await db.select(db.categories).get()).single;
      final session = (await edits.openCatalogName(
        CatalogNameTarget.renameCategory(category.id),
      ) as FreshEdit<CatalogNameEditSession>).session;
      session.replace(CatalogNameInput(nameText: '  ${category.name}  '));
      await session.flush();

      final saved = await session.save();
      final after = (await db.select(db.categories).get()).single;
      expect(saved.id, category.id);
      expect(saved.name, category.name);
      expect(after.revision, category.revision + 1);
      await saved.acknowledge();
    },
  );

  test('blank names, locked PIN, and company refusal preserve exact drafts and taxonomy', () async {
    final type = (await db.select(db.styles).get()).single;
    final blank = (await edits.openCatalogName(
      const CatalogNameTarget.newCategory(),
    ) as FreshEdit<CatalogNameEditSession>).session;
    blank.replace(const CatalogNameInput(nameText: ' \n\t '));
    await blank.flush();
    final beforeBlankRows = await taxonomyRows();
    final beforeBlankDrafts = await draftRows();
    await expectLater(blank.save(), throwsStateError);
    expect(await taxonomyRows(), beforeBlankRows);
    expect(await draftRows(), beforeBlankDrafts);
    await blank.leave(LeaveIntent.discard);

    final create = (await edits.openCatalogName(
      const CatalogNameTarget.newCategory(),
    ) as FreshEdit<CatalogNameEditSession>).session;
    final rename = (await edits.openCatalogName(
      CatalogNameTarget.renameType(type.id),
    ) as FreshEdit<CatalogNameEditSession>).session;
    create.replace(const CatalogNameInput(nameText: '  PIN blocked create  '));
    rename.replace(const CatalogNameInput(nameText: '  PIN blocked rename  '));
    await create.flush();
    await rename.flush();
    final beforePinRows = await taxonomyRows();
    final beforePinDrafts = await draftRows();
    await pin.setPin('1234');
    pin.lock();
    await expectLater(create.save(), throwsStateError);
    await expectLater(rename.save(), throwsStateError);
    expect(await taxonomyRows(), beforePinRows);
    expect(await draftRows(), beforePinDrafts);
    await pin.unlock('1234');

    await db.customStatement(
      'INSERT INTO company_join_events '
      '(request_id, ordinal, kind, evidence_bytes) '
      "VALUES ('synthetic-catalog-refusal', 1, 'blocked', 'synthetic-marker')",
    );
    final beforeCompanyRows = await taxonomyRows();
    final beforeCompanyDrafts = await draftRows();
    await expectLater(create.save(), throwsStateError);
    await expectLater(rename.save(), throwsStateError);
    expect(await taxonomyRows(), beforeCompanyRows);
    expect(await draftRows(), beforeCompanyDrafts);
    expect(
      (await db.select(db.categories).get()).any(
        (r) => r.name == 'PIN blocked create',
      ),
      isFalse,
    );
    expect((await db.select(db.styles).get()).single.name, type.name);
  });

  test('reserved ID collision and deleted rename target preserve competing business data and drafts', () async {
    final category = (await db.select(db.categories).get()).single;
    final variant = (await db.select(db.types).get()).single;
    final create = (await edits.openCatalogName(
      const CatalogNameTarget.newCategory(),
    ) as FreshEdit<CatalogNameEditSession>).session;
    create.replace(const CatalogNameInput(nameText: '  collided create  '));
    await create.flush();
    final reservedId = create.recordId;
    await db.taxonomyDao.insertCategory(
      id: reservedId,
      name: 'Competing category',
      deviceId: 'synthetic-competing-device',
    );
    final beforeCollisionRows = await taxonomyRows();
    final beforeCollisionDrafts = await draftRows();
    await expectLater(create.save(), throwsStateError);
    expect(await taxonomyRows(), beforeCollisionRows);
    expect(await draftRows(), beforeCollisionDrafts);
    expect(
      (await db.select(db.categories).get())
          .singleWhere((row) => row.id == reservedId)
          .name,
      'Competing category',
    );
    await create.leave(LeaveIntent.discard);

    final rename = (await edits.openCatalogName(
      CatalogNameTarget.renameVariant(variant.id),
    ) as FreshEdit<CatalogNameEditSession>).session;
    rename.replace(const CatalogNameInput(nameText: '  deleted target  '));
    await rename.flush();
    await db.taxonomyDao.softDeleteType(variant.id);
    final beforeDeletedRows = await taxonomyRows();
    final beforeDeletedDrafts = await draftRows();
    await expectLater(rename.save(), throwsStateError);
    expect(await taxonomyRows(), beforeDeletedRows);
    expect(await draftRows(), beforeDeletedDrafts);
    await reopen();
    final blocked = await edits.openCatalogName(
      CatalogNameTarget.renameVariant(variant.id),
    );
    expect(blocked, isA<BlockedEdit<CatalogNameEditSession>>());
    expect(await taxonomyRows(), beforeDeletedRows);
    expect(await db.select(db.categories).get(), hasLength(2));
    expect(
      (await db.select(db.categories).get())
          .singleWhere((row) => row.id == category.id)
          .name,
      category.name,
    );
  });

  test('changed ancestor blocks pending child create and stale rename without losing raw text', () async {
    final category = (await db.select(db.categories).get()).single;
    final type = (await db.select(db.styles).get()).single;
    final staleRename = (await edits.openCatalogName(
      CatalogNameTarget.renameVariant(
        (await db.select(db.types).get()).single.id,
      ),
    ) as FreshEdit<CatalogNameEditSession>).session;
    staleRename.replace(const CatalogNameInput(nameText: '  stale variant  '));
    await staleRename.flush();
    final childCreate = (await edits.openCatalogName(
      CatalogNameTarget.newVariant(type.id),
    ) as FreshEdit<CatalogNameEditSession>).session;
    childCreate.replace(
      const CatalogNameInput(nameText: '  child under old type  '),
    );
    await childCreate.flush();

    await db.taxonomyDao.renameCategory(
      category.id,
      'Concurrent category change',
    );
    final beforeRows = await taxonomyRows();
    final beforeDrafts = await draftRows();
    await expectLater(staleRename.save(), throwsStateError);
    await expectLater(childCreate.save(), throwsStateError);
    expect(await taxonomyRows(), beforeRows);
    expect(await draftRows(), beforeDrafts);

    await reopen();
    final blockedRename = await edits.openCatalogName(
      staleRename.isRename
          ? CatalogNameTarget.renameVariant(staleRename.recordId)
          : CatalogNameTarget.renameCategory(category.id),
    );
    expect(blockedRename, isA<BlockedEdit<CatalogNameEditSession>>());
    final blockedCreate = await edits.openCatalogName(
      CatalogNameTarget.newVariant(type.id),
    );
    expect(blockedCreate, isA<BlockedEdit<CatalogNameEditSession>>());
    expect(await taxonomyRows(), beforeRows);

    final otherCategory = await db.taxonomyDao.insertCategory(
      id: 'synthetic-reparent-category',
      name: 'Reparent destination',
      deviceId: device,
    );
    final reparentedType = (await db.select(db.styles).get()).single;
    final reparent = (await edits.openCatalogName(
      CatalogNameTarget.renameType(reparentedType.id),
    ) as FreshEdit<CatalogNameEditSession>).session;
    reparent.replace(
      const CatalogNameInput(nameText: '  renamed after reparent  '),
    );
    await reparent.flush();
    await db.customStatement('UPDATE styles SET category_id = ? WHERE id = ?', [
      otherCategory,
      reparentedType.id,
    ]);
    final beforeReparentRows = await taxonomyRows();
    final beforeReparentDrafts = await draftRows();
    await expectLater(reparent.save(), throwsStateError);
    expect(await taxonomyRows(), beforeReparentRows);
    expect(await draftRows(), beforeReparentDrafts);
  });

  test('receipt SQL failure rolls back both create and rename with their drafts', () async {
    final category = (await db.select(db.categories).get()).single;
    final cases = [
      (
        session: (await edits.openCatalogName(
          const CatalogNameTarget.newCategory(),
        ) as FreshEdit<CatalogNameEditSession>).session,
        slot: 'catalog-name-new/category',
        raw: 'Receipt failure create',
      ),
      (
        session: (await edits.openCatalogName(
          CatalogNameTarget.renameCategory(category.id),
        ) as FreshEdit<CatalogNameEditSession>).session,
        slot:
            'catalog-name-rename/category/${Uri.encodeComponent(category.id)}',
        raw: 'Receipt failure rename',
      ),
    ];
    for (final c in cases) {
      c.session.replace(CatalogNameInput(nameText: c.raw));
      await c.session.flush();
      final beforeRows = await taxonomyRows();
      final beforeDrafts = await draftRows();
      final key = controlKey(c.slot).replaceAll("'", "''");
      await db.customStatement(
        'CREATE TRIGGER reject_catalog_name_receipt BEFORE UPDATE ON app_settings '
        "WHEN NEW.key = '$key' AND instr(NEW.value, '"
        '"phase":"committed"'
        "') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic catalog receipt failure'); END",
      );
      await expectLater(
        c.session.save(),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('synthetic catalog receipt failure'),
          ),
        ),
      );
      expect(await taxonomyRows(), beforeRows);
      expect(await draftRows(), beforeDrafts);
      await db.customStatement('DROP TRIGGER reject_catalog_name_receipt');
    }
  });

  test('changed saved row blocks its receipt and leaves the exact receipt evidence', () async {
    final category = (await db.select(db.categories).get()).single;
    final target = CatalogNameTarget.newType(category.id);
    final session = (await edits.openCatalogName(
      target,
    ) as FreshEdit<CatalogNameEditSession>).session;
    session.replace(
      const CatalogNameInput(nameText: 'Saved type before change'),
    );
    await session.flush();
    final saved = await session.save();
    final slot = createSlot(CatalogNameKind.type, category.id);
    final receipt = await db.settingsDao.getSetting(controlKey(slot));
    await db.taxonomyDao.renameStyle(saved.id, 'Changed after save');
    final changedRows = await taxonomyRows();

    await reopen();
    final blocked = await edits.openCatalogName(target);
    expect(blocked, isA<BlockedEdit<CatalogNameEditSession>>());
    expect(
      (blocked as BlockedEdit<CatalogNameEditSession>).preservedInput,
      receipt,
    );
    expect(await db.settingsDao.getSetting(controlKey(slot)), receipt);
    expect(await taxonomyRows(), changedRows);
  });

  test('foreign and malformed catalog drafts stay blocked and exact receipt acknowledgement rejects replacement', () async {
    const target = CatalogNameTarget.newCategory();
    final session = (await edits.openCatalogName(
      target,
    ) as FreshEdit<CatalogNameEditSession>).session;
    session.replace(const CatalogNameInput(nameText: '  retained draft  '));
    await session.flush();
    final rawInput = await db.settingsDao.getSetting(
      inputKey('catalog-name-new/category'),
    );
    await reopen();
    final foreign = EditDrafts(
      db: db,
      pin: pin,
      deviceId: 'synthetic-other-device',
    );
    expect(
      await foreign.openCatalogName(target),
      isA<BlockedEdit<CatalogNameEditSession>>(),
    );
    expect(
      await db.settingsDao.getSetting(inputKey('catalog-name-new/category')),
      rawInput,
    );

    final draft = Map<String, Object?>.from(jsonDecode(rawInput!) as Map)
      ..['v'] = 999;
    final malformed = jsonEncode(draft);
    await db.settingsDao.setSetting(
      inputKey('catalog-name-new/category'),
      malformed,
    );
    await reopen();
    final blocked = await edits.openCatalogName(target);
    expect(blocked, isA<BlockedEdit<CatalogNameEditSession>>());
    expect(
      (blocked as BlockedEdit<CatalogNameEditSession>).preservedInput,
      malformed,
    );
    expect(
      await db.settingsDao.getSetting(inputKey('catalog-name-new/category')),
      malformed,
    );

    await blocked.discard();
    final fresh = (await edits.openCatalogName(
      target,
    ) as FreshEdit<CatalogNameEditSession>).session;
    fresh.replace(
      const CatalogNameInput(nameText: '  exact acknowledgement  '),
    );
    await fresh.flush();
    final saved = await fresh.save();
    final beforeRows = await taxonomyRows();
    const replacement = '{"phase":"editing","token":"synthetic-replacement"}';
    await db.settingsDao.setSetting(
      controlKey('catalog-name-new/category'),
      replacement,
    );
    await expectLater(saved.acknowledge(), throwsStateError);
    expect(
      await db.settingsDao.getSetting(controlKey('catalog-name-new/category')),
      replacement,
    );
    expect(await taxonomyRows(), beforeRows);
  });
}
