import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import '../warehouse/warehouse_test_support.dart';

void main() {
  late Directory directory;
  late File file;
  late AppDatabase db;
  late String device, existingPart, category, style, variant;
  late PinService pin;
  late EditDrafts edits;

  const inputKey = 'local_edit_v1/part-new/input';
  const controlKey = 'local_edit_v1/part-new/control';
  CatalogRepository catalog() => CatalogRepository(db, pin, device);
  MaintenanceRepository maintenance() => MaintenanceRepository(db, pin, device);

  void bind() {
    pin = PinService(db.settingsDao);
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
  }

  Future<void> reopen() async {
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
  }

  NewPartInput input({String name = '  Synthetic new Part\nphase 2  '}) =>
      NewPartInput(
        nameText: name,
        categoryId: category,
        styleId: style,
        typeId: variant,
      );

  Future<NewPartEditSession> fresh() async =>
      (await edits.openNewPart() as FreshEdit<NewPartEditSession>).session;

  Future<NewPartEditSession> prepare() async {
    final session = await fresh();
    session.replace(input());
    await session.flush();
    return session;
  }

  Future<List<Part>> createdParts() async => (await db.select(db.parts).get())
      .where((part) => part.id != existingPart)
      .toList();

  Future<List<Map<String, Object?>>> drafts() async =>
      (await db
              .customSelect(
                "SELECT key, value FROM app_settings WHERE key LIKE 'local_edit_v1/part-new/%' ORDER BY key",
              )
              .get())
          .map((row) => row.data)
          .toList();

  Future<Map<String, dynamic>> control() async =>
      jsonDecode((await db.settingsDao.getSetting(controlKey))!)
          as Map<String, dynamic>;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('new-part-draft-');
    file = File('${directory.path}/synthetic.sqlite');
    final fixture = await WarehouseFixture.create(file: file);
    db = fixture.db;
    device = fixture.device;
    existingPart = fixture.partId;
    final part = (await db.partsDao.getPart(existingPart))!;
    category = part.categoryId!;
    style = part.styleId!;
    variant = part.typeId!;
    bind();
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'raw input reopens across entry defaults and only Save creates a Part',
    () async {
      final original = (await db.partsDao.getPart(existingPart))!;
      final session = await prepare();
      final reserved = session.partId;
      expect(await createdParts(), isEmpty);
      await edits.quiesce(StorageChange.exit);
      await reopen();

      final opening = await edits.openNewPart(initialCategoryId: 'other-entry');
      expect(opening, isA<RecoverableEdit<NewPartEditSession>>());
      expect(await createdParts(), isEmpty);
      final resumed = await (opening as RecoverableEdit<NewPartEditSession>)
          .resume();
      expect(resumed.partId, reserved);
      expect(resumed.initial.nameText, '  Synthetic new Part\nphase 2  ');
      expect(
        (
          resumed.initial.categoryId,
          resumed.initial.styleId,
          resumed.initial.typeId,
        ),
        (category, style, variant),
      );
      final saved = await resumed.save();
      final retry = await resumed.save();
      expect((saved.id, retry.id), (reserved, reserved));
      final created = (await createdParts()).single;
      expect(created.name, 'Synthetic new Part\nphase 2');
      expect(
        (created.categoryId, created.styleId, created.typeId),
        (category, style, variant),
      );
      expect(created.originDeviceId, device);
      expect(created.revision, 1);
      expect(created.deletedAt, isNull);
      expect(await db.partsDao.getPart(existingPart), original);
      expect(await db.settingsDao.getSetting(inputKey), isNull);
      expect(await db.settingsDao.getSetting(controlKey), isNotNull);

      await reopen();
      final recovered = await edits.openNewPart() as NewPartCreated;
      expect(recovered.id, reserved);
      expect((await createdParts()).single.id, reserved);
      await recovered.acknowledge();
      await recovered.acknowledge();
      expect(await drafts(), isEmpty);
      expect(await edits.openNewPart(), isA<FreshEdit<NewPartEditSession>>());
    },
  );

  test(
    'untouched initialization does not persist and Back flushes user input',
    () async {
      final opening = await edits.openNewPart(
        initialCategoryId: category,
        initialStyleId: style,
        initialTypeId: variant,
      ) as FreshEdit<NewPartEditSession>;
      await opening.session.leave(LeaveIntent.back);
      expect(await drafts(), isEmpty);
      final session = await prepare();
      await session.leave(LeaveIntent.back);
      final resumed =
          await (await edits.openNewPart()
                  as RecoverableEdit<NewPartEditSession>)
              .resume();
      expect(resumed.initial.nameText, input().nameText);
      expect(await createdParts(), isEmpty);
    },
  );

  test(
    'Cancel preserves unrelated drafts and independently saved taxonomy',
    () async {
      final other =
          (await edits.openNewJob() as FreshEdit<NewJobEditSession>).session;
      other.replace(const NewJobInput(nameText: 'Unrelated input'));
      await other.flush();
      final unrelated = await db.settingsDao.getSetting(
        'local_edit_v1/job-new/input',
      );
      final session = await prepare();
      final child = (await edits.openCatalogName(
        const CatalogNameTarget.newCategory(),
      ) as FreshEdit<CatalogNameEditSession>).session;
      child.replace(const CatalogNameInput(nameText: 'Independent category'));
      final saved = await child.save();
      session.replace(
        NewPartInput(
          nameText: input().nameText,
          categoryId: saved.id,
          styleId: null,
          typeId: null,
        ),
      );
      await session.flush();
      await saved.acknowledge();
      final discard = session.leave(LeaveIntent.discard);
      session.replace(input(name: 'Late capture'));
      await discard;
      await edits.quiesce(StorageChange.exit);
      expect(await drafts(), isEmpty);
      expect(await createdParts(), isEmpty);
      expect(
        (await maintenance().listCategories()).map((row) => row.name),
        contains('Independent category'),
      );
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/input'),
        unrelated,
      );
    },
  );

  for (final invalid in [
    'blank-name',
    'missing-category',
    'missing-type',
    'missing-variant',
  ]) {
    test('$invalid is refused without losing raw input', () async {
      final session = await fresh();
      session.replace(
        NewPartInput(
          nameText: invalid == 'blank-name' ? ' \n\t ' : input().nameText,
          categoryId: invalid == 'missing-category' ? null : category,
          styleId: invalid == 'missing-type' ? null : style,
          typeId: invalid == 'missing-variant' ? null : variant,
        ),
      );
      await session.flush();
      final before = await drafts();
      await expectLater(session.save(), throwsStateError);
      expect(await createdParts(), isEmpty);
      expect(await drafts(), before);
    });
  }

  test('fresh initial hierarchy refuses a mismatched parent', () async {
    final other = await maintenance().createCategory('Other category');
    expect(
      await edits.openNewPart(
        initialCategoryId: other,
        initialStyleId: style,
        initialTypeId: variant,
      ),
      isA<BlockedEdit<NewPartEditSession>>(),
    );
    expect(await createdParts(), isEmpty);
  });

  for (final change in ['rename', 'delete', 'reparent', 'missing']) {
    test(
      '$change of selected hierarchy blocks Save and recovery with raw input intact',
      () async {
        final session = await prepare();
        final before = await drafts();
        switch (change) {
          case 'rename':
            await maintenance().renameStyle(style, 'Changed type');
          case 'delete':
            await db.customStatement(
              'UPDATE types SET deleted_at = 1 WHERE id = ?',
              [variant],
            );
          case 'reparent':
            final other = await maintenance().createCategory('Other category');
            await db.customStatement(
              'UPDATE styles SET category_id = ? WHERE id = ?',
              [other, style],
            );
          case 'missing':
            await db.customStatement('DELETE FROM types WHERE id = ?', [
              variant,
            ]);
        }
        await expectLater(session.save(), throwsStateError);
        expect(await drafts(), before);
        expect(await createdParts(), isEmpty);
        await reopen();
        final blocked =
            await edits.openNewPart() as BlockedEdit<NewPartEditSession>;
        expect(
          blocked.preservedInput,
          await db.settingsDao.getSetting(inputKey),
        );
        expect(await drafts(), before);
      },
    );
  }

  test('Resume revalidates hierarchy changed after opening recovery', () async {
    final session = await prepare();
    await session.leave(LeaveIntent.back);
    final recovery =
        await edits.openNewPart() as RecoverableEdit<NewPartEditSession>;
    final before = await drafts();
    await db.customStatement('UPDATE types SET style_id = ? WHERE id = ?', [
      'other-type',
      variant,
    ]);
    await expectLater(recovery.resume(), throwsStateError);
    expect(await drafts(), before);
    expect(await createdParts(), isEmpty);
  });

  test('real locked and relocked PIN refuse Save and unlocking permits the same session', () async {
    await pin.setPin('2468');
    final session = await prepare();
    final before = await drafts();
    await expectLater(session.save(), throwsStateError);
    expect(await createdParts(), isEmpty);
    expect(await drafts(), before);
    expect(await pin.unlock('2468'), isTrue);
    pin.lock();
    await expectLater(session.save(), throwsStateError);
    expect(await drafts(), before);
    expect(await pin.unlock('2468'), isTrue);
    expect((await session.save()).id, session.partId);
  });

  test(
    'company boundary refuses Part creation and preserves the draft',
    () async {
      final session = await prepare();
      final before = await drafts();
      await db.customStatement(
        "INSERT INTO company_bootstrap_witnesses "
        "(company_id, bootstrap_id, facts_commitment, package_id, package_digest, status) "
        "VALUES ('synthetic-company', 'synthetic-bootstrap', 'facts', 'package', NULL, 'pending')",
      );
      await expectLater(session.save(), throwsStateError);
      expect(await createdParts(), isEmpty);
      expect(await drafts(), before);
    },
  );

  for (final tombstone in [false, true]) {
    test(
      'reserved collision including deleted=$tombstone preserves both records',
      () async {
        final session = await prepare();
        await catalog().createGeneralPart(
          name: 'Collision',
          categoryId: category,
          styleId: style,
          typeId: variant,
          reservedId: session.partId,
        );
        if (tombstone) {
          await db.customStatement(
            'UPDATE parts SET deleted_at = 1 WHERE id = ?',
            [session.partId],
          );
        }
        final parts = await db.select(db.parts).get();
        final before = await drafts();
        await expectLater(session.save(), throwsStateError);
        expect(await db.select(db.parts).get(), parts);
        expect(await drafts(), before);
        await reopen();
        expect(
          await edits.openNewPart(),
          isA<BlockedEdit<NewPartEditSession>>(),
        );
        expect(await drafts(), before);
      },
    );
  }

  for (final failure in ['insert', 'receipt']) {
    test('$failure failure rolls back Part creation and retains retryable input', () async {
      final session = await prepare();
      final before = await drafts();
      final trigger = failure == 'insert'
          ? "CREATE TRIGGER reject_part BEFORE INSERT ON parts BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END"
          : "CREATE TRIGGER reject_part BEFORE UPDATE ON app_settings WHEN NEW.key = '$controlKey' AND instr(NEW.value, '\"phase\":\"committed\"') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END";
      await db.customStatement(trigger);
      await expectLater(
        session.save(),
        throwsA(
          predicate(
            (error) => error.toString().contains('synthetic $failure failure'),
          ),
        ),
      );
      expect(await createdParts(), isEmpty);
      expect(await drafts(), before);
      await reopen();
      final resumed =
          await (await edits.openNewPart()
                  as RecoverableEdit<NewPartEditSession>)
              .resume();
      expect(resumed.initial.nameText, input().nameText);
      await db.customStatement('DROP TRIGGER reject_part');
      expect((await resumed.save()).id, session.partId);
      expect(await createdParts(), hasLength(1));
    });
  }

  test(
    'legitimate mutable Part edits preserve cold receipt and acknowledgement',
    () async {
      final session = await prepare();
      final saved = await session.save();
      final otherCategory = await maintenance().createCategory(
        'Later category',
      );
      final otherStyle = await maintenance().createStyle(
        categoryId: otherCategory,
        name: 'Later type',
      );
      final otherVariant = await maintenance().createType(
        styleId: otherStyle,
        name: 'Later variant',
      );
      await catalog().updatePart(
        partId: saved.id,
        name: 'Later name',
        description: 'Later description',
        uom: 'ft',
        active: false,
        categoryId: otherCategory,
        styleId: otherStyle,
        typeId: otherVariant,
        specs: 'Later specs',
      );
      expect(saved.identifies((await catalog().getPart(saved.id))!), isTrue);
      expect((await session.save()).id, saved.id);
      await reopen();
      final recovered = await edits.openNewPart() as NewPartCreated;
      expect(recovered.name, 'Synthetic new Part\nphase 2');
      expect(recovered.categoryId, category);
      expect((await catalog().getPart(saved.id))!.name, 'Later name');
      await recovered.acknowledge();
      expect(await drafts(), isEmpty);
      expect(await createdParts(), hasLength(1));
    },
  );

  for (final changed in ['device', 'created', 'deleted', 'missing']) {
    test(
      'changed creation identity $changed refuses receipt and preserves evidence',
      () async {
        final saved = await (await prepare()).save();
        final before = await drafts();
        switch (changed) {
          case 'device':
            await db.customStatement(
              'UPDATE parts SET origin_device_id = ? WHERE id = ?',
              ['other', saved.id],
            );
          case 'created':
            await db.customStatement(
              'UPDATE parts SET created_at = created_at + 1 WHERE id = ?',
              [saved.id],
            );
          case 'deleted':
            await db.customStatement(
              'UPDATE parts SET deleted_at = 1 WHERE id = ?',
              [saved.id],
            );
          case 'missing':
            await db.customStatement('DELETE FROM parts WHERE id = ?', [
              saved.id,
            ]);
        }
        await expectLater(saved.acknowledge(), throwsStateError);
        await reopen();
        expect(
          await edits.openNewPart(),
          isA<BlockedEdit<NewPartEditSession>>(),
        );
        expect(await drafts(), before);
      },
    );
  }

  test('overwritten input with the same control token is preserved and cannot save', () async {
    final session = await prepare();
    final raw = jsonDecode(
      (await db.settingsDao.getSetting(inputKey))!,
    ) as Map<String, dynamic>;
    (raw['input'] as Map<String, dynamic>)['name'] = 'External input';
    await db.settingsDao.setSetting(inputKey, jsonEncode(raw));
    final before = await drafts();
    await expectLater(session.save(), throwsStateError);
    expect(await drafts(), before);
    expect(await createdParts(), isEmpty);
  });

  test(
    'foreign and malformed pending input remains blocked and untouched',
    () async {
      final session = await prepare();
      await session.leave(LeaveIntent.back);
      final foreign = EditDrafts(db: db, pin: pin, deviceId: 'other-device');
      final before = await drafts();
      expect(
        await foreign.openNewPart(),
        isA<BlockedEdit<NewPartEditSession>>(),
      );
      expect(await drafts(), before);
      final record = jsonDecode(
        (await db.settingsDao.getSetting(inputKey))!,
      ) as Map<String, dynamic>;
      (record['input'] as Map<String, dynamic>)['extra'] = true;
      await db.settingsDao.setSetting(inputKey, jsonEncode(record));
      final malformed = await drafts();
      expect(await edits.openNewPart(), isA<BlockedEdit<NewPartEditSession>>());
      expect(await drafts(), malformed);
      expect(await createdParts(), isEmpty);
    },
  );

  for (final tamper in [
    'token',
    'command',
    'target',
    'origin',
    'extra',
    'input',
  ]) {
    test(
      '$tamper tampering refuses retry and acknowledgement without creating another Part',
      () async {
        final session = await prepare();
        final saved = await session.save();
        final receipt = await control();
        switch (tamper) {
          case 'token':
            receipt['token'] = 'replacement';
          case 'command':
            receipt['command'] = 'part-save';
          case 'target':
            (receipt['result'] as Map<String, dynamic>)['target'] = jsonEncode({
              'kind': 'part-new',
              'reserved': 'other-part',
            });
          case 'origin':
            (receipt['origin'] as Map<String, dynamic>)['device'] =
                'other-device';
          case 'extra':
            (receipt['result'] as Map<String, dynamic>)['unknown'] = 'field';
          case 'input':
            await db.settingsDao.setSetting(inputKey, 'newer unfinished input');
        }
        await db.settingsDao.setSetting(controlKey, jsonEncode(receipt));
        final before = await drafts();
        await expectLater(session.save(), throwsA(anything));
        await expectLater(saved.acknowledge(), throwsStateError);
        expect(await drafts(), before);
        expect((await createdParts()).single.id, saved.id);
      },
    );
  }

  test('cold foreign receipt is blocked and unrelated acknowledgement cannot clear a newer session', () async {
    final first = await (await prepare()).save();
    await reopen();
    final foreign = EditDrafts(db: db, pin: pin, deviceId: 'other-device');
    final before = await drafts();
    expect(await foreign.openNewPart(), isA<BlockedEdit<NewPartEditSession>>());
    expect(await drafts(), before);
    final recovered = await edits.openNewPart() as NewPartCreated;
    await recovered.acknowledge();
    final later = await prepare();
    final newerDraft = await drafts();
    await expectLater(recovered.acknowledge(), throwsStateError);
    expect(await drafts(), newerDraft);
    expect(later.partId, isNot(first.id));
    expect(await createdParts(), hasLength(1));
  });
}
