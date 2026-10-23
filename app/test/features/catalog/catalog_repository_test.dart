import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/catalog_tree.dart';
import 'package:wired_parts/features/catalog/part_photo_store.dart';
import 'package:wired_parts/features/jobs/job_line_qty.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

class _LockAfterSavePhotoStore extends PartPhotoStore {
  _LockAfterSavePhotoStore(this.pin);

  final PinService pin;

  @override
  Future<String> saveForPart({
    required String partId,
    required Uint8List bytes,
    Directory? root,
  }) async {
    final stored = await super.saveForPart(
      partId: partId,
      bytes: bytes,
      root: root,
    );
    pin.lock();
    return stored;
  }
}

class _CleanupFailurePhotoStore extends PartPhotoStore {
  final attempted = <String>[];

  @override
  Future<void> deleteAt(String stored, {Directory? root}) async {
    attempted.add(stored);
    throw FileSystemException('synthetic cleanup denied', root!.path);
  }
}

void main() {
  late AppDatabase db;
  late String deviceId;
  late PinService pin;
  late CatalogRepository catalog;

  setUp(() async {
    BackupIo.end();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deviceId = await db.settingsDao.ensureDeviceId();
    pin = PinService(db.settingsDao);
    catalog = CatalogRepository(db, pin, deviceId);
  });

  tearDown(() async {
    BackupIo.end();
    await db.close();
  });

  Future<String> createValidPart({
    required String name,
    String? defaultSupplierId,
  }) async {
    final category = await db.taxonomyDao.insertCategory(
      id: newId(),
      name: 'Synthetic category',
      deviceId: deviceId,
    );
    final style = await db.taxonomyDao.insertStyle(
      id: newId(),
      categoryId: category,
      name: 'Synthetic type',
      deviceId: deviceId,
    );
    final variant = await db.taxonomyDao.insertType(
      id: newId(),
      styleId: style,
      name: 'Synthetic variant',
      deviceId: deviceId,
    );
    return catalog.createGeneralPart(
      name: name,
      defaultSupplierId: defaultSupplierId,
      categoryId: category,
      styleId: style,
      typeId: variant,
    );
  }

  Uint8List photoBytes(int red, int green, int blue) {
    final image = img.Image(width: 8, height: 8);
    img.fill(image, color: img.ColorRgb8(red, green, blue));
    return Uint8List.fromList(img.encodePng(image));
  }

  Future<List<Map<String, Object?>>> partRows() async =>
      (await db.customSelect('SELECT * FROM parts ORDER BY id').get())
          .map((row) => Map<String, Object?>.of(row.data))
          .toList();

  Future<Map<String, Object>> photoSnapshot(Directory dir) async {
    final exists = await dir.exists();
    final directories = <String>[];
    final files = <String, List<int>>{};
    if (exists) {
      final entries = await dir
          .list(recursive: true, followLinks: false)
          .toList();
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        final name = p.relative(entry.path, from: dir.path);
        if (entry is Directory) {
          directories.add(name);
        } else if (entry is File) {
          files[name] = await entry.readAsBytes();
        }
      }
    }
    return {'exists': exists, 'directories': directories, 'files': files};
  }

  test('create part allowed when no PIN set', () async {
    final id = await createValidPart(name: 'Valve');
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

    final id = await createValidPart(
      name: 'Relay',
      defaultSupplierId: supplierId,
    );
    final original = (await catalog.getPart(id))!;
    await catalog.updatePart(
      partId: id,
      name: 'Relay 24V',
      description: 'Control relay',
      uom: 'ea',
      defaultSupplierId: supplierId,
      active: true,
      categoryId: original.categoryId,
      styleId: original.styleId,
      typeId: original.typeId,
    );
    final part = await catalog.getPart(id);
    expect(part!.name, 'Relay 24V');
    expect(part.description, 'Control relay');
    expect(part.defaultSupplierId, supplierId);
    expect(part.revision, 2);
  });

  test(
    'part Specifications update, omission preserve, and empty clears',
    () async {
      final id = await createValidPart(name: 'Specifications part');
      await db.partsDao.setPhotoPath(id, 'synthetic-photo.jpg');
      final original = (await catalog.getPart(id))!;

      Future<void> update({String? name, String? specs}) => catalog.updatePart(
        partId: id,
        name: name ?? original.name,
        description: original.description,
        uom: original.uom,
        defaultSupplierId: original.defaultSupplierId,
        active: original.active,
        categoryId: original.categoryId,
        styleId: original.styleId,
        typeId: original.typeId,
        specs: specs,
      );

      await update(specs: '120 V\n20 A');
      await update(name: 'Renamed part');
      var saved = (await catalog.getPart(id))!;
      expect(saved.specs, '120 V\n20 A');
      expect(saved.name, 'Renamed part');
      expect(saved.photoPath, 'synthetic-photo.jpg');
      expect(saved.categoryId, original.categoryId);
      expect(saved.styleId, original.styleId);
      expect(saved.typeId, original.typeId);

      await update(specs: '');
      saved = (await catalog.getPart(id))!;
      expect(saved.specs, isEmpty);
    },
  );

  test('locked PIN and company marker refuse Specifications changes', () async {
    final id = await createValidPart(name: 'Protected specifications');
    final original = (await catalog.getPart(id))!;
    Future<void> updateSpecs(String value) => catalog.updatePart(
      partId: id,
      name: original.name,
      description: original.description,
      uom: original.uom,
      defaultSupplierId: original.defaultSupplierId,
      active: original.active,
      categoryId: original.categoryId,
      styleId: original.styleId,
      typeId: original.typeId,
      specs: value,
    );

    await catalog.updatePart(
      partId: id,
      name: original.name,
      description: original.description,
      uom: original.uom,
      defaultSupplierId: original.defaultSupplierId,
      active: original.active,
      categoryId: original.categoryId,
      styleId: original.styleId,
      typeId: original.typeId,
      specs: 'Existing specifications',
    );
    final beforeRefusals = (await catalog.getPart(id))!;
    await pin.setPin('2468');
    await expectLater(updateSpecs('Blocked by PIN'), throwsStateError);
    expect(await catalog.getPart(id), beforeRefusals);

    await pin.unlock('2468');
    await db.customStatement(
      'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
      ['synthetic-specs-blocker', 1, 'blocked', 'synthetic-refusal-marker'],
    );
    await expectLater(
      updateSpecs('Blocked by company marker'),
      throwsStateError,
    );
    expect(await catalog.getPart(id), beforeRefusals);
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

    final id = await createValidPart(name: 'With photo');
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

  test(
    'replacing a photo stores a new relative file and deletes the old one',
    () async {
      final dir = Directory.systemTemp.createTempSync('wp-repo-photo-replace-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 8, height: 8)),
      );
      final id = await createValidPart(name: 'Swap photo');
      final first = await catalog.attachPhoto(
        partId: id,
        bytes: bytes,
        root: dir,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = await catalog.attachPhoto(
        partId: id,
        bytes: bytes,
        root: dir,
      );
      expect(second, isNot(first));
      expect(p.isAbsolute(second), isFalse);
      expect(
        (await const PartPhotoStore().resolveFile(
          first,
          root: dir,
        )).existsSync(),
        isFalse,
      );
      expect(
        (await const PartPhotoStore().resolveFile(
          second,
          root: dir,
        )).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'attach photo to an unknown UUID refuses without creating files',
    () async {
      final parent = Directory.systemTemp.createTempSync('wp-photo-missing-');
      addTearDown(() => parent.deleteSync(recursive: true));
      final photos = Directory(p.join(parent.path, 'photos'));
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      expect(beforePhotos['exists'], isFalse);
      Object? error;
      try {
        await catalog.attachPhoto(
          partId: newId(),
          bytes: photoBytes(210, 30, 40),
          root: photos,
        );
      } catch (e) {
        error = e;
      }
      expect(
        {
          'refused': error is StateError,
          'parts': await partRows(),
          'photos': await photoSnapshot(photos),
        },
        {'refused': true, 'parts': beforeRows, 'photos': beforePhotos},
      );
    },
  );

  test(
    'attach photo to a tombstone preserves its row and existing image',
    () async {
      final photos = Directory.systemTemp.createTempSync('wp-photo-deleted-');
      addTearDown(() => photos.deleteSync(recursive: true));
      final id = await createValidPart(name: 'Deleted photo target');
      await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      await db.partsDao.softDeletePart(id);
      expect(
        (await catalog.getPart(id, includeDeleted: true))!.deletedAt,
        isNotNull,
      );
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      expect(beforePhotos['files'], hasLength(1));
      Object? error;
      try {
        await catalog.attachPhoto(
          partId: id,
          bytes: photoBytes(210, 30, 40),
          root: photos,
        );
      } catch (e) {
        error = e;
      }
      expect(
        {
          'refused': error is StateError,
          'parts': await partRows(),
          'photos': await photoSnapshot(photos),
        },
        {'refused': true, 'parts': beforeRows, 'photos': beforePhotos},
      );
    },
  );

  test(
    'company refusal preserves the Part and entire photo directory',
    () async {
      final photos = Directory.systemTemp.createTempSync('wp-photo-company-');
      addTearDown(() => photos.deleteSync(recursive: true));
      final id = await createValidPart(name: 'Company protected photo');
      await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      await db.customStatement(
        'INSERT INTO company_join_events (request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
        ['synthetic-photo-blocker', 1, 'blocked', 'synthetic-refusal-marker'],
      );
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      expect(beforePhotos['files'], hasLength(1));
      Object? error;
      try {
        await catalog.attachPhoto(
          partId: id,
          bytes: photoBytes(210, 30, 40),
          root: photos,
        );
      } catch (e) {
        error = e;
      }
      expect(
        {
          'refused': error is StateError,
          'parts': await partRows(),
          'photos': await photoSnapshot(photos),
        },
        {'refused': true, 'parts': beforeRows, 'photos': beforePhotos},
      );
    },
  );

  test(
    'photo path SQL failure preserves the previous row and file set',
    () async {
      final photos = Directory.systemTemp.createTempSync('wp-photo-sql-fail-');
      addTearDown(() => photos.deleteSync(recursive: true));
      final id = await createValidPart(name: 'Failed replacement target');
      await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      await db.customStatement(
        "CREATE TRIGGER refuse_photo_path BEFORE UPDATE OF photo_path ON parts "
        "BEGIN SELECT RAISE(ABORT, 'synthetic photo update failure'); END",
      );
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      expect(beforePhotos['files'], hasLength(1));
      Object? error;
      try {
        await catalog.attachPhoto(
          partId: id,
          bytes: photoBytes(210, 30, 40),
          root: photos,
        );
      } catch (e) {
        error = e;
      }
      expect(
        {
          'failed update': '$error'.contains('synthetic photo update failure'),
          'parts': await partRows(),
          'photos': await photoSnapshot(photos),
        },
        {'failed update': true, 'parts': beforeRows, 'photos': beforePhotos},
      );
    },
  );

  test(
    'photo attachment refuses caller-owned transactions without effects',
    () async {
      final photos = Directory.systemTemp.createTempSync('wp-photo-outer-tx-');
      addTearDown(() => photos.deleteSync(recursive: true));
      final id = await createValidPart(name: 'Caller transaction photo');
      await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      Object? error;
      await db.transaction(() async {
        try {
          await catalog.attachPhoto(
            partId: id,
            bytes: photoBytes(210, 30, 40),
            root: photos,
          );
        } catch (e) {
          error = e;
        }
      });
      expect(
        {
          'refused': error is StateError,
          'parts': await partRows(),
          'photos': await photoSnapshot(photos),
        },
        {'refused': true, 'parts': beforeRows, 'photos': beforePhotos},
      );
    },
  );

  test(
    'photo references, bytes and PIN gates survive file-backed reopen',
    () async {
      final parent = Directory.systemTemp.createTempSync('wp-photo-reopen-');
      final databaseFile = File(p.join(parent.path, 'synthetic.sqlite'));
      final photos = Directory(p.join(parent.path, 'photos'));
      var diskDb = AppDatabase.forTesting(NativeDatabase(databaseFile));
      try {
        final origin = await diskDb.settingsDao.ensureDeviceId();
        final category = await diskDb.taxonomyDao.insertCategory(
          id: newId(),
          name: 'Synthetic category',
          deviceId: origin,
        );
        final style = await diskDb.taxonomyDao.insertStyle(
          id: newId(),
          categoryId: category,
          name: 'Synthetic type',
          deviceId: origin,
        );
        final variant = await diskDb.taxonomyDao.insertType(
          id: newId(),
          styleId: style,
          name: 'Synthetic variant',
          deviceId: origin,
        );
        var diskPin = PinService(diskDb.settingsDao);
        await diskPin.setPin('2468');
        expect(await diskPin.unlock('2468'), isTrue);
        var diskCatalog = CatalogRepository(diskDb, diskPin, origin);
        final id = await diskCatalog.createGeneralPart(
          name: 'Persistent photo target',
          categoryId: category,
          styleId: style,
          typeId: variant,
        );
        final first = await diskCatalog.attachPhoto(
          partId: id,
          bytes: photoBytes(20, 80, 140),
          root: photos,
        );
        final firstRow =
            (await diskDb.customSelect('SELECT * FROM parts').getSingle()).data;
        final firstPhotos = await photoSnapshot(photos);
        expect(firstRow['photo_path'], first);
        expect(
          await File(p.join(photos.path, first)).readAsBytes(),
          PartPhotoStore.compress(photoBytes(20, 80, 140)),
        );

        Future<void> reopen() async {
          await diskDb.close();
          diskDb = AppDatabase.forTesting(NativeDatabase(databaseFile));
          expect(await diskDb.settingsDao.ensureDeviceId(), origin);
          diskPin = PinService(diskDb.settingsDao);
          diskCatalog = CatalogRepository(diskDb, diskPin, origin);
          expect(
            await diskDb.customSelect('PRAGMA foreign_key_check').get(),
            isEmpty,
          );
        }

        await reopen();
        expect(
          (await diskDb.customSelect('SELECT * FROM parts').getSingle()).data,
          firstRow,
        );
        expect(await photoSnapshot(photos), firstPhotos);
        expect(diskPin.isUnlocked, isFalse);
        await expectLater(
          diskCatalog.attachPhoto(
            partId: id,
            bytes: photoBytes(210, 30, 40),
            root: photos,
          ),
          throwsA(isA<StateError>()),
        );
        expect(await photoSnapshot(photos), firstPhotos);
        expect(await diskPin.unlock('2468'), isTrue);
        final second = await diskCatalog.attachPhoto(
          partId: id,
          bytes: photoBytes(210, 30, 40),
          root: photos,
        );
        expect(second, isNot(first));
        expect(p.isAbsolute(second), isFalse);
        final secondRow =
            (await diskDb.customSelect('SELECT * FROM parts').getSingle()).data;
        final secondPhotos = await photoSnapshot(photos);
        expect(secondRow['photo_path'], second);
        expect(
          await File(p.join(photos.path, second)).readAsBytes(),
          PartPhotoStore.compress(photoBytes(210, 30, 40)),
        );
        expect((secondPhotos['files'] as Map).keys, [second]);
        expect(secondPhotos, isNot(firstPhotos));

        await reopen();
        expect(
          (await diskDb.customSelect('SELECT * FROM parts').getSingle()).data,
          secondRow,
        );
        expect(await photoSnapshot(photos), secondPhotos);
        expect(await diskPin.unlock('2468'), isTrue);
        await diskCatalog.clearPhoto(id, root: photos);
        final clearedRow =
            (await diskDb.customSelect('SELECT * FROM parts').getSingle()).data;

        await reopen();
        expect(
          (await diskDb.customSelect('SELECT * FROM parts').getSingle()).data,
          clearedRow,
        );
        final part = (await diskCatalog.getPart(id))!;
        expect(part.photoPath, isNull);
        expect(
          [part.id, part.categoryId, part.styleId, part.typeId],
          [id, category, style, variant],
        );
        expect((await photoSnapshot(photos))['files'], isEmpty);
      } finally {
        try {
          await diskDb.close();
        } finally {
          await parent.delete(recursive: true);
        }
      }
    },
  );

  test(
    'photo clear refuses a caller transaction without changing files',
    () async {
      final photos = Directory.systemTemp.createTempSync('wp-photo-clear-tx-');
      addTearDown(() => photos.deleteSync(recursive: true));
      final id = await createValidPart(name: 'Caller transaction clear');
      await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      Object? error;
      await db.transaction(() async {
        try {
          await catalog.clearPhoto(id, root: photos);
        } catch (e) {
          error = e;
        }
      });
      expect(
        {
          'refused': error is StateError,
          'parts': await partRows(),
          'photos': await photoSnapshot(photos),
        },
        {'refused': true, 'parts': beforeRows, 'photos': beforePhotos},
      );
    },
  );

  test(
    'photo clear refuses a tombstone without changing its row or image',
    () async {
      final photos = Directory.systemTemp.createTempSync(
        'wp-photo-clear-dead-',
      );
      addTearDown(() => photos.deleteSync(recursive: true));
      final id = await createValidPart(name: 'Deleted clear target');
      await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      await db.partsDao.softDeletePart(id);
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      await expectLater(catalog.clearPhoto(id, root: photos), throwsStateError);
      expect(await partRows(), beforeRows);
      expect(await photoSnapshot(photos), beforePhotos);
    },
  );

  test(
    'locking the PIN during photo staging rolls back and removes the new file',
    () async {
      final photos = Directory.systemTemp.createTempSync('wp-photo-late-pin-');
      addTearDown(() => photos.deleteSync(recursive: true));
      await pin.setPin('2468');
      expect(await pin.unlock('2468'), isTrue);
      final id = await createValidPart(name: 'Late PIN photo');
      await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      final beforeRows = await partRows();
      final beforePhotos = await photoSnapshot(photos);
      await expectLater(
        catalog.attachPhoto(
          partId: id,
          bytes: photoBytes(210, 30, 40),
          root: photos,
          store: _LockAfterSavePhotoStore(pin),
        ),
        throwsStateError,
      );
      expect(pin.isUnlocked, isFalse);
      expect(await partRows(), beforeRows);
      expect(await photoSnapshot(photos), beforePhotos);
    },
  );

  test(
    'postcommit photo cleanup failure preserves success and reports no paths',
    () async {
      final photos = Directory.systemTemp.createTempSync('wp-photo-cleanup-');
      addTearDown(() => photos.deleteSync(recursive: true));
      final messages = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = previousPrint);
      final id = await createValidPart(name: 'Cleanup failure photo');
      final first = await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(20, 80, 140),
        root: photos,
      );
      final store = _CleanupFailurePhotoStore();
      final second = await catalog.attachPhoto(
        partId: id,
        bytes: photoBytes(210, 30, 40),
        root: photos,
        store: store,
      );
      expect((await catalog.getPart(id))!.photoPath, second);
      expect(store.attempted, [first]);
      expect(
        await File(p.join(photos.path, second)).readAsBytes(),
        PartPhotoStore.compress(photoBytes(210, 30, 40)),
      );
      await catalog.clearPhoto(id, root: photos, store: store);
      expect((await catalog.getPart(id))!.photoPath, isNull);
      expect(store.attempted, [first, second]);
      expect((await photoSnapshot(photos))['files'], hasLength(2));
      expect(messages, contains(contains('attachment commit')));
      expect(messages, contains(contains('clear commit')));
      expect(messages.join('\n'), isNot(contains(photos.path)));
      expect(messages.join('\n'), isNot(contains('synthetic cleanup denied')));
    },
  );

  test('delete part is PIN-gated and tombstones the row', () async {
    final dir = Directory.systemTemp.createTempSync('wp-del-tombstone-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final id = await createValidPart(name: 'Scrap');
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
    final id = await createValidPart(name: 'With photo');
    final stored = await catalog.attachPhoto(
      partId: id,
      bytes: bytes,
      root: dir,
    );
    await catalog.deletePart(id, root: dir);
    expect(
      (await const PartPhotoStore().resolveFile(
        stored,
        root: dir,
      )).existsSync(),
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
      catalog.deleteEmptyFolder(kind: CatalogTreeKind.category, id: occupiedId),
      throwsA(isA<StateError>()),
    );
    expect(
      (await db.taxonomyDao.listCategories()).map((c) => c.id),
      contains(occupiedId),
    );

    await pin.setPin('2468');
    await expectLater(
      catalog.deleteEmptyFolder(kind: CatalogTreeKind.category, id: occupiedId),
      throwsA(isA<StateError>()),
    );
  });

  test('deleted part stays off the catalog but job lines remain', () async {
    final dir = Directory.systemTemp.createTempSync('wp-del-jobline-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final partId = await createValidPart(name: 'On a job');
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

  test('create general part refuses empty folders', () async {
    await expectLater(
      catalog.createGeneralPart(name: 'Unfiled'),
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
    );
    final part = await catalog.getPart(id);
    expect(part!.name, 'Decora GFI');
    expect(part.categoryId, cat);
    expect(part.styleId, type);
    expect(part.typeId, variant);
  });

  test('update part requires nested category type variant', () async {
    final id = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Unfiled',
      deviceId: deviceId,
    );
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
    final id = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Mismatch',
      deviceId: deviceId,
    );
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
    final id = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Crossed',
      deviceId: deviceId,
    );
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

  test(
    'legacy unassigned part with brand version can recover its hierarchy',
    () async {
      final id = await db.partsDao.insertGeneralPart(
        id: newId(),
        name: 'Decora GFI',
        deviceId: deviceId,
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
    },
  );

  test(
    'deleted part keeps job-line name, variance, and supplier listings',
    () async {
      final dir = Directory.systemTemp.createTempSync('wp-del-splits-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final supplierId = await db.taxonomyDao.insertSupplier(
        id: newId(),
        name: 'Supply A',
        deviceId: deviceId,
      );
      final brandId = await db.taxonomyDao.insertBrand(
        id: newId(),
        name: 'Leviton',
        deviceId: deviceId,
      );
      final partId = await createValidPart(name: 'Decora outlet');
      final bvId = await catalog.createBrandVersion(
        partId: partId,
        brandId: brandId,
        mpn: 'LEV-W',
        varianceName: 'White',
        isMain: true,
      );
      await catalog.createSupplierListing(
        brandVersionId: bvId,
        supplierId: supplierId,
        sku: 'SH-1',
      );
      final jobId = await db.jobsDao.insertJob(
        id: newId(),
        name: 'Panel',
        deviceId: deviceId,
      );
      final lineId = await db.jobsDao.insertJobLine(
        id: newId(),
        jobId: jobId,
        partId: partId,
        brandVersionId: bvId,
        neededQty: 10,
        shopPullQty: 4,
        deviceId: deviceId,
      );
      await db.jobsDao.replaceOrderSplits(
        lineId: lineId,
        splits: [(supplierId: supplierId, qty: 6)],
        deviceId: deviceId,
      );

      await catalog.deletePart(partId, root: dir);

      expect(await catalog.getPart(partId), isNull);
      expect(await catalog.listBrandVersionsForPart(partId), isEmpty);
      expect(await catalog.listingsForBrandVersion(bvId), isEmpty);

      final named = await catalog.getPart(partId, includeDeleted: true);
      expect(named!.name, 'Decora outlet');
      expect(
        (await catalog.listParts(
          activeOnly: false,
          includeDeleted: true,
        )).map((p) => p.id),
        contains(partId),
      );
      final versions = await catalog.listBrandVersionsForPart(
        partId,
        includeDeleted: true,
      );
      expect(versions, hasLength(1));
      expect(versions.first.id, bvId);
      final listings = await catalog.listingsForBrandVersion(
        bvId,
        includeDeleted: true,
      );
      expect(listings.map((l) => l.supplierId), contains(supplierId));

      final catalogTree = buildCatalogTree(await catalog.loadTreeSnapshot());
      final pickerTree = buildCatalogTree(
        await catalog.loadTreeSnapshot(activeOnly: true),
      );
      expect(_treeLabels(catalogTree), isNot(contains('Decora outlet')));
      expect(_treeLabels(pickerTree), isNot(contains('Decora outlet')));

      final splits = await db.jobsDao.orderSplitsForLine(lineId);
      expect(splits, hasLength(1));
      expect(splits.first.supplierId, supplierId);
      expect(splits.first.quantity, 6);

      final allowed = jobLineEditorSupplierIds(
        listingSupplierIds: listings.map((l) => l.supplierId),
        existingSplitSupplierIds: splits.map((s) => s.supplierId),
        preserveExistingSplits: true,
      );
      expect(allowed, contains(supplierId));

      await db.jobsDao.replaceOrderSplits(
        lineId: lineId,
        splits: [
          for (final s in splits) (supplierId: s.supplierId, qty: s.quantity),
        ],
        deviceId: deviceId,
      );
      final saved = await db.jobsDao.orderSplitsForLine(lineId);
      expect(saved, hasLength(1));
      expect(saved.first.supplierId, supplierId);
      expect(saved.first.quantity, 6);
    },
  );
}

Set<String> _treeLabels(List<CatalogTreeNode> nodes) {
  final labels = <String>{};
  void walk(CatalogTreeNode n) {
    labels.add(n.label);
    for (final c in n.children) {
      walk(c);
    }
  }

  for (final n in nodes) {
    walk(n);
  }
  return labels;
}
