import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  test('create general part with default supplier and optional brand listing', () async {
    final deviceId = await db.settingsDao.ensureDeviceId();
    final supplierId = await db.taxonomyDao.insertSupplier(
      id: newId(),
      name: 'SupplyHouse',
      deviceId: deviceId,
    );
    final brandId = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Watts',
      deviceId: deviceId,
    );
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: '3/4 isolation valve',
      defaultSupplierId: supplierId,
      deviceId: deviceId,
    );
    final bvId = await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: partId,
      brandId: brandId,
      mpn: 'W-123',
      deviceId: deviceId,
    );
    await db.partsDao.insertSupplierListing(
      id: newId(),
      brandVersionId: bvId,
      supplierId: supplierId,
      sku: 'SH-9',
      deviceId: deviceId,
    );

    final part = await db.partsDao.getPart(partId);
    expect(part!.name, '3/4 isolation valve');
    expect(part.defaultSupplierId, supplierId);
    final listings = await db.partsDao.listingsForBrandVersion(bvId);
    expect(listings, hasLength(1));
  });

  test('softDeletePart tombstones the part and brand versions', () async {
    final deviceId = await db.settingsDao.ensureDeviceId();
    final brandId = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Watts',
      deviceId: deviceId,
    );
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Valve',
      deviceId: deviceId,
    );
    final bvId = await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: partId,
      brandId: brandId,
      mpn: 'W-1',
      deviceId: deviceId,
    );
    await db.partsDao.insertSupplierListing(
      id: newId(),
      brandVersionId: bvId,
      supplierId: await db.taxonomyDao.insertSupplier(
        id: newId(),
        name: 'Co',
        deviceId: deviceId,
      ),
      sku: 'X',
      deviceId: deviceId,
    );

    await db.partsDao.softDeletePart(partId);
    expect(await db.partsDao.getPart(partId), isNull);
    expect(await db.partsDao.listBrandVersionsForPart(partId), isEmpty);
    expect(await db.partsDao.listingsForBrandVersion(bvId), isEmpty);

    final tombstoned = await db.partsDao.getPart(partId, includeDeleted: true);
    expect(tombstoned, isNotNull);
    expect(tombstoned!.name, 'Valve');
    expect(
      await db.partsDao.listBrandVersionsForPart(partId, includeDeleted: true),
      hasLength(1),
    );
    expect(
      await db.partsDao.listingsForBrandVersion(bvId, includeDeleted: true),
      hasLength(1),
    );
    expect(
      (await db.partsDao.listParts(activeOnly: false, includeDeleted: true))
          .map((p) => p.id),
      contains(partId),
    );
    expect(
      (await db.partsDao.listParts(activeOnly: false)).map((p) => p.id),
      isNot(contains(partId)),
    );
  });
}
