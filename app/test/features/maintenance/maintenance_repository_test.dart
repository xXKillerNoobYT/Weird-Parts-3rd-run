import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/catalog_tree.dart';
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

  test(
    'inline child creation refuses missing or deleted parents without writes',
    () async {
      final catalog = CatalogRepository(db, pin, deviceId);
      await expectLater(
        maintenance.createStyle(categoryId: 'missing', name: 'Denied'),
        throwsStateError,
      );
      await expectLater(
        maintenance.createType(styleId: 'missing', name: 'Denied'),
        throwsStateError,
      );
      final deletedCategory = await maintenance.createCategory(
        'Deleted category',
      );
      await catalog.deleteEmptyFolder(
        kind: CatalogTreeKind.category,
        id: deletedCategory,
      );
      await expectLater(
        maintenance.createStyle(categoryId: deletedCategory, name: 'Denied'),
        throwsStateError,
      );
      final category = await maintenance.createCategory('Live category');
      final deletedStyle = await maintenance.createStyle(
        categoryId: category,
        name: 'Deleted type',
      );
      await catalog.deleteEmptyFolder(
        kind: CatalogTreeKind.type,
        id: deletedStyle,
      );
      await expectLater(
        maintenance.createType(styleId: deletedStyle, name: 'Denied'),
        throwsStateError,
      );
      expect(await maintenance.listStyles(), isEmpty);
      expect(await maintenance.listTypes(), isEmpty);
    },
  );

  for (final childKind in ['type', 'variant']) {
    test(
      'inline $childKind creation and parent deletion serialize in either order',
      () async {
        final catalog = CatalogRepository(db, pin, deviceId);
        for (final deleteFirst in [false, true]) {
          final category = await maintenance.createCategory(
            'Synthetic category',
          );
          final String parent;
          final CatalogTreeKind parentKind;
          if (childKind == 'type') {
            parent = category;
            parentKind = CatalogTreeKind.category;
          } else {
            parent = await maintenance.createStyle(
              categoryId: category,
              name: 'Synthetic type',
            );
            parentKind = CatalogTreeKind.type;
          }
          Future<bool> create() async {
            try {
              if (childKind == 'type') {
                await maintenance.createStyle(
                  categoryId: parent,
                  name: 'Concurrent child',
                );
              } else {
                await maintenance.createType(
                  styleId: parent,
                  name: 'Concurrent child',
                );
              }
              return true;
            } on StateError {
              return false;
            }
          }

          Future<bool> remove() async {
            try {
              await catalog.deleteEmptyFolder(kind: parentKind, id: parent);
              return true;
            } on StateError {
              return false;
            }
          }

          final results = await Future.wait(
            deleteFirst ? [remove(), create()] : [create(), remove()],
          );
          expect(results.where((result) => result), hasLength(1));
          if (childKind == 'type') {
            final exists = (await maintenance.listCategories()).any(
              (c) => c.id == parent,
            );
            expect(
              (await maintenance.listStyles(categoryId: parent)).isNotEmpty,
              exists,
            );
          } else {
            final exists = (await maintenance.listStyles()).any(
              (s) => s.id == parent,
            );
            expect(
              (await maintenance.listTypes(styleId: parent)).isNotEmpty,
              exists,
            );
          }
        }
      },
    );
  }

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
    await expectLater(
      maintenance.createCategory('Outlet'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      maintenance.createBrand('Leviton'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      maintenance.createSupplier('SupplyHouse'),
      throwsA(isA<StateError>()),
    );

    await pin.unlock('2468');
    final cat = await maintenance.createCategory('Outlet');
    expect(cat, isNotEmpty);
  });
}
