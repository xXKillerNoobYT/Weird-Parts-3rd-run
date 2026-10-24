import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/warehouse/warehouse_integrity.dart';
import 'package:wired_parts/features/warehouse/warehouse_repository.dart';

import 'warehouse_test_support.dart';

void main() {
  late WarehouseFixture f;
  setUp(() async => f = await WarehouseFixture.create());
  tearDown(() => f.db.close());

  test(
    'unknown differs from zero; absolute recount keeps full causal history',
    () async {
      expect(await f.repo.latestCount(f.locationId, f.partId), isNull);
      final first = await f.repo.recordCount(f.draft(quantity: 12));
      final zero = await f.repo.recordCount(
        f.draft(
          prior: first.id,
          quantity: 0,
          observedAt: DateTime.utc(2026, 1, 1),
          note: '  Empty after physical count\nSecond line  ',
        ),
      );
      expect(zero.quantity, 0);
      expect(zero.ordinal, 2);
      expect(zero.priorCountId, first.id);
      expect(zero.observedAt.isBefore(first.observedAt), isTrue);
      expect((await f.repo.latestCount(f.locationId, f.partId))!.id, zero.id);
      expect(await f.repo.loadCountHistory(f.locationId, f.partId), [
        zero,
        first,
      ]);
      expect(zero.note, 'Empty after physical count\nSecond line');
      expect(zero.originDeviceId, f.device);
      await validateWarehouseStore(f.db);
    },
  );

  test(
    'exact normalized replay survives newer head and Part unit change',
    () async {
      final draft = f.draft(uom: ' ea ', note: ' counted\ncarefully ');
      final first = await f.repo.recordCount(draft);
      expect(first.observedAt.toUtc(), DateTime.utc(2026, 10, 20, 9, 15, 13));
      final second = await f.repo.recordCount(
        f.draft(prior: first.id, quantity: 8),
      );
      await (f.db.update(f.db.parts)..where((t) => t.id.equals(f.partId)))
          .write(const PartsCompanion(uom: Value('box')));
      final before = await f.snapshot();
      expect(await f.repo.recordCount(draft), first);
      expect(await f.snapshot(), before);
      expect((await f.repo.latestCount(f.locationId, f.partId))!.id, second.id);
      expect(
        (await f.repo.loadLatestCounts(f.locationId)).single.needsRecount,
        isTrue,
      );
      await expectLater(
        f.repo.recordCount(f.draft(prior: second.id)),
        throwsStateError,
      );
      final third = await f.repo.recordCount(
        f.draft(prior: second.id, uom: 'box', quantity: 2),
      );
      expect(third.quantity, 2);
      expect(third.uom, 'box');
      expect(
        (await f.repo.loadCountHistory(f.locationId, f.partId)).last.uom,
        'ea',
      );
    },
  );

  test(
    'reused ID with different immutable payload or origin refuses every write',
    () async {
      final draft = f.draft();
      await f.repo.recordCount(draft);
      final before = await f.snapshot();
      for (final changed in [
        f.draft(id: draft.id, quantity: 99),
        f.draft(id: draft.id, prior: draft.id),
        f.draft(id: draft.id, note: 'Different'),
        f.draft(id: draft.id, observedAt: DateTime.utc(2026, 10, 21)),
        f.draft(id: draft.id, partId: 'missing'),
        f.draft(id: draft.id, locationId: 'missing'),
        f.draft(id: draft.id, uom: 'box'),
      ]) {
        await expectLater(f.repo.recordCount(changed), throwsStateError);
        expect(await f.snapshot(), before);
      }
      await expectLater(
        WarehouseRepository(f.db, f.pin, 'other-device').recordCount(draft),
        throwsStateError,
      );
      expect(await f.snapshot(), before);
    },
  );

  test('negative and nonfinite count quantities refuse; finite fractions and excess are allowed', () async {
    final before = await f.snapshot();
    for (final value in [
      -1.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      await expectLater(
        f.repo.recordCount(f.draft(quantity: value)),
        throwsStateError,
      );
      expect(await f.snapshot(), before);
    }
    final small = await f.repo.recordCount(f.draft(quantity: 0.25));
    final large = await f.repo.recordCount(
      f.draft(prior: small.id, quantity: double.maxFinite),
    );
    expect(large.quantity, double.maxFinite);
  });

  test('missing targets, tombstones, crossed prior and stale heads refuse without writes', () async {
    final first = await f.repo.recordCount(f.draft());
    final otherLocation = newId();
    await f.repo.createLocation(id: otherLocation, name: 'Truck shelf');
    final other = await f.repo.recordCount(f.draft(locationId: otherLocation));
    final before = await f.snapshot();
    for (final draft in [
      f.draft(),
      f.draft(prior: other.id),
      f.draft(prior: 'missing'),
      f.draft(locationId: 'missing'),
      f.draft(partId: 'missing'),
      f.draft(prior: first.id, uom: ''),
      f.draft(id: '', prior: first.id),
    ]) {
      await expectLater(f.repo.recordCount(draft), throwsStateError);
      expect(await f.snapshot(), before);
    }
    await (f.db.update(
      f.db.warehouseLocations,
    )..where((t) => t.id.equals(f.locationId))).write(
      WarehouseLocationsCompanion(deletedAt: Value(DateTime.now().toUtc())),
    );
    final deleted = await f.snapshot();
    await expectLater(
      f.repo.recordCount(f.draft(prior: first.id)),
      throwsStateError,
    );
    await expectLater(
      f.repo.renameLocation(
        id: f.locationId,
        expectedRevision: 1,
        name: 'Gone',
      ),
      throwsStateError,
    );
    expect(await f.snapshot(), deleted);
  });

  test('inactive live Parts accept counts; deleted Parts retain read-only history and exact receipts', () async {
    await (f.db.update(f.db.parts)..where((t) => t.id.equals(f.partId))).write(
      const PartsCompanion(active: Value(false)),
    );
    final draft = f.draft();
    final first = await f.repo.recordCount(draft);
    await (f.db.update(f.db.parts)..where((t) => t.id.equals(f.partId))).write(
      PartsCompanion(
        name: const Value('Renamed part'),
        deletedAt: Value(DateTime.now().toUtc()),
      ),
    );
    final before = await f.snapshot();
    final stock = (await f.repo.loadLatestCounts(f.locationId)).single;
    expect(stock.part.name, 'Renamed part');
    expect(stock.part.deletedAt, isNotNull);
    expect(stock.count, first);
    expect(await f.repo.recordCount(draft), first);
    await expectLater(
      f.repo.recordCount(f.draft(prior: first.id)),
      throwsStateError,
    );
    expect(await f.snapshot(), before);
    await validateWarehouseStore(f.db);
  });

  test('location names normalize, duplicate refusal and stale revisions preserve identities', () async {
    final location = (await f.repo.loadLocations()).single;
    final before = await f.snapshot();
    await f.repo.renameLocation(
      id: location.id,
      expectedRevision: 1,
      name: ' Shop shelf ',
    );
    expect(await f.snapshot(), before);
    await expectLater(
      f.repo.createLocation(id: newId(), name: ' SHOP SHELF '),
      throwsStateError,
    );
    await expectLater(
      f.repo.createLocation(id: newId(), name: '   '),
      throwsStateError,
    );
    expect(await f.snapshot(), before);
    await f.repo.renameLocation(
      id: location.id,
      expectedRevision: 1,
      name: ' Rack A ',
    );
    final renamed = (await f.repo.loadLocations()).single;
    expect(renamed.id, location.id);
    expect(renamed.name, 'Rack A');
    expect(renamed.revision, 2);
    expect(renamed.originDeviceId, location.originDeviceId);
    final after = await f.snapshot();
    await expectLater(
      f.repo.renameLocation(
        id: location.id,
        expectedRevision: 1,
        name: 'Stale',
      ),
      throwsStateError,
    );
    expect(await f.snapshot(), after);
  });

  test('two local count saves from one observed head have one winner and one stale refusal', () async {
    final results = await Future.wait([
      for (final qty in [1.0, 2.0])
        f.repo
            .recordCount(f.draft(quantity: qty))
            .then<Object>((row) => row, onError: (Object error) => error),
    ]);
    expect(results.whereType<WarehouseCount>(), hasLength(1));
    expect(results.whereType<StateError>(), hasLength(1));
    expect(await f.repo.loadCountHistory(f.locationId, f.partId), hasLength(1));
  });

  test('locked PIN refuses creation, rename, count and exact replay with full store equality', () async {
    final draft = f.draft();
    await f.repo.recordCount(draft);
    await f.pin.setPin('1234');
    final before = await f.snapshot();
    for (final write in [
      () => f.repo.createLocation(id: newId(), name: 'Denied'),
      () => f.repo.renameLocation(
        id: f.locationId,
        expectedRevision: 1,
        name: 'Denied',
      ),
      () => f.repo.recordCount(draft),
      () => f.repo.recordCount(f.draft()),
    ]) {
      await expectLater(write(), throwsStateError);
      expect(await f.snapshot(), before);
    }
  });

  test(
    'company marker refuses every mutation and replay without writes',
    () async {
      final draft = f.draft();
      await f.repo.recordCount(draft);
      await f.db.customStatement(
        'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
        ['synthetic-refusal', 1, 'blocked', 'synthetic-marker'],
      );
      final before = await f.snapshot();
      for (final write in [
        () => f.repo.createLocation(id: newId(), name: 'Denied'),
        () => f.repo.renameLocation(
          id: f.locationId,
          expectedRevision: 1,
          name: 'Denied',
        ),
        () => f.repo.recordCount(draft),
      ]) {
        await expectLater(write(), throwsStateError);
        expect(await f.snapshot(), before);
      }
      for (final read in [
        () => f.repo.loadLocations(),
        () => f.repo.latestCount(f.locationId, f.partId),
        () => f.repo.loadCountHistory(f.locationId, f.partId),
        () => f.repo.loadLatestCounts(f.locationId),
        () => f.repo.loadPartChoices(),
        () => f.repo.loadPart(f.partId),
      ]) {
        await expectLater(read(), throwsStateError);
      }
      expect(await f.snapshot(), before);
    },
  );

  test('PIN relocked by SQLite during insert or update rolls back every mutation', () async {
    await f.db.close();
    f = await WarehouseFixture.create(
      executor: NativeDatabase.memory(
        setup: (raw) {
          raw.createFunction(
            functionName: 'relock_editor',
            argumentCount: const sqlite.AllowedArgumentCount(0),
            directOnly: false,
            function: (_) {
              f.pin.lock();
              return 0;
            },
          );
        },
      ),
    );
    await f.pin.setPin('1234');
    for (final event in [
      (
        'INSERT',
        'warehouse_locations',
        () => f.repo.createLocation(id: newId(), name: 'Must roll back'),
      ),
      (
        'UPDATE',
        'warehouse_locations',
        () => f.repo.renameLocation(
          id: f.locationId,
          expectedRevision: 1,
          name: 'Must roll back',
        ),
      ),
      ('INSERT', 'warehouse_counts', () => f.repo.recordCount(f.draft())),
    ]) {
      await f.pin.unlock('1234');
      await f.db.customStatement(
        'CREATE TRIGGER relock_write AFTER ${event.$1} ON ${event.$2} BEGIN SELECT relock_editor(); END',
      );
      final before = await f.snapshot();
      await expectLater(event.$3(), throwsStateError);
      expect(f.pin.isUnlocked, isFalse);
      expect(await f.snapshot(), before);
      await f.db.customStatement('DROP TRIGGER relock_write');
    }
  });

  test(
    'injected count failure leaves complete store and previous head unchanged',
    () async {
      final first = await f.repo.recordCount(f.draft());
      final draft = f.draft(prior: first.id, quantity: 7);
      await f.db.customStatement(
        "CREATE TRIGGER fail_count BEFORE INSERT ON warehouse_counts BEGIN SELECT RAISE(ABORT, 'synthetic count failure'); END",
      );
      final before = await f.snapshot();
      await expectLater(f.repo.recordCount(draft), throwsA(anything));
      expect(await f.snapshot(), before);
      await f.db.customStatement('DROP TRIGGER fail_count');
      final saved = await f.repo.recordCount(draft);
      expect(saved.ordinal, 2);
      expect(saved.id, draft.id);
    },
  );

  test('real SQLite close/reopen preserves exact observations, relationships and replay', () async {
    final dir = Directory.systemTemp.createTempSync('warehouse-reopen-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/shop.sqlite');
    await f.db.close();
    final disk = await WarehouseFixture.create(file: file);
    final draft = disk.draft(note: 'Exact\nmultiline observation');
    final first = await disk.repo.recordCount(draft);
    await disk.repo.recordCount(disk.draft(prior: first.id, quantity: 0));
    await disk.repo.renameLocation(
      id: disk.locationId,
      expectedRevision: 1,
      name: 'Retained rack',
    );
    final before = await disk.snapshot();
    await disk.db.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final repo = WarehouseRepository(
        reopened,
        PinService(reopened.settingsDao),
        disk.device,
      );
      expect(await repo.recordCount(draft), first);
      for (final table in reopened.allTables) {
        expect(
          (await reopened
                  .customSelect(
                    'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
                  )
                  .get())
              .map((r) => r.data)
              .toList(),
          before[table.actualTableName],
          reason: table.actualTableName,
        );
      }
      expect((await repo.loadLocations()).single.name, 'Retained rack');
      final history = await repo.loadCountHistory(disk.locationId, disk.partId);
      expect(history.map((r) => r.quantity), [0, 12.5]);
      expect(
        history.last.observedAt.toUtc(),
        DateTime.utc(2026, 10, 20, 9, 15, 13),
      );
      expect(history.last.note, 'Exact\nmultiline observation');
      expect(
        (await reopened.partsDao.getPart(disk.partId))!.categoryId,
        isNotNull,
      );
      await validateWarehouseStore(reopened);
    } finally {
      await reopened.close();
    }
  });
}
