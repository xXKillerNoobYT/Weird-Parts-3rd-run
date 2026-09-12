import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
    );
    final part = await catalog.getPart(id);
    expect(part!.name, 'Relay 24V');
    expect(part.description, 'Control relay');
    expect(part.defaultSupplierId, supplierId);
  });
}
