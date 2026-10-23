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
  late String device, partId, brandId, otherBrand;
  late PinService pin;
  late EditDrafts edits;
  const rawName = '  White · exact\n unfinished  ';
  const rawMpn = '  SYN · MPN\n phase 2  ';

  String inputKey() =>
      '${editDraftPrefix}variance-new/${Uri.encodeComponent(partId)}/input';
  String controlKey() => inputKey().replaceFirst('/input', '/control');
  CatalogRepository catalog() => CatalogRepository(db, pin, device);
  MaintenanceRepository maintenance() => MaintenanceRepository(db, pin, device);

  void bind() {
    pin = PinService(db.settingsDao);
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
  }

  Future<void> reopen() async {
    await edits.quiesce(StorageChange.exit);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    bind();
  }

  VarianceInput input({String? brand, String mpn = rawMpn, bool main = true}) =>
      VarianceInput(
        brandId: brand ?? brandId,
        varianceNameText: rawName,
        mpnText: mpn,
        isMain: main,
      );

  Future<EditOpening<NewVarianceEditSession>> open({
    VarianceInput? initial,
    EditDrafts? owner,
  }) => (owner ?? edits).openNewVariance(
    partId: partId,
    initial:
        initial ??
        VarianceInput(
          brandId: brandId,
          varianceNameText: '',
          mpnText: '',
          isMain: false,
        ),
  );

  Future<NewVarianceEditSession> pending({VarianceInput? value}) async {
    final session = (await open(
      initial: VarianceInput(
        brandId: value == null ? brandId : value.brandId,
        varianceNameText: '',
        mpnText: '',
        isMain: false,
      ),
    ) as FreshEdit<NewVarianceEditSession>).session;
    session.replace(value ?? input());
    await session.flush();
    return session;
  }

  Future<BrandVersion?> variance(String id) => (db.select(
    db.brandVersions,
  )..where((table) => table.id.equals(id))).getSingleOrNull();

  Future<Map<String, List<String>>> snapshot({bool drafts = true}) async => {
    for (final table in db.allTables)
      table.actualTableName:
          (await db
                  .customSelect(
                    'SELECT * FROM "${table.actualTableName}"'
                    '${!drafts && table.actualTableName == 'app_settings' ? " WHERE key NOT LIKE 'local_edit_v1/%'" : ''}',
                  )
                  .get())
              .map((row) => jsonEncode(row.data))
              .toList()
            ..sort(),
  };

  Future<Map<String, String?>> ownDrafts() async => {
    'input': await db.settingsDao.getSetting(inputKey()),
    'control': await db.settingsDao.getSetting(controlKey()),
  };

  Future<String> sibling({String? part, String? brand, bool main = true}) =>
      catalog().createBrandVersion(
        partId: part ?? partId,
        brandId: brand ?? brandId,
        mpn: 'SIBLING',
        isMain: main,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('variance-draft-');
    file = File('${directory.path}/synthetic.sqlite');
    final fixture = await WarehouseFixture.create(file: file);
    db = fixture.db;
    device = fixture.device;
    partId = fixture.partId;
    bind();
    brandId = await maintenance().createBrand('Selected brand');
    otherBrand = await maintenance().createBrand('Other brand');
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  for (final main in [false, true]) {
    test(
      'file-backed raw fields and Main=$main recover across defaults; Save and cold receipt create once',
      () async {
        final before = await snapshot(drafts: false);
        final session = await pending(value: input(main: main));
        final reserved = session.varianceId;
        expect(await snapshot(drafts: false), before);
        await reopen();
        final recovery = await open(
          initial: input(brand: otherBrand, mpn: 'replacement', main: !main),
        );
        expect(recovery, isA<RecoverableEdit<NewVarianceEditSession>>());
        final resumed =
            await (recovery as RecoverableEdit<NewVarianceEditSession>)
                .resume();
        expect(resumed.varianceId, reserved);
        expect(
          (
            resumed.partId,
            resumed.initial.brandId,
            resumed.initial.varianceNameText,
            resumed.initial.mpnText,
            resumed.initial.isMain,
          ),
          (partId, brandId, rawName, rawMpn, main),
        );
        final saved = await resumed.save();
        expect((await resumed.save()).id, reserved);
        final row = (await variance(reserved))!;
        expect(saved.identifies(row), isTrue);
        expect(
          (
            row.mpn,
            row.varianceName,
            row.isMain,
            row.originDeviceId,
            row.revision,
          ),
          (rawMpn.trim(), rawName.trim(), main, device, 1),
        );
        expect(await db.settingsDao.getSetting(inputKey()), isNull);
        final rows = await snapshot(drafts: false);
        await reopen();
        final completion = await open(initial: input(brand: otherBrand));
        expect(completion, isA<VarianceCreated>());
        expect((completion as VarianceCreated).id, reserved);
        expect(await snapshot(drafts: false), rows);
        await completion.acknowledge();
        await completion.acknowledge();
        expect(await ownDrafts(), {'input': null, 'control': null});
        expect(await open(), isA<FreshEdit<NewVarianceEditSession>>());
      },
    );
  }

  for (final invalid in ['mpn', 'brand']) {
    test(
      'missing $invalid retains admitted raw and changes no business data',
      () async {
        final session = await pending(
          value: VarianceInput(
            brandId: invalid == 'brand' ? null : brandId,
            varianceNameText: rawName,
            mpnText: invalid == 'mpn' ? ' \n ' : rawMpn,
            isMain: true,
          ),
        );
        final before = await snapshot();
        await expectLater(session.save(), throwsStateError);
        expect(await snapshot(), before);
        await reopen();
        expect(await open(), isA<RecoverableEdit<NewVarianceEditSession>>());
      },
    );
  }

  for (final table in ['parts', 'brands']) {
    for (final change in ['rename', 'delete']) {
      test(
        '$change selected $table refuses Save and cold recovery while retaining input',
        () async {
          final session = await pending();
          await db.customStatement(
            'UPDATE $table SET ${change == 'rename' ? "name = 'Changed'" : 'deleted_at = 1'} WHERE id = ?',
            [table == 'parts' ? partId : brandId],
          );
          final before = await snapshot();
          await expectLater(session.save(), throwsStateError);
          expect(await snapshot(), before);
          await reopen();
          final opening = await open();
          expect(opening, isA<BlockedEdit<NewVarianceEditSession>>());
          expect(
            (opening as BlockedEdit<NewVarianceEditSession>).preservedInput,
            isNotNull,
          );
          expect(await snapshot(), before);
        },
      );
    }
  }

  test('reference change between recovery prompt and Resume refuses without deleting input', () async {
    await pending();
    await reopen();
    final recovery = await open() as RecoverableEdit<NewVarianceEditSession>;
    await db.customStatement(
      "UPDATE brands SET name = 'Changed after opening' WHERE id = ?",
      [brandId],
    );
    final before = await snapshot();
    await expectLater(recovery.resume(), throwsStateError);
    expect(await snapshot(), before);
  });

  for (final replacement in [
    'malformed',
    'raw',
    'target',
    'origin',
    'control',
  ]) {
    test(
      '$replacement storage replacement is not overwritten by Save or recovery',
      () async {
        final session = await pending();
        if (replacement == 'control') {
          await db.settingsDao.setSetting(
            controlKey(),
            jsonEncode({'phase': 'editing', 'token': 'another-token'}),
          );
        } else if (replacement == 'malformed') {
          await db.settingsDao.setSetting(inputKey(), '{malformed');
        } else {
          final raw = jsonDecode(
            (await db.settingsDao.getSetting(inputKey()))!,
          ) as Map<String, dynamic>;
          if (replacement == 'raw') {
            (raw['input'] as Map<String, dynamic>)['mpn'] = 'newer raw';
          }
          if (replacement == 'target') {
            (raw['target'] as Map<String, dynamic>)['unexpected'] = 'foreign';
          }
          if (replacement == 'origin') {
            (raw['origin'] as Map<String, dynamic>)['device'] =
                'foreign-device';
          }
          await db.settingsDao.setSetting(inputKey(), jsonEncode(raw));
        }
        final before = await snapshot();
        await expectLater(session.save(), throwsA(anything));
        expect(await snapshot(), before);
        await db.close();
        db = AppDatabase.forTesting(NativeDatabase(file));
        bind();
        final opening = await open();
        if (replacement == 'raw') {
          final resumed =
              await (opening as RecoverableEdit<NewVarianceEditSession>)
                  .resume();
          expect(resumed.initial.mpnText, 'newer raw');
        } else {
          expect(opening, isA<BlockedEdit<NewVarianceEditSession>>());
        }
        expect(await snapshot(), before);
      },
    );
  }

  test('foreign device cannot resume or acknowledge local variance', () async {
    final session = await pending();
    await session.leave(LeaveIntent.back);
    final foreign = EditDrafts(db: db, pin: pin, deviceId: 'foreign-device');
    expect(
      await open(owner: foreign),
      isA<BlockedEdit<NewVarianceEditSession>>(),
    );
    final resumed =
        await (await open() as RecoverableEdit<NewVarianceEditSession>)
            .resume();
    await resumed.save();
    final before = await snapshot();
    expect(
      await open(owner: foreign),
      isA<BlockedEdit<NewVarianceEditSession>>(),
    );
    expect(await snapshot(), before);
  });

  test('actual configured locked and relocked PIN retain input; unlock saves same reserved ID', () async {
    final session = await pending();
    await pin.setPin('2468');
    final before = await snapshot();
    await expectLater(session.save(), throwsStateError);
    expect(await snapshot(), before);
    expect(await pin.unlock('2468'), isTrue);
    pin.lock();
    await expectLater(session.save(), throwsStateError);
    expect(await snapshot(), before);
    expect(await pin.unlock('2468'), isTrue);
    expect((await session.save()).id, session.varianceId);
  });

  for (final invalid in [
    'mpn',
    'part',
    'brand',
    'deleted-part',
    'deleted-brand',
  ]) {
    test(
      'repository boundary refuses $invalid without creating or demoting a variance',
      () async {
        await sibling();
        if (invalid == 'deleted-part') {
          await db.customStatement(
            'UPDATE parts SET deleted_at = 1 WHERE id = ?',
            [partId],
          );
        }
        if (invalid == 'deleted-brand') {
          await db.customStatement(
            'UPDATE brands SET deleted_at = 1 WHERE id = ?',
            [brandId],
          );
        }
        final before = await snapshot();
        await expectLater(
          catalog().createBrandVersion(
            partId: invalid == 'part' ? 'missing-part' : partId,
            brandId: invalid == 'brand' ? 'missing-brand' : brandId,
            mpn: invalid == 'mpn' ? ' \n ' : 'VALID',
            isMain: true,
          ),
          throwsStateError,
        );
        expect(await snapshot(), before);
      },
    );
  }

  test('company refusal retains admitted input without business or other draft effects', () async {
    final session = await pending();
    await db.customStatement(
      'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) '
      "VALUES ('variance-denial', 1, 'blocked', 'synthetic')",
    );
    final before = await snapshot();
    await expectLater(session.save(), throwsStateError);
    expect(await snapshot(), before);
  });

  for (final deleted in [false, true]) {
    test(
      'reserved ID collision deleted=$deleted rejects without replacing row or draft',
      () async {
        final session = await pending();
        await catalog().createBrandVersion(
          partId: partId,
          brandId: brandId,
          mpn: 'COLLISION',
          reservedId: session.varianceId,
        );
        if (deleted) {
          await db.customStatement(
            'UPDATE brand_versions SET deleted_at = 1 WHERE id = ?',
            [session.varianceId],
          );
        }
        final before = await snapshot();
        await expectLater(session.save(), throwsStateError);
        expect(await snapshot(), before);
        await reopen();
        expect(await open(), isA<BlockedEdit<NewVarianceEditSession>>());
        expect(await snapshot(), before);
      },
    );
  }

  for (final failure in ['insert', 'receipt']) {
    test(
      '$failure failure rolls back insertion and intended Main demotion including revision',
      () async {
        final existing = await sibling();
        final session = await pending();
        final before = await snapshot();
        final trigger = failure == 'insert'
            ? "CREATE TRIGGER reject_variance BEFORE INSERT ON brand_versions BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END"
            : "CREATE TRIGGER reject_variance BEFORE UPDATE ON app_settings WHEN NEW.key = '${controlKey()}' AND instr(NEW.value, '\"phase\":\"committed\"') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END";
        await db.customStatement(trigger);
        await expectLater(
          session.save(),
          throwsA(
            predicate(
              (error) =>
                  error.toString().contains('synthetic $failure failure'),
            ),
          ),
        );
        expect(await snapshot(), before);
        expect((await variance(existing))!.isMain, isTrue);
        expect(await variance(session.varianceId), isNull);
        await db.customStatement('DROP TRIGGER reject_variance');
        await session.save();
        expect((await variance(existing))!.isMain, isFalse);
        expect((await variance(session.varianceId))!.isMain, isTrue);
      },
    );
  }

  test('Main demotes only other live Main in same Part and Brand; false elects none', () async {
    final part = (await db.partsDao.getPart(partId))!;
    final secondPart = await catalog().createGeneralPart(
      name: 'Other Part',
      categoryId: part.categoryId,
      styleId: part.styleId,
      typeId: part.typeId,
    );
    final main = await sibling();
    final nonMain = await sibling(main: false);
    final otherBrandMain = await sibling(brand: otherBrand);
    final otherPartMain = await sibling(part: secondPart);
    final deletedMain = await sibling();
    await db.customStatement(
      'UPDATE brand_versions SET deleted_at = 1 WHERE id = ?',
      [deletedMain],
    );
    await catalog().updateBrandVersion(
      id: main,
      mpn: 'MAIN',
      varianceName: '',
      isMain: true,
    );
    final unaffected = {
      for (final id in [nonMain, otherBrandMain, otherPartMain, deletedMain])
        id: await variance(id),
    };
    final previous = (await variance(main))!;
    final session = await pending();
    await session.save();
    final demoted = (await variance(main))!;
    expect(demoted.isMain, isFalse);
    expect(demoted.revision, previous.revision + 1);
    for (final entry in unaffected.entries) {
      expect(await variance(entry.key), entry.value);
    }
    final receipt = await open() as VarianceCreated;
    await receipt.acknowledge();
    final unselected = await pending(value: input(main: false));
    final current = await variance(session.varianceId);
    await unselected.save();
    expect(await variance(session.varianceId), current);
    expect((await variance(unselected.varianceId))!.isMain, isFalse);
  });

  test('later mutable edits and legitimate Main demotion preserve cold completion and acknowledgement', () async {
    final session = await pending();
    final saved = await session.save();
    await catalog().updateBrandVersion(
      id: saved.id,
      mpn: 'LATER-MPN',
      varianceName: 'Later name',
      isMain: true,
    );
    await sibling();
    expect((await variance(saved.id))!.isMain, isFalse);
    final before = await snapshot(drafts: false);
    await reopen();
    final completion = await open() as VarianceCreated;
    expect(completion.identifies((await variance(saved.id))!), isTrue);
    await completion.acknowledge();
    expect(await snapshot(drafts: false), before);
    expect(await ownDrafts(), {'input': null, 'control': null});
  });

  for (final change in [
    'variance-delete',
    'part-delete',
    'brand-delete',
    'identity',
    'control',
    'new-input',
  ]) {
    test('$change refuses acknowledgement and preserves the exact receipt', () async {
      final saved = await (await pending()).save();
      if (change == 'variance-delete') {
        await db.customStatement(
          'UPDATE brand_versions SET deleted_at = 1 WHERE id = ?',
          [saved.id],
        );
      }
      if (change == 'part-delete') {
        await db.customStatement(
          'UPDATE parts SET deleted_at = 1 WHERE id = ?',
          [partId],
        );
      }
      if (change == 'brand-delete') {
        await db.customStatement(
          'UPDATE brands SET deleted_at = 1 WHERE id = ?',
          [brandId],
        );
      }
      if (change == 'identity') {
        await db.customStatement(
          "UPDATE brand_versions SET origin_device_id = 'foreign' WHERE id = ?",
          [saved.id],
        );
      }
      if (change == 'control') {
        await db.settingsDao.setSetting(
          controlKey(),
          jsonEncode({'phase': 'editing', 'token': 'newer-token'}),
        );
      }
      if (change == 'new-input') {
        await db.settingsDao.setSetting(inputKey(), 'newer input');
      }
      final before = await snapshot();
      await expectLater(saved.acknowledge(), throwsStateError);
      expect(await snapshot(), before);
      expect(await open(), isA<BlockedEdit<NewVarianceEditSession>>());
    });
  }

  test('Cancel removes only own variance input and preserves Brand, Part, Job and New Part drafts', () async {
    final parent =
        (await edits.openPart(partId) as FreshEdit<PartEditSession>).session;
    final old = parent.initial;
    parent.replace(
      PartInput(
        nameText: 'Parent pending',
        descriptionText: old.descriptionText,
        specsText: old.specsText,
        uomText: old.uomText,
        categoryId: old.categoryId,
        styleId: old.styleId,
        typeId: old.typeId,
        defaultSupplierId: old.defaultSupplierId,
        active: old.active,
      ),
    );
    await parent.flush();
    final job =
        (await edits.openNewJob() as FreshEdit<NewJobEditSession>).session;
    job.replace(const NewJobInput(nameText: 'Independent Job'));
    await job.flush();
    final newPart =
        (await edits.openNewPart() as FreshEdit<NewPartEditSession>).session;
    newPart.replace(
      const NewPartInput(
        nameText: 'Independent Part',
        categoryId: null,
        styleId: null,
        typeId: null,
      ),
    );
    await newPart.flush();
    final child = (await edits.openCatalogName(
      const CatalogNameTarget.newBrand(),
    ) as FreshEdit<CatalogNameEditSession>).session;
    child.replace(const CatalogNameInput(nameText: 'Independent brand'));
    final brand = await child.save();
    final before = await snapshot();
    final session = await pending(value: input(brand: brand.id));
    await session.leave(LeaveIntent.discard);
    expect(await snapshot(), before);
  });

  test('no Brands permits outer raw draft; failed child adoption retains Brand receipt and retry persists selection before ack', () async {
    await db.customStatement('DELETE FROM brands');
    const unselected = VarianceInput(
      brandId: null,
      varianceNameText: rawName,
      mpnText: rawMpn,
      isMain: true,
    );
    final outer = await pending(value: unselected);
    final child = (await edits.openCatalogName(
      const CatalogNameTarget.newBrand(),
    ) as FreshEdit<CatalogNameEditSession>).session;
    child.replace(const CatalogNameInput(nameText: 'First brand'));
    final saved = await child.save();
    const childKey = '${editDraftPrefix}catalog-name-new/brand/control';
    final receipt = await db.settingsDao.getSetting(childKey);
    await db.customStatement(
      "CREATE TRIGGER reject_adoption BEFORE UPDATE ON app_settings WHEN NEW.key = '${inputKey()}' BEGIN SELECT RAISE(ABORT, 'synthetic adoption failure'); END",
    );
    outer.replace(input(brand: saved.id));
    await expectLater(
      outer.flush(),
      throwsA(
        predicate(
          (error) => error.toString().contains('synthetic adoption failure'),
        ),
      ),
    );
    expect(await db.settingsDao.getSetting(childKey), receipt);
    expect((await db.select(db.brands).get()).single.id, saved.id);
    expect(await db.select(db.brandVersions).get(), isEmpty);
    await db.customStatement('DROP TRIGGER reject_adoption');
    await outer.flush();
    expect(
      outer.status.value.durableSequence,
      outer.status.value.latestSequence,
    );
    expect(outer.initial.brandId, saved.id);
    await saved.acknowledge();
    await reopen();
    final resumed =
        await (await open() as RecoverableEdit<NewVarianceEditSession>)
            .resume();
    expect(
      (
        resumed.initial.brandId,
        resumed.initial.mpnText,
        resumed.initial.varianceNameText,
      ),
      (saved.id, rawMpn, rawName),
    );
  });
}
