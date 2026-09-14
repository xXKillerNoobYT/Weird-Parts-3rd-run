import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/maintenance/maintenance_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late AppDatabase db;
  late String deviceId;
  late PinService pin;
  late MaintenanceRepository maintenance;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deviceId = await db.settingsDao.ensureDeviceId();
    pin = PinService(db.settingsDao);
    maintenance = MaintenanceRepository(db, pin, deviceId);
  });

  tearDown(() async => db.close());

  test('empty shop can create category type variant brand supplier', () async {
    final cat = await maintenance.createCategory('Outlet');
    final type = await maintenance.createStyle(categoryId: cat, name: 'Decora');
    final variant = await maintenance.createType(styleId: type, name: 'GFI');
    final brand = await maintenance.createBrand('Leviton');
    final supplier = await maintenance.createSupplier('SupplyHouse');

    expect((await maintenance.listCategories()).single.id, cat);
    expect((await maintenance.listStyles(categoryId: cat)).single.id, type);
    expect((await maintenance.listTypes(styleId: type)).single.id, variant);
    expect((await maintenance.listBrands()).single.id, brand);
    expect((await maintenance.listSuppliers()).single.id, supplier);
  });

  test('taxonomy writes are blocked when PIN is set and locked', () async {
    await pin.setPin('2468');
    await expectLater(maintenance.createCategory('Outlet'), throwsA(isA<StateError>()));
    await expectLater(maintenance.createBrand('Leviton'), throwsA(isA<StateError>()));
    await expectLater(
      maintenance.createSupplier('SupplyHouse'),
      throwsA(isA<StateError>()),
    );

    await pin.unlock('2468');
    final cat = await maintenance.createCategory('Outlet');
    expect(cat, isNotEmpty);
  });
}
