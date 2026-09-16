import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/catalog_tree.dart';
import 'package:wired_parts/features/catalog/part_photo_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late AppDatabase db;
  late String deviceId;
  late PinService pin;
  late CatalogRepository catalog;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deviceId = await db.settingsDao.ensureDeviceId();
    pin = PinService(db.settingsDao);
    catalog = CatalogRepository(db, pin, deviceId);
  });

  tearDown(() async => db.close());

  test('create part allowed when no PIN set', () async {
    final id = await catalog.createGeneralPart(name: 'Valve');
    final part = await catalog.getPart(id);
    expect(part!.name, 'Valve');
  });

  test('create part blocked when PIN set and locked', () async {
    await pin.setPin('2468');
    await expectLater(
      catalog.createGeneralPart(name: 'Blocked'),
      throwsA(isA<StateError>()),
    );
  });

  test('update part after unlock', () async {
    final supplierId = await db.taxonomyDao.insertSupplier(
      id: newId(),
      name: 'SupplyCo',
      deviceId: deviceId,
    );
    await pin.setPin('2468');
    await pin.unlock('2468');

    final id = await catalog.createGeneralPart(
      name: 'Relay',
      defaultSupplierId: supplierId,
    );
    await catalog.updatePart(
      partId: id,
      name: 'Relay 24V',
      description: 'Control relay',
      uom: 'ea',
      defaultSupplierId: supplierId,
      active: true,
      categoryId: null,
      styleId: null,
      typeId: null,
      requireNestedTaxonomy: false,
    );
    final part = await catalog.getPart(id);
    expect(part!.name, 'Relay 24V');
    expect(part.description, 'Control relay');
    expect(part.defaultSupplierId, supplierId);
    expect(part.revision, 2);
  });

  test('variance write blocked when PIN set and locked', () async {
    await pin.setPin('2468');
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Outlet',
      deviceId: deviceId,
    );
    final brandId = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Leviton',
      deviceId: deviceId,
    );
    await expectLater(
      catalog.createBrandVersion(
        partId: partId,
        brandId: brandId,
        mpn: 'X',
        varianceName: 'White',
        isMain: true,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('attach photo stores path; locked PIN blocks it', () async {
    final dir = Directory.systemTemp.createTempSync('wp-repo-photo-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final raw = img.Image(width: 16, height: 16);
    img.fill(raw, color: img.ColorRgb8(9, 9, 9));
    final bytes = Uint8List.fromList(img.encodePng(raw));

    final id = await catalog.createGeneralPart(name: 'With photo');
    final stored = await catalog.attachPhoto(
      partId: id,
      bytes: bytes,
      root: dir,
    );
    final part = await catalog.getPart(id);
    expect(part!.photoPath, stored);
    expect(p.isAbsolute(stored), isFalse);
    final file = await const PartPhotoStore().resolveFile(stored, root: dir);
    expect(file.existsSync(), isTrue);

    await pin.setPin('2468');
    await expectLater(
      catalog.attachPhoto(partId: id, bytes: bytes, root: dir),
      throwsA(isA<StateError>()),
    );
  });

  test('replacing a photo stores a new relative file and deletes the old one', () async {
    final dir = Directory.systemTemp.createTempSync('wp-repo-photo-replace-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 8, height: 8)),
    );
    final id = await catalog.createGeneralPart(name: 'Swap photo');
    final first = await catalog.attachPhoto(partId: id, bytes: bytes, root: dir);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final second = await catalog.attachPhoto(partId: id, bytes: bytes, root: dir);
    expect(second, isNot(first));
    expect(p.isAbsolute(second), isFalse);
    expect(
      (await const PartPhotoStore().resolveFile(first, root: dir)).existsSync(),
      isFalse,
    );
    expect(
      (await const PartPhotoStore().resolveFile(second, root: dir)).existsSync(),
      isTrue,
    );
  });

  test('delete part is PIN-gated and tombstones the row', () async {
    final dir = Directory.systemTemp.createTempSync('wp-del-tombstone-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final id = await catalog.createGeneralPart(name: 'Scrap');
    await pin.setPin('2468');
    await expectLater(
      catalog.deletePart(id, root: dir),
      throwsA(isA<StateError>()),
    );
    expect(await catalog.getPart(id), isNotNull);

    await pin.unlock('2468');
    await catalog.deletePart(id, root: dir);
    expect(await catalog.getPart(id), isNull);
    expect(
      (await catalog.listParts(activeOnly: false)).map((p) => p.id),
      isNot(contains(id)),
    );
  });

  test('delete part removes photo files', () async {
    final dir = Directory.systemTemp.createTempSync('wp-repo-photo-del-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 8, height: 8)),
    );
    final id = await catalog.createGeneralPart(name: 'With photo');
    final stored = await catalog.attachPhoto(
      partId: id,
      bytes: bytes,
      root: dir,
    );
    await catalog.deletePart(id, root: dir);
    expect(
      (await const PartPhotoStore().resolveFile(stored, root: dir)).existsSync(),
      isFalse,
    );
  });

  test('empty folder deletes; occupied folder is refused', () async {
    final emptyId = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Empty',
      deviceId: deviceId,
    );
    final occupiedId = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Occupied',
      deviceId: deviceId,
    );
    await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: occupiedId,
      name: 'Type',
      deviceId: deviceId,
    );

    await catalog.deleteEmptyFolder(
      kind: CatalogTreeKind.category,
      id: emptyId,
    );
    expect(
      (await db.taxonomyDao.listCategories()).map((c) => c.id),
      isNot(contains(emptyId)),
    );

    await expectLater(
      catalog.deleteEmptyFolder(
        kind: CatalogTreeKind.category,
        id: occupiedId,
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      (await db.taxonomyDao.listCategories()).map((c) => c.id),
      contains(occupiedId),
    );

    await pin.setPin('2468');
    await expectLater(
      catalog.deleteEmptyFolder(
        kind: CatalogTreeKind.category,
        id: occupiedId,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('deleted part stays off the catalog but job lines remain', () async {
    final dir = Directory.systemTemp.createTempSync('wp-del-jobline-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final partId = await catalog.createGeneralPart(name: 'On a job');
    final jobId = await db.jobsDao.insertJob(
      id: newId(),
      name: 'Job',
      deviceId: deviceId,
    );
    await db.jobsDao.insertJobLine(
      id: newId(),
      jobId: jobId,
      partId: partId,
      brandVersionId: null,
      neededQty: 2,
      shopPullQty: 0,
      deviceId: deviceId,
    );
    expect(await catalog.countJobLinesForPart(partId), 1);
    await catalog.deletePart(partId, root: dir);
    expect(await catalog.getPart(partId), isNull);
    expect(await catalog.countJobLinesForPart(partId), 1);
  });

  test('create general part with nested required refuses empty folders',
      () async {
    await expectLater(
      catalog.createGeneralPart(
        name: 'Unfiled',
        requireNestedTaxonomy: true,
      ),
      throwsA(isA<StateError>()),
    );

    final cat = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Outlet',
      deviceId: deviceId,
    );
    final type = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: cat,
      name: 'Decora',
      deviceId: deviceId,
    );
    final variant = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: type,
      name: 'GFI',
      deviceId: deviceId,
    );
    final id = await catalog.createGeneralPart(
      name: 'Decora GFI',
      categoryId: cat,
      styleId: type,
      typeId: variant,
      requireNestedTaxonomy: true,
    );
    final part = await catalog.getPart(id);
    expect(part!.name, 'Decora GFI');
    expect(part.categoryId, cat);
    expect(part.styleId, type);
    expect(part.typeId, variant);
  });

  test('update part requires nested category type variant', () async {
    final id = await catalog.createGeneralPart(name: 'Unfiled');
    await expectLater(
      catalog.updatePart(
        partId: id,
        name: 'Unfiled',
        description: '',
        uom: 'ea',
        active: true,
        categoryId: null,
        styleId: null,
        typeId: null,
      ),
      throwsA(isA<StateError>()),
    );

    final cat = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Outlet',
      deviceId: deviceId,
    );
    final type = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: cat,
      name: 'Decora',
      deviceId: deviceId,
    );
    final variant = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: type,
      name: 'GFI',
      deviceId: deviceId,
    );
    await catalog.updatePart(
      partId: id,
      name: 'Decora GFI',
      description: '',
      uom: 'ea',
      active: true,
      categoryId: cat,
      styleId: type,
      typeId: variant,
    );
    final part = await catalog.getPart(id);
    expect(part!.name, 'Decora GFI');
    expect(part.categoryId, cat);
    expect(part.styleId, type);
    expect(part.typeId, variant);
  });

  test('update part rejects type from another category', () async {
    final catA = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Outlet',
      deviceId: deviceId,
    );
    final catB = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Switch',
      deviceId: deviceId,
    );
    final typeB = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: catB,
      name: 'Toggle',
      deviceId: deviceId,
    );
    final variantB = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: typeB,
      name: 'Single pole',
      deviceId: deviceId,
    );
    final id = await catalog.createGeneralPart(name: 'Mismatch');
    await expectLater(
      catalog.updatePart(
        partId: id,
        name: 'Mismatch',
        description: '',
        uom: 'ea',
        active: true,
        categoryId: catA,
        styleId: typeB,
        typeId: variantB,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('update part rejects variant from another type', () async {
    final cat = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Outlet',
      deviceId: deviceId,
    );
    final typeA = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: cat,
      name: 'Decora',
      deviceId: deviceId,
    );
    final typeB = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: cat,
      name: 'Duplex',
      deviceId: deviceId,
    );
    final variantB = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: typeB,
      name: 'Tamper resistant',
      deviceId: deviceId,
    );
    final id = await catalog.createGeneralPart(name: 'Crossed');
    await expectLater(
      catalog.updatePart(
        partId: id,
        name: 'Crossed',
        description: '',
        uom: 'ea',
        active: true,
        categoryId: cat,
        styleId: typeA,
        typeId: variantB,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('brand version before nested save still allows taxonomy update', () async {
    final id = await catalog.createGeneralPart(name: 'Decora GFI');
    final cat = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Outlet',
      deviceId: deviceId,
    );
    final type = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: cat,
      name: 'Decora',
      deviceId: deviceId,
    );
    final variant = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: type,
      name: 'GFI',
      deviceId: deviceId,
    );
    final brandId = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Leviton',
      deviceId: deviceId,
    );
    await catalog.createBrandVersion(
      partId: id,
      brandId: brandId,
      mpn: 'R50-W',
      varianceName: 'White',
      isMain: true,
    );
    final unsaved = await catalog.getPart(id);
    expect(unsaved!.categoryId, isNull);
    expect(unsaved.styleId, isNull);
    expect(unsaved.typeId, isNull);

    await catalog.updatePart(
      partId: id,
      name: 'Decora GFI',
      description: '',
      uom: 'ea',
      active: true,
      categoryId: cat,
      styleId: type,
      typeId: variant,
    );
    final part = await catalog.getPart(id);
    expect(part!.categoryId, cat);
    expect(part.styleId, type);
    expect(part.typeId, variant);
    expect(await catalog.listBrandVersionsForPart(id), hasLength(1));
  });
}
