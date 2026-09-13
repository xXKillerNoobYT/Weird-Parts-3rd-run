import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
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
    final path = await catalog.attachPhoto(
      partId: id,
      bytes: bytes,
      root: dir,
    );
    final part = await catalog.getPart(id);
    expect(part!.photoPath, path);
    expect(File(path).existsSync(), isTrue);

    await pin.setPin('2468');
    await expectLater(
      catalog.attachPhoto(partId: id, bytes: bytes, root: dir),
      throwsA(isA<StateError>()),
    );
  });
}
