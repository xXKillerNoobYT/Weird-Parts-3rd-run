import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_tree.dart';

void main() {
  late AppDatabase db;
  late String deviceId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deviceId = await db.settingsDao.ensureDeviceId();
  });
  tearDown(() async => db.close());

  test('shop walk: category is a folder; brand colors stay per brand', () async {
    final cat = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Wire',
      deviceId: deviceId,
    );
    final style = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: cat,
      name: 'Romex',
      deviceId: deviceId,
    );
    final variant = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: style,
      name: '12/2',
      deviceId: deviceId,
    );
    final general = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: '12/2 NM-B',
      deviceId: deviceId,
      categoryId: cat,
      styleId: style,
      typeId: variant,
    );
    final leviton = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Leviton',
      deviceId: deviceId,
    );
    final hubbell = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Hubbell',
      deviceId: deviceId,
    );
    await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: general,
      brandId: leviton,
      mpn: 'LEV-W',
      varianceName: 'White',
      isMain: true,
      deviceId: deviceId,
    );
    await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: general,
      brandId: leviton,
      mpn: 'LEV-I',
      varianceName: 'Ivory',
      deviceId: deviceId,
    );
    await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: general,
      brandId: hubbell,
      mpn: 'HUB-W',
      varianceName: 'White',
      isMain: true,
      deviceId: deviceId,
    );

    final tree = buildCatalogTree(await loadCatalogTreeSnapshot(db));
    expect(tree.where((n) => n.kind == CatalogTreeKind.category), hasLength(1));
    final wire = tree.first;
    expect(wire.label, 'Wire');
    expect(wire.isJobPickable, isFalse);

    final romex = wire.children.single;
    expect(romex.label, 'Romex');
    expect(romex.kind, CatalogTreeKind.type);
    expect(romex.isJobPickable, isFalse);

    final twelveTwo = romex.children.single;
    expect(twelveTwo.label, '12/2');
    expect(twelveTwo.kind, CatalogTreeKind.variant);
    expect(twelveTwo.isJobPickable, isFalse);

    final part = twelveTwo.children.single;
    expect(part.label, '12/2 NM-B');
    expect(part.isJobPickable, isTrue);
    expect(part.kind, CatalogTreeKind.part);

    final brandNames = part.children.map((c) => c.label).toList();
    expect(brandNames, containsAll(['Leviton', 'Hubbell']));
    expect(part.children.every((c) => !c.isJobPickable), isTrue);

    final lev = part.children.firstWhere((c) => c.label == 'Leviton');
    final hub = part.children.firstWhere((c) => c.label == 'Hubbell');
    expect(lev.children.map((c) => c.label), containsAll(['White · LEV-W', 'Ivory · LEV-I']));
    expect(hub.children.map((c) => c.label), ['White · HUB-W']);
    expect(lev.children.first.subtitle, 'Main');
    expect(lev.children.every((c) => c.isJobPickable), isTrue);

    await db.taxonomyDao.renameStyle(style, 'NM-B Romex');
    final again = buildCatalogTree(await loadCatalogTreeSnapshot(db));
    expect(again.first.children.single.label, 'NM-B Romex');
  });

  test('general part hangs with no brand and search keeps ancestors', () async {
    final cat = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Wire',
      deviceId: deviceId,
    );
    final style = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: cat,
      name: 'Romex',
      deviceId: deviceId,
    );
    final variant = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: style,
      name: '12/2',
      deviceId: deviceId,
    );
    await db.partsDao.insertGeneralPart(
      id: newId(),
      name: '12/2 NM-B',
      deviceId: deviceId,
      categoryId: cat,
      styleId: style,
      typeId: variant,
    );
    await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Loose clip',
      deviceId: deviceId,
    );

    final tree = buildCatalogTree(await loadCatalogTreeSnapshot(db));
    final part = tree.first.children.single.children.single.children.single;
    expect(part.children, isEmpty);
    expect(part.subtitle, contains('General'));

    final unassigned = tree.firstWhere((n) => n.kind == CatalogTreeKind.unassigned);
    expect(unassigned.children.single.label, 'Loose clip');

    final filtered = filterCatalogTree(tree, 'NM-B');
    expect(filtered, hasLength(1));
    expect(filtered.first.label, 'Wire');
    expect(
      filtered.first.children.single.children.single.children.single.label,
      '12/2 NM-B',
    );
    expect(filtered.any((n) => n.label == 'Unassigned'), isFalse);
  });

  test('first variance for a brand is main; later option does not steal it', () async {
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Decora',
      deviceId: deviceId,
    );
    final brandId = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Leviton',
      deviceId: deviceId,
    );
    await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: partId,
      brandId: brandId,
      mpn: 'A',
      varianceName: 'White',
      isMain: true,
      deviceId: deviceId,
    );
    await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: partId,
      brandId: brandId,
      mpn: 'B',
      varianceName: 'Ivory',
      isMain: false,
      deviceId: deviceId,
    );
    final rows = await db.partsDao.listBrandVersionsForPart(partId);
    expect(rows.first.varianceName, 'White');
    expect(rows.first.isMain, isTrue);
    expect(rows.where((r) => r.isMain), hasLength(1));
  });
}
