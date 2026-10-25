import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/jobs/job_line_qty.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/warehouse/warehouse_repository.dart';

import '../../tool/mock_shop/adapter.dart';
import '../../tool/mock_shop/fixture.dart';
import '../../tool/mock_shop_app.dart' as inspection_app;

void main() {
  late MockShopFixture fixture;
  late MockLocalWorkspace workspace;
  final inputs = Directory('test/fixtures/mock_shop');
  setUpAll(() {
    fixture = MockShopFixture.read(inputs);
  });
  setUp(() async {
    workspace = await MockLocalWorkspace.create();
  });
  tearDown(() => workspace.close());

  test(
    'inspection entrypoint refuses default launch and uses owned app basename',
    () async {
      expect(workspace.databaseFile.uri.pathSegments.last, kSqliteFileName);
      expect(
        await workspace.db.settingsDao.ensureDeviceId(),
        workspace.deviceId,
      );
      final before = await workspace.publicBusinessDigest();
      await expectLater(inspection_app.main(), throwsStateError);
      expect(await workspace.publicBusinessDigest(), before);
      await workspace.reopen();
      expect(
        await workspace.db.settingsDao.ensureDeviceId(),
        workspace.deviceId,
      );
    },
  );

  test(
    'owned database and PIN handles cannot be rebound to another store',
    () async {
      final foreign = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(foreign.close);
      final originalDb = workspace.db;
      final originalPin = workspace.pin;
      expect(
        () => (workspace as dynamic).db = foreign,
        throwsNoSuchMethodError,
      );
      expect(
        () => (workspace as dynamic).pin = PinService(foreign.settingsDao),
        throwsNoSuchMethodError,
      );
      expect(identical(workspace.db, originalDb), isTrue);
      expect(identical(workspace.pin, originalPin), isTrue);
      await workspace.import(fixture);
      expect(await foreign.select(foreign.parts).get(), isEmpty);
      expect(
        await workspace.db.select(workspace.db.parts).get(),
        hasLength(59),
      );
    },
  );

  test(
    'frozen input retains 59 variants, 66 offers and original identities',
    () {
      expect(fixture.variants, hasLength(59));
      expect(fixture.offers, hasLength(66));
      expect(fixture.jobs, hasLength(7));
      expect(
        fixture.nativeId('job', 'JOB-001'),
        '7b161081-fc87-5961-b138-c498fadd3078',
      );
      expect(
        fixture.nativeId('job', 'JOB-001'),
        isNot(fixture.nativeId('job', 'JOB-002')),
      );
      expect(() => fixture.jobs.clear(), throwsUnsupportedError);
    },
  );

  test(
    'raw and gzip packages retain the original catalog bytes and hashes',
    () {
      final sourceBytes = MockShopFixture.readSourceBytes(inputs);
      expect(sha256.convert(sourceBytes).toString(), mockShopSourceSha256);
      final rawPackage = Directory.systemTemp.createTempSync('mock-shop-raw-');
      addTearDown(() => rawPackage.deleteSync(recursive: true));
      File('${rawPackage.path}/source-catalog.json')
          .writeAsBytesSync(sourceBytes);
      File('${rawPackage.path}/shop.json')
          .writeAsBytesSync(File('${inputs.path}/shop.json').readAsBytesSync());
      expect(MockShopFixture.readSourceBytes(rawPackage), sourceBytes);
      final rawFixture = MockShopFixture.read(rawPackage);
      expect(rawFixture.sha256Value, mockShopFixtureSha256);
      expect(canonicalMockJson(rawFixture.raw), canonicalMockJson(fixture.raw));
    },
  );

  test('a package containing both catalog encodings is refused', () {
    final ambiguous = Directory.systemTemp.createTempSync(
      'mock-shop-ambiguous-',
    );
    addTearDown(() => ambiguous.deleteSync(recursive: true));
    File('${ambiguous.path}/source-catalog.json')
        .writeAsBytesSync(MockShopFixture.readSourceBytes(inputs));
    File('${ambiguous.path}/source-catalog.json.gz').writeAsBytesSync(
      File('${inputs.path}/source-catalog.json.gz').readAsBytesSync(),
    );
    File('${ambiguous.path}/shop.json')
        .writeAsBytesSync(File('${inputs.path}/shop.json').readAsBytesSync());
    expect(() => MockShopFixture.read(ambiguous), throwsFormatException);
  });

  for (final field in ['stock_unit', 'preferred_offer_id', 'planned_qty']) {
    test('parser rejects malformed material $field', () {
      final d = jsonDecode(jsonEncode(fixture.raw));
      d['job_material_lines']['MAT-001-01'][field] = switch (field) {
        'stock_unit' => 'each',
        'preferred_offer_id' => 'missing-offer',
        _ => -1,
      };
      expect(
        () => MockShopFixture.decode(
          utf8.encode(jsonEncode(d)),
          MockShopFixture.readSourceBytes(inputs),
          requireFrozen: false,
        ),
        throwsFormatException,
      );
    });
  }

  test('changed source bytes fail before opening a business store', () {
    expect(
      () => MockShopFixture.decode(
        utf8.encode(jsonEncode(fixture.raw)),
        utf8.encode('{}'),
      ),
      throwsFormatException,
    );
    expect(workspace.db.select(workspace.db.parts).get(), completion(isEmpty));
  });

  test(
    'local profile stores the declared native projection and repeats exactly',
    () async {
      final result = await workspace.import(fixture);
      expect(result.unchanged, isFalse);
      expect(result.counts['parts'], 59);
      expect(result.counts['brand_versions'], 59);
      expect(result.counts['supplier_listings'], 66);
      expect(result.counts['jobs'], 7);
      expect(result.counts['job_lines'], 40);
      expect(result.counts['warehouse_locations'], 11);
      expect(result.counts['warehouse_counts'], 649);
      final jobs = await workspace.db.select(workspace.db.jobs).get();
      expect(jobs.where((j) => j.status == 'active'), hasLength(5));
      expect(jobs.where((j) => j.status == 'archived'), hasLength(2));
      for (final job in jobs) {
        final source = jsonDecode(job.notes!)['fixture'];
        expect(source['status'], fixture.jobs[job.jobNumber]['status']);
      }
      final before = await workspace.publicBusinessDigest();
      final repeated = await workspace.import(fixture);
      expect(repeated.unchanged, isTrue);
      expect(await workspace.publicBusinessDigest(), before);
      await workspace.reopen();
      expect(await workspace.publicBusinessDigest(), before);
      expect((await workspace.import(fixture)).unchanged, isTrue);
    },
  );

  test(
    'black and white identity, three suppliers and unknown prices survive',
    () async {
      await workspace.import(fixture);
      final db = workspace.db;
      final white = fixture.nativeId('part', 'part-leviton-t5320-w');
      final black = fixture.nativeId('part', 'part-leviton-r55-t5320-00e');
      expect(white, isNot(black));
      final versions = await db.select(db.brandVersions).get();
      expect(
        versions.singleWhere((v) => v.partId == white).varianceName,
        'white',
      );
      expect(
        versions.singleWhere((v) => v.partId == black).varianceName,
        'black',
      );
      final listingVersion = fixture.nativeId(
        'brand-version',
        'part-lutron-cw-1-wh',
      );
      final listings = (await db.select(db.supplierListings).get())
          .where((l) => l.brandVersionId == listingVersion)
          .toList();
      expect(listings, hasLength(3));
      expect(listings.map((l) => l.lastPrice), containsAll([4.97, 4.98, null]));
      final platt = listings.singleWhere(
        (l) => l.supplierId == fixture.nativeId('supplier', 'platt'),
      );
      expect(platt.sku, '0181973');
      expect(jsonDecode(platt.notes!)['supplier_online_id'], isNull);
      final wire = (await db.select(db.supplierListings).get()).singleWhere(
        (l) => l.id == fixture.nativeId('offer', 'offer-home-depot-203401604'),
      );
      expect(wire.packageQty, 500);
      expect(wire.lastPrice, 145);
      expect(
        (await db.select(db.supplierListings).get()).where(
          (l) => l.lastPrice == null,
        ),
        hasLength(8),
      );
    },
  );

  test(
    'warehouse records on-hand once, not free stock or movement replay',
    () async {
      await workspace.import(fixture);
      final repo = WarehouseRepository(
        workspace.db,
        workspace.pin,
        workspace.deviceId,
      );
      final count = await repo.latestCount(
        fixture.nativeId('location', 'LOC-SHOP'),
        fixture.nativeId('part', 'part-eaton-trbr20w-10-lw'),
      );
      expect(count!.quantity, 16);
      final metadata = jsonDecode(count.note)['fixture_stock'];
      expect(metadata['reserved_qty'], 10);
      expect(metadata['available_qty'], 6);
    },
  );

  test('interruption rolls back every imported business row', () async {
    final before = await workspace.publicBusinessDigest();
    await expectLater(
      workspace.import(
        fixture,
        beforeCommit: () async => throw StateError('synthetic interruption'),
      ),
      throwsStateError,
    );
    expect(await workspace.publicBusinessDigest(), before);
    expect((await workspace.import(fixture)).unchanged, isFalse);
  });

  test(
    'occupied or subsequently edited IDs refuse without replacing data',
    () async {
      await workspace.import(fixture);
      await workspace.db.customStatement(
        'UPDATE parts SET name = ? WHERE id = ?',
        [
          'A separate edit',
          fixture.nativeId('part', fixture.variants.keys.first),
        ],
      );
      final before = await workspace.publicBusinessDigest();
      await expectLater(workspace.import(fixture), throwsStateError);
      expect(await workspace.publicBusinessDigest(), before);
    },
  );

  test(
    'PIN denial and company markers preserve the entire local projection',
    () async {
      workspace.pin.lock();
      final empty = await workspace.publicBusinessDigest();
      await expectLater(workspace.import(fixture), throwsStateError);
      expect(await workspace.publicBusinessDigest(), empty);
      await workspace.unlock();
      await workspace.import(fixture);
      final catalog = CatalogRepository(
        workspace.db,
        workspace.pin,
        workspace.deviceId,
      );
      workspace.pin.lock();
      final before = await workspace.publicBusinessDigest();
      final validPart =
          (await workspace.db.select(workspace.db.parts).get()).first;
      await expectLater(
        catalog.createGeneralPart(
          name: 'Denied',
          categoryId: validPart.categoryId,
          styleId: validPart.styleId,
          typeId: validPart.typeId,
        ),
        throwsStateError,
      );
      expect(await workspace.publicBusinessDigest(), before);
      await workspace.unlock();
      await workspace.db.customStatement(
        'INSERT INTO company_join_events '
        '(request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
        ['mock-marker', 1, 'blocked', 'synthetic company marker'],
      );
      await expectLater(workspace.import(fixture), throwsStateError);
      expect(await workspace.publicBusinessDigest(), before);
    },
  );

  test(
    'a later auxiliary business row is not accepted as an unchanged import',
    () async {
      await workspace.import(fixture);
      final repo = JobsRepository(workspace.db, workspace.deviceId);
      final line = fixture.nativeId('material', 'MAT-001-01');
      await repo.replaceOrderSplits(line, [
        (supplierId: fixture.nativeId('supplier', 'home-depot'), qty: 1),
      ]);
      final before = await workspace.publicBusinessDigest();
      final splits = await repo.orderSplitsForLine(line);
      await expectLater(workspace.import(fixture), throwsStateError);
      expect(await workspace.publicBusinessDigest(), before);
      expect(await repo.orderSplitsForLine(line), splits);
    },
  );

  test(
    'repository quantities, promotion and split tombstones retain semantics',
    () async {
      await workspace.import(fixture);
      final repo = JobsRepository(workspace.db, workspace.deviceId);
      final job = fixture.nativeId('job', 'JOB-001');
      final line = await repo.addLine(
        jobId: job,
        customName: 'Test custom line',
        neededQty: 20,
        shopPullQty: 8,
        splits: [
          (supplierId: fixture.nativeId('supplier', 'home-depot'), qty: 7),
        ],
      );
      expect(
        const JobLineQty(
          requested: 20,
          shop: 8,
          supplierSplits: [
            JobSupplierSplit(supplierName: 'Supplier A', qty: 7),
          ],
        ).leftToPullOrder,
        5,
      );
      await repo.replaceOrderSplits(line, [
        (supplierId: fixture.nativeId('supplier', 'home-depot'), qty: 7),
        (supplierId: fixture.nativeId('supplier', 'lowes'), qty: 6),
      ]);
      expect(
        const JobLineQty(
          requested: 20,
          shop: 8,
          supplierSplits: [
            JobSupplierSplit(supplierName: 'Supplier A', qty: 7),
            JobSupplierSplit(supplierName: 'Supplier B', qty: 6),
          ],
        ).leftToPullOrder,
        -1,
      );
      await repo.attachCatalogPart(
        lineId: line,
        partId: fixture.nativeId('part', 'part-leviton-t5320-w'),
      );
      final promoted = await repo.getJobLine(line);
      expect(promoted!.neededQty, 20);
      expect(promoted.shopPullQty, 8);
      expect(promoted.customName, isNull);
      expect(await repo.orderSplitsForLine(line), hasLength(2));
      await expectLater(repo.setShopPull(line, -1), throwsStateError);
      await repo.removeLine(line);
      expect(await repo.orderSplitsForLine(line), isEmpty);
      final allSplits = await workspace.db
          .select(workspace.db.orderSplits)
          .get();
      expect(
        allSplits
            .where((s) => s.jobLineId == line)
            .every((s) => s.deletedAt != null),
        isTrue,
      );
    },
  );
}
