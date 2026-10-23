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
  late String device, partId, versionId;
  late PinService pin;
  late EditDrafts edits;

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

  String slot(CatalogNameTarget target) =>
      'catalog-name-new/supplier'
      '${target.listingVersionId == null ? '' : '/version/${Uri.encodeComponent(target.listingVersionId!)}'}';
  String inputKey(CatalogNameTarget target) =>
      '$editDraftPrefix${slot(target)}/input';
  String controlKey(CatalogNameTarget target) =>
      '$editDraftPrefix${slot(target)}/control';

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

  Future<CatalogNameEditSession> fresh(
    CatalogNameTarget target,
    String raw,
  ) async {
    final opening = await edits.openCatalogName(target);
    expect(opening, isA<FreshEdit<CatalogNameEditSession>>());
    final session = (opening as FreshEdit<CatalogNameEditSession>).session;
    session.replace(CatalogNameInput(nameText: raw));
    await session.flush();
    return session;
  }

  Future<Map<String, dynamic>> storedTarget(CatalogNameTarget target) async =>
      (jsonDecode((await db.settingsDao.getSetting(inputKey(target)))!)
              as Map)['target']
          as Map<String, dynamic>;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-name-draft-');
    file = File('${directory.path}/synthetic.sqlite');
    final fixture = await WarehouseFixture.create(file: file);
    db = fixture.db;
    device = fixture.device;
    partId = fixture.partId;
    bind();
    final brand = await MaintenanceRepository(
      db,
      pin,
      device,
    ).createBrand('Brand');
    versionId = await CatalogRepository(
      db,
      pin,
      device,
    ).createBrandVersion(partId: partId, brandId: brand, mpn: 'SYN-SUPPLIER');
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('both scopes cold Resume exact raw input and reserved identities; save and ack once', () async {
    final targets = [
      const CatalogNameTarget.newSupplier(),
      CatalogNameTarget.newSupplierForVersion(versionId),
    ];
    final before = await snapshot(drafts: false);
    final reserved = <String>[];
    final listingIds = <String?>[];
    for (final target in targets) {
      final session = await fresh(target, '  Supplier\npending · exact  ');
      reserved.add(session.recordId);
      listingIds.add(
        (await storedTarget(target))['listingReserved'] as String?,
      );
    }
    expect(await snapshot(drafts: false), before);
    await reopen();
    for (var i = 0; i < targets.length; i++) {
      final target = targets[i];
      final opening = await edits.openCatalogName(target);
      expect(opening, isA<RecoverableEdit<CatalogNameEditSession>>());
      final session = await (opening as RecoverableEdit<CatalogNameEditSession>)
          .resume();
      expect(session.initial.nameText, '  Supplier\npending · exact  ');
      expect(session.recordId, reserved[i]);
      expect((await storedTarget(target))['listingReserved'], listingIds[i]);
      final saved = await session.save();
      expect(
        (saved.kind, saved.id, saved.name),
        (CatalogNameKind.supplier, reserved[i], 'Supplier\npending · exact'),
      );
      expect((await session.save()).id, saved.id);
    }
    final suppliers = await db.select(db.suppliers).get();
    expect(suppliers, hasLength(2));
    expect(suppliers.map((s) => s.name).toSet(), {'Supplier\npending · exact'});
    final listing = (await db.select(db.supplierListings).get()).single;
    expect(
      (listing.id, listing.supplierId, listing.brandVersionId, listing.sku),
      (listingIds[1], reserved[1], versionId, ''),
    );
    final savedRows = await snapshot(drafts: false);
    await reopen();
    for (var i = 0; i < targets.length; i++) {
      final receipt =
          await edits.openCatalogName(targets[i]) as CatalogNameSaved;
      expect(receipt.id, reserved[i]);
      expect(await db.settingsDao.getSetting(inputKey(targets[i])), isNull);
      await receipt.acknowledge();
      await receipt.acknowledge();
      expect(await db.settingsDao.getSetting(controlKey(targets[i])), isNull);
    }
    expect(await snapshot(drafts: false), savedRows);
  });

  test('root Supplier has no taxonomy dependency and optional parent selection stays recoverable', () async {
    const target = CatalogNameTarget.newSupplier();
    final supplier = await fresh(target, '  Independent Supplier  ');
    expect((await storedTarget(target)).keys.toSet(), {
      'kind',
      'entity',
      'reserved',
    });
    await db.customStatement('UPDATE categories SET revision = revision + 1');
    final saved = await supplier.save();
    expect(await db.select(db.supplierListings).get(), isEmpty);
    final parent =
        (await edits.openPart(partId) as FreshEdit<PartEditSession>).session;
    expect(parent.initial.defaultSupplierId, isNull);
    final p = parent.initial;
    parent.replace(
      PartInput(
        nameText: '  Parent raw  ',
        descriptionText: ' raw description ',
        specsText: p.specsText,
        uomText: ' ea ',
        categoryId: p.categoryId,
        styleId: p.styleId,
        typeId: p.typeId,
        defaultSupplierId: saved.id,
        active: p.active,
      ),
    );
    await parent.flush();
    await saved.acknowledge();
    await reopen();
    final resumed = await (await edits.openPart(
      partId,
    ) as RecoverableEdit<PartEditSession>).resume();
    expect(resumed.initial.defaultSupplierId, saved.id);
    expect(resumed.initial.nameText, '  Parent raw  ');
    expect(resumed.initial.descriptionText, ' raw description ');
    final current = resumed.initial;
    resumed.replace(
      PartInput(
        nameText: current.nameText,
        descriptionText: current.descriptionText,
        specsText: current.specsText,
        uomText: current.uomText,
        categoryId: current.categoryId,
        styleId: current.styleId,
        typeId: current.typeId,
        defaultSupplierId: null,
        active: current.active,
      ),
    );
    await resumed.flush();
    await resumed.leave(LeaveIntent.discard);
    expect((await db.partsDao.getPart(partId))!.defaultSupplierId, isNull);
    expect((await db.select(db.suppliers).get()).single.id, saved.id);
  });

  test(
    'root Supplier creation works without any taxonomy hierarchy rows',
    () async {
      await db.customStatement('DELETE FROM types');
      await db.customStatement('DELETE FROM styles');
      await db.customStatement('DELETE FROM categories');
      final before = await snapshot(drafts: false);
      final session = await fresh(
        const CatalogNameTarget.newSupplier(),
        '  No hierarchy  ',
      );
      final saved = await session.save();
      await saved.acknowledge();
      final after = await snapshot(drafts: false);
      before.remove('suppliers');
      after.remove('suppliers');
      expect(after, before);
      expect((await db.select(db.suppliers).get()).single.name, 'No hierarchy');
      expect((await db.partsDao.getPart(partId))!.defaultSupplierId, isNull);
    },
  );

  test('blank, discard, PIN and company refusal preserve exact input and business rows', () async {
    final target = CatalogNameTarget.newSupplierForVersion(versionId);
    final blank = await fresh(target, ' \n\t ');
    var before = await snapshot();
    await expectLater(blank.save(), throwsStateError);
    expect(await snapshot(), before);
    await blank.leave(LeaveIntent.discard);
    final session = await fresh(target, '  Denied Supplier  ');
    await pin.setPin('1234');
    pin.lock();
    before = await snapshot();
    await expectLater(session.save(), throwsStateError);
    expect(await snapshot(), before);
    await pin.unlock('1234');
    await db.customStatement(
      'INSERT INTO company_join_events '
      '(request_id, ordinal, kind, evidence_bytes) '
      "VALUES ('supplier-denial', 1, 'blocked', 'synthetic')",
    );
    before = await snapshot();
    await expectLater(session.save(), throwsStateError);
    expect(await snapshot(), before);
  });

  for (final collision in ['supplier', 'listing']) {
    test(
      '$collision reserved collision preserves competing rows and draft',
      () async {
        final target = CatalogNameTarget.newSupplierForVersion(versionId);
        final session = await fresh(target, '  Collided Supplier  ');
        if (collision == 'supplier') {
          await MaintenanceRepository(
            db,
            pin,
            device,
          ).createSupplier('Competing Supplier', reservedId: session.recordId);
        } else {
          final other = await MaintenanceRepository(
            db,
            pin,
            device,
          ).createSupplier('Other');
          await CatalogRepository(db, pin, device).createSupplierListing(
            brandVersionId: versionId,
            supplierId: other,
            sku: 'existing',
            reservedId:
                (await storedTarget(target))['listingReserved'] as String,
          );
        }
        final before = await snapshot();
        await expectLater(session.save(), throwsStateError);
        expect(await snapshot(), before);
      },
    );
  }

  for (final fault in [
    'version-changed',
    'version-deleted',
    'part-changed',
    'part-deleted',
  ]) {
    test('$fault blocks pending companion Save and cold Resume', () async {
      final target = CatalogNameTarget.newSupplierForVersion(versionId);
      final session = await fresh(target, '  Stale companion  ');
      final table = fault.startsWith('version') ? 'brand_versions' : 'parts';
      final id = fault.startsWith('version') ? versionId : partId;
      final update = fault.endsWith('deleted')
          ? 'deleted_at = 1'
          : 'revision = revision + 1';
      await db.customStatement('UPDATE $table SET $update WHERE id = ?', [id]);
      final before = await snapshot();
      await expectLater(session.save(), throwsStateError);
      expect(await snapshot(), before);
      await reopen();
      expect(
        await edits.openCatalogName(target),
        isA<BlockedEdit<CatalogNameEditSession>>(),
      );
      expect(await snapshot(), before);
    });
  }

  for (final failure in ['listing', 'receipt']) {
    test(
      '$failure SQL failure rolls back Supplier plus listing and preserves draft',
      () async {
        final target = CatalogNameTarget.newSupplierForVersion(versionId);
        final session = await fresh(target, '  Atomic Supplier  ');
        final before = await snapshot();
        if (failure == 'listing') {
          await db.customStatement(
            'CREATE TRIGGER reject_supplier_operation BEFORE INSERT ON supplier_listings '
            "BEGIN SELECT RAISE(ABORT, 'synthetic supplier failure'); END",
          );
        } else {
          final key = controlKey(target).replaceAll("'", "''");
          await db.customStatement(
            'CREATE TRIGGER reject_supplier_operation BEFORE UPDATE ON app_settings '
            "WHEN NEW.key = '$key' AND instr(NEW.value, '\"phase\":\"committed\"') > 0 "
            "BEGIN SELECT RAISE(ABORT, 'synthetic supplier failure'); END",
          );
        }
        await expectLater(
          session.save(),
          throwsA(
            predicate(
              (error) =>
                  error.toString().contains('synthetic supplier failure'),
            ),
          ),
        );
        expect(await snapshot(), before);
        await db.customStatement('DROP TRIGGER reject_supplier_operation');
        final saved = await session.save();
        expect((await db.select(db.suppliers).get()).single.id, saved.id);
        expect(
          (await db.select(db.supplierListings).get()).single.supplierId,
          saved.id,
        );
      },
    );
  }

  test('foreign origin and malformed Supplier targets preserve exact draft evidence', () async {
    final target = CatalogNameTarget.newSupplierForVersion(versionId);
    await fresh(target, '  Foreign Supplier input  ');
    final raw = (await db.settingsDao.getSetting(inputKey(target)))!;
    await reopen();
    final foreign = EditDrafts(
      db: db,
      pin: pin,
      deviceId: 'foreign-supplier-device',
    );
    expect(
      await foreign.openCatalogName(target),
      isA<BlockedEdit<CatalogNameEditSession>>(),
    );
    expect(await db.settingsDao.getSetting(inputKey(target)), raw);
    for (final fault in ['rename', 'parent', 'half-context', 'other-version']) {
      final record = jsonDecode(raw) as Map<String, dynamic>;
      final changed = record['target'] as Map<String, dynamic>;
      switch (fault) {
        case 'rename':
          changed['kind'] = 'catalog-name-rename';
          changed['id'] = changed.remove('reserved');
        case 'parent':
          changed['parent'] = partId;
        case 'half-context':
          changed.remove('listingReserved');
        case 'other-version':
          changed['listingVersion'] = 'other-version';
      }
      final malformed = jsonEncode(record);
      await db.settingsDao.setSetting(inputKey(target), malformed);
      expect(
        await edits.openCatalogName(target),
        isA<BlockedEdit<CatalogNameEditSession>>(),
        reason: fault,
      );
      expect(await db.settingsDao.getSetting(inputKey(target)), malformed);
    }
  });

  test('companion receipt rejects malformed contexts, changed rows and replacement ack', () async {
    final target = CatalogNameTarget.newSupplierForVersion(versionId);
    final session = await fresh(target, '  Receipt Supplier  ');
    final saved = await session.save();
    final raw = (await db.settingsDao.getSetting(controlKey(target)))!;
    final before = await snapshot(drafts: false);
    for (final fault in [
      'rename',
      'missing-listing',
      'listing-id',
      'part',
      'root-context',
    ]) {
      final control = jsonDecode(raw) as Map<String, dynamic>;
      final result = control['result'] as Map<String, dynamic>;
      final stored =
          jsonDecode(result['target'] as String) as Map<String, dynamic>;
      switch (fault) {
        case 'rename':
          stored['kind'] = 'catalog-name-rename';
          stored['id'] = stored.remove('reserved');
        case 'missing-listing':
          result.remove('listingRow');
        case 'listing-id':
          result['listing'] = saved.id;
        case 'part':
          result['listingPart'] = 'other-part';
        case 'root-context':
          stored.remove('listingVersion');
          stored.remove('listingReserved');
      }
      result['target'] = jsonEncode(stored);
      final malformed = jsonEncode(control);
      await db.settingsDao.setSetting(controlKey(target), malformed);
      expect(
        await edits.openCatalogName(target),
        isA<BlockedEdit<CatalogNameEditSession>>(),
        reason: fault,
      );
      expect(await db.settingsDao.getSetting(controlKey(target)), malformed);
      expect(await snapshot(drafts: false), before);
    }
    await db.settingsDao.setSetting(controlKey(target), raw);
    await db.customStatement(
      'UPDATE supplier_listings SET sku = ? WHERE supplier_id = ?',
      ['changed', saved.id],
    );
    expect(
      await edits.openCatalogName(target),
      isA<BlockedEdit<CatalogNameEditSession>>(),
    );
    expect(await db.settingsDao.getSetting(controlKey(target)), raw);
    await db.customStatement(
      'UPDATE supplier_listings SET sku = ? WHERE supplier_id = ?',
      ['', saved.id],
    );
    final receipt = await edits.openCatalogName(target) as CatalogNameSaved;
    const replacement = '{"phase":"editing","token":"replacement-supplier"}';
    await db.settingsDao.setSetting(controlKey(target), replacement);
    await expectLater(receipt.acknowledge(), throwsStateError);
    expect(await db.settingsDao.getSetting(controlKey(target)), replacement);
  });

  test('companion receipt allows metadata changes but refuses reparenting until restored', () async {
    final originalPart = (await db.partsDao.getPart(partId))!;
    final originalVersion = (await db.select(db.brandVersions).get())
        .singleWhere((version) => version.id == versionId);
    final otherPartId = await CatalogRepository(db, pin, device)
        .createGeneralPart(
          name: 'Other valid Part',
          categoryId: originalPart.categoryId,
          styleId: originalPart.styleId,
          typeId: originalPart.typeId,
        );
    final target = CatalogNameTarget.newSupplierForVersion(versionId);
    final session = await fresh(target, '  Metadata boundary Supplier  ');
    final saved = await session.save();
    final suppliers = await db.select(db.suppliers).get();
    final listings = await db.select(db.supplierListings).get();
    final raw = (await db.settingsDao.getSetting(controlKey(target)))!;

    await db.customStatement(
      'UPDATE brand_versions SET mpn = ?, revision = revision + 1 WHERE id = ?',
      ['Metadata after Supplier Save', versionId],
    );
    await db.customStatement(
      'UPDATE parts SET description = ?, revision = revision + 1 WHERE id = ?',
      ['Part metadata after Supplier Save', partId],
    );
    await reopen();
    final allowed = await edits.openCatalogName(target) as CatalogNameSaved;
    expect((allowed.id, allowed.name), (saved.id, saved.name));
    expect(await db.settingsDao.getSetting(controlKey(target)), raw);

    await db.customStatement(
      'UPDATE brand_versions SET part_id = ?, revision = revision + 1 WHERE id = ?',
      [otherPartId, versionId],
    );
    final reparented = await snapshot();
    expect(
      await edits.openCatalogName(target),
      isA<BlockedEdit<CatalogNameEditSession>>(),
    );
    await expectLater(allowed.acknowledge(), throwsStateError);
    expect(await db.settingsDao.getSetting(controlKey(target)), raw);
    expect(await snapshot(), reparented);

    await db.customStatement(
      'UPDATE brand_versions SET part_id = ?, revision = revision + 1 WHERE id = ?',
      [partId, versionId],
    );
    await reopen();
    final beforeAck = await snapshot(drafts: false);
    final recovered = await edits.openCatalogName(target) as CatalogNameSaved;
    expect((recovered.id, recovered.name), (saved.id, saved.name));
    await recovered.acknowledge();
    await recovered.acknowledge();
    expect(await db.settingsDao.getSetting(inputKey(target)), isNull);
    expect(await db.settingsDao.getSetting(controlKey(target)), isNull);
    expect(await snapshot(drafts: false), beforeAck);
    expect(await db.select(db.suppliers).get(), suppliers);
    expect(await db.select(db.supplierListings).get(), listings);
    final version = (await db.select(db.brandVersions).get()).singleWhere(
      (version) => version.id == versionId,
    );
    expect(
      (version.partId, version.mpn, version.revision),
      (partId, 'Metadata after Supplier Save', originalVersion.revision + 3),
    );
    final part = (await db.partsDao.getPart(partId))!;
    expect(
      (part.description, part.revision),
      ('Part metadata after Supplier Save', originalPart.revision + 1),
    );
  });

  for (final table in ['suppliers', 'brand_versions', 'parts']) {
    test(
      'deleted saved $table blocks companion receipt and acknowledgement',
      () async {
        final target = CatalogNameTarget.newSupplierForVersion(versionId);
        final session = await fresh(target, '  Saved before deletion  ');
        final receipt = await session.save();
        final id = table == 'suppliers'
            ? receipt.id
            : table == 'brand_versions'
            ? versionId
            : partId;
        await db.customStatement(
          'UPDATE $table SET deleted_at = 1 WHERE id = ?',
          [id],
        );
        final before = await snapshot();
        await expectLater(receipt.acknowledge(), throwsStateError);
        expect(await snapshot(), before);
        await reopen();
        expect(
          await edits.openCatalogName(target),
          isA<BlockedEdit<CatalogNameEditSession>>(),
        );
        expect(await snapshot(), before);
      },
    );
  }
}
