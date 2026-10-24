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
  late String device, partId, versionId, supplierId, alternateId;
  late PinService pin;
  late EditDrafts edits;
  const rawSku = '  SKU · exact\n pending  ';

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

  String inputKey() =>
      '$editDraftPrefix'
      'supplier-listing-new/'
      '${Uri.encodeComponent(versionId)}/input';
  String controlKey() => inputKey().replaceFirst('/input', '/control');

  Future<EditOpening<SupplierListingEditSession>> open({EditDrafts? owner}) =>
      (owner ?? edits).openSupplierListing(
        brandVersionId: versionId,
        partId: partId,
        initial: SupplierListingInput(supplierId: supplierId, skuText: ''),
      );

  Future<SupplierListingEditSession> pending({String sku = rawSku}) async {
    final session =
        (await open() as FreshEdit<SupplierListingEditSession>).session;
    session.replace(
      SupplierListingInput(supplierId: alternateId, skuText: sku),
    );
    await session.flush();
    return session;
  }

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

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('listing-session-');
    file = File('${directory.path}/synthetic.sqlite');
    final fixture = await WarehouseFixture.create(file: file);
    db = fixture.db;
    device = fixture.device;
    partId = fixture.partId;
    bind();
    final repo = MaintenanceRepository(db, pin, device);
    supplierId = await repo.createSupplier('Default supplier');
    alternateId = await repo.createSupplier('Selected supplier');
    final brand = await repo.createBrand('Brand');
    versionId = await CatalogRepository(
      db,
      pin,
      device,
    ).createBrandVersion(partId: partId, brandId: brand, mpn: 'SYN-LISTING');
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  for (final sku in [rawSku, '']) {
    test(
      'cold Resume preserves exact Supplier and SKU ${sku.isEmpty ? 'empty' : 'raw'}; Add and receipt retry once',
      () async {
        final before = await snapshot(drafts: false);
        final session = await pending(sku: sku);
        final reserved = session.listingId;
        expect(await snapshot(drafts: false), before);
        await reopen();
        final opening = await open();
        expect(opening, isA<RecoverableEdit<SupplierListingEditSession>>());
        expect(await snapshot(drafts: false), before);
        final resumed =
            await (opening as RecoverableEdit<SupplierListingEditSession>)
                .resume();
        expect(resumed.listingId, reserved);
        expect(resumed.initial.supplierId, alternateId);
        expect(resumed.initial.skuText, sku);
        final saved = await resumed.save();
        expect(
          (
            saved.listing.id,
            saved.listing.brandVersionId,
            saved.listing.supplierId,
            saved.listing.sku,
          ),
          (reserved, versionId, alternateId, sku.trim()),
        );
        expect((await resumed.save()).listing, saved.listing);
        final after = await snapshot(drafts: false);
        await reopen();
        final receipt = await open() as SupplierListingSaved;
        expect(receipt.listing, saved.listing);
        expect(await db.settingsDao.getSetting(inputKey()), isNull);
        await receipt.acknowledge();
        await receipt.acknowledge();
        expect(await db.settingsDao.getSetting(controlKey()), isNull);
        expect(await snapshot(drafts: false), after);
        expect(await db.select(db.supplierListings).get(), [saved.listing]);
      },
    );
  }

  test('Back retains outer input; explicit Discard preserves Part draft and saved Supplier', () async {
    final parent =
        (await edits.openPart(partId) as FreshEdit<PartEditSession>).session;
    final p = parent.initial;
    parent.replace(
      PartInput(
        nameText: '  Parent exact  ',
        descriptionText: p.descriptionText,
        specsText: p.specsText,
        uomText: p.uomText,
        categoryId: p.categoryId,
        styleId: p.styleId,
        typeId: p.typeId,
        defaultSupplierId: p.defaultSupplierId,
        active: p.active,
      ),
    );
    await parent.flush();
    final child = (await edits.openCatalogName(
      const CatalogNameTarget.newSupplier(),
    ) as FreshEdit<CatalogNameEditSession>).session;
    child.replace(const CatalogNameInput(nameText: '  Nested supplier  '));
    final childSaved = await child.save();
    final outer = await pending();
    outer.replace(
      SupplierListingInput(supplierId: childSaved.id, skuText: rawSku),
    );
    await outer.flush();
    await childSaved.acknowledge();
    final before = await snapshot(drafts: false);
    await outer.leave(LeaveIntent.back);
    final resumed =
        await (await open() as RecoverableEdit<SupplierListingEditSession>)
            .resume();
    expect(resumed.initial.supplierId, childSaved.id);
    expect(resumed.initial.skuText, rawSku);
    await resumed.leave(LeaveIntent.discard);
    expect(await db.settingsDao.getSetting(inputKey()), isNull);
    expect(await db.settingsDao.getSetting(controlKey()), isNull);
    expect(await snapshot(drafts: false), before);
    await reopen();
    final partDraft = await (await edits.openPart(
      partId,
    ) as RecoverableEdit<PartEditSession>).resume();
    expect(partDraft.initial.nameText, '  Parent exact  ');
    expect(
      (await db.select(db.suppliers).get())
          .where((s) => s.id == childSaved.id)
          .single
          .name,
      'Nested supplier',
    );
  });

  test(
    'PIN and company refusals preserve input without business mutation',
    () async {
      final session = await pending();
      await pin.setPin('1234');
      pin.lock();
      var before = await snapshot();
      await expectLater(session.save(), throwsStateError);
      expect(await snapshot(), before);
      await pin.unlock('1234');
      await db.customStatement(
        'INSERT INTO company_join_events '
        '(request_id, ordinal, kind, evidence_bytes) '
        "VALUES ('listing-denial', 1, 'blocked', 'synthetic')",
      );
      before = await snapshot();
      await expectLater(session.save(), throwsStateError);
      expect(await snapshot(), before);
    },
  );

  test('failed outer adoption flush retains child receipt; retry adopts once before acknowledgement', () async {
    final outer = await pending();
    final child = (await edits.openCatalogName(
      const CatalogNameTarget.newSupplier(),
    ) as FreshEdit<CatalogNameEditSession>).session;
    child.replace(const CatalogNameInput(nameText: '  Durable child  '));
    final saved = await child.save();
    final childKey = '${editDraftPrefix}catalog-name-new/supplier/control';
    final receipt = await db.settingsDao.getSetting(childKey);
    expect(receipt, isNotNull);
    final escaped = inputKey().replaceAll("'", "''");
    await db.customStatement(
      'CREATE TRIGGER reject_outer_adoption BEFORE UPDATE ON app_settings '
      "WHEN NEW.key = '$escaped' "
      "BEGIN SELECT RAISE(ABORT, 'synthetic adoption failure'); END",
    );
    outer.replace(SupplierListingInput(supplierId: saved.id, skuText: rawSku));
    await expectLater(
      outer.flush(),
      throwsA(
        predicate(
          (error) => error.toString().contains('synthetic adoption failure'),
        ),
      ),
    );
    expect(await db.settingsDao.getSetting(childKey), receipt);
    expect(await db.select(db.supplierListings).get(), isEmpty);
    expect(
      (await db.select(db.suppliers).get()).where((s) => s.id == saved.id),
      hasLength(1),
    );
    await db.customStatement('DROP TRIGGER reject_outer_adoption');
    await outer.flush();
    await saved.acknowledge();
    await reopen();
    final resumed =
        await (await open() as RecoverableEdit<SupplierListingEditSession>)
            .resume();
    expect(resumed.initial.supplierId, saved.id);
    expect(resumed.initial.skuText, rawSku);
    expect(await db.settingsDao.getSetting(childKey), isNull);
    expect(await db.select(db.supplierListings).get(), isEmpty);
  });

  test('missing Supplier and wrong initial Part reject without placeholder listing', () async {
    final wrong = await edits.openSupplierListing(
      brandVersionId: versionId,
      partId: 'other-part',
      initial: const SupplierListingInput(supplierId: null, skuText: rawSku),
    );
    expect(wrong, isA<BlockedEdit<SupplierListingEditSession>>());
    final session = await pending();
    session.replace(
      const SupplierListingInput(supplierId: null, skuText: rawSku),
    );
    await session.flush();
    final before = await snapshot();
    await expectLater(session.save(), throwsStateError);
    expect(await snapshot(), before);
    expect(await db.select(db.supplierListings).get(), isEmpty);
  });

  for (final fault in [
    'version-changed',
    'version-deleted',
    'version-reparented',
    'part-changed',
    'part-deleted',
    'supplier-changed',
    'supplier-deleted',
  ]) {
    test('$fault blocks Add and cold Resume preserving raw input', () async {
      final session = await pending();
      final table = fault.startsWith('version')
          ? 'brand_versions'
          : fault.startsWith('part')
          ? 'parts'
          : 'suppliers';
      final id = fault.startsWith('version')
          ? versionId
          : fault.startsWith('part')
          ? partId
          : alternateId;
      final update = fault.endsWith('deleted')
          ? 'deleted_at = 1'
          : fault.endsWith('reparented')
          ? "part_id = 'other-part'"
          : 'revision = revision + 1';
      await db.customStatement('UPDATE $table SET $update WHERE id = ?', [id]);
      final before = await snapshot();
      await expectLater(session.save(), throwsStateError);
      expect(await snapshot(), before);
      await reopen();
      expect(await open(), isA<BlockedEdit<SupplierListingEditSession>>());
      expect(await snapshot(), before);
    });
  }

  test('reserved ID collision preserves competing listing and draft', () async {
    final session = await pending();
    await CatalogRepository(db, pin, device).createSupplierListing(
      brandVersionId: versionId,
      supplierId: supplierId,
      sku: 'competing',
      reservedId: session.listingId,
    );
    final before = await snapshot();
    await expectLater(session.save(), throwsStateError);
    expect(await snapshot(), before);
  });

  for (final fault in ['insert', 'receipt']) {
    test(
      '$fault failure rolls back listing; same session retries reserved ID once',
      () async {
        final session = await pending();
        final before = await snapshot();
        final trigger = fault == 'insert'
            ? 'BEFORE INSERT ON supplier_listings'
            : 'BEFORE UPDATE ON app_settings '
                  "WHEN NEW.key = '${controlKey().replaceAll("'", "''")}' "
                  "AND instr(NEW.value, '\"phase\":\"committed\"') > 0";
        await db.customStatement(
          'CREATE TRIGGER reject_listing_operation $trigger '
          "BEGIN SELECT RAISE(ABORT, 'synthetic listing failure'); END",
        );
        await expectLater(
          session.save(),
          throwsA(
            predicate(
              (error) => error.toString().contains('synthetic listing failure'),
            ),
          ),
        );
        expect(await snapshot(), before);
        await db.customStatement('DROP TRIGGER reject_listing_operation');
        final saved = await session.save();
        expect(saved.listing.id, session.listingId);
        expect(await db.select(db.supplierListings).get(), [saved.listing]);
      },
    );
  }

  test('foreign origin, malformed binding and closed generation preserve draft evidence', () async {
    final session = await pending();
    final raw = (await db.settingsDao.getSetting(inputKey()))!;
    await reopen();
    await expectLater(session.save(), throwsStateError);
    final foreign = EditDrafts(db: db, pin: pin, deviceId: 'foreign-device');
    expect(
      await open(owner: foreign),
      isA<BlockedEdit<SupplierListingEditSession>>(),
    );
    expect(await db.settingsDao.getSetting(inputKey()), raw);
    final value = jsonDecode(raw) as Map<String, dynamic>;
    (value['target'] as Map<String, dynamic>)['part'] = 'other-part';
    final malformed = jsonEncode(value);
    await db.settingsDao.setSetting(inputKey(), malformed);
    expect(await open(), isA<BlockedEdit<SupplierListingEditSession>>());
    expect(await db.settingsDao.getSetting(inputKey()), malformed);
  });

  test(
    'receipt refuses changed saved listing and replacement acknowledgement',
    () async {
      final session = await pending();
      final saved = await session.save();
      final raw = (await db.settingsDao.getSetting(controlKey()))!;
      final changed = jsonDecode(raw) as Map<String, dynamic>;
      changed['token'] = 'replacement';
      final replacement = jsonEncode(changed);
      await db.settingsDao.setSetting(controlKey(), replacement);
      await expectLater(saved.acknowledge(), throwsStateError);
      expect(await db.settingsDao.getSetting(controlKey()), replacement);
      await db.settingsDao.setSetting(controlKey(), raw);
      await db.customStatement(
        'UPDATE supplier_listings SET sku = ? WHERE id = ?',
        ['changed', saved.listing.id],
      );
      await expectLater(saved.acknowledge(), throwsStateError);
      await reopen();
      expect(await open(), isA<BlockedEdit<SupplierListingEditSession>>());
      expect(await db.settingsDao.getSetting(controlKey()), raw);
      expect(await db.select(db.supplierListings).get(), hasLength(1));
    },
  );
}
