import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/daos/parts_dao.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/part_photo_store.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

class _ReadGateDatabase extends AppDatabase {
  _ReadGateDatabase(File file) : super.forTesting(NativeDatabase(file));
  late final gatedParts = _ReadGatePartsDao(this);
  @override
  PartsDao get partsDao => gatedParts;
}

class _ReadGatePartsDao extends PartsDao {
  _ReadGatePartsDao(super.db);
  bool armed = false;
  final read = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Part?> getPart(String partId, {bool includeDeleted = false}) async {
    final result = await super.getPart(partId, includeDeleted: includeDeleted);
    if (armed) {
      armed = false;
      read.complete();
      await release.future;
    }
    return result;
  }
}

class _BaselinePhotoStore extends PartPhotoStore {
  const _BaselinePhotoStore();
  @override
  Future<String> saveForPart({
    required String partId,
    required Uint8List bytes,
    Directory? root,
  }) async {
    if (root == null) throw StateError('Synthetic photo root is required');
    final generated = await super.saveForPart(
      partId: partId,
      bytes: bytes,
      root: root,
    );
    await File('${root.path}/$generated')
        .rename('${root.path}/baseline-photo.jpg');
    return 'baseline-photo.jpg';
  }
}

class _CleanupFailureStore extends PartPhotoStore {
  const _CleanupFailureStore();
  @override
  Future<void> deleteAt(String stored, {Directory? root}) async {
    throw FileSystemException('synthetic photo cleanup failure', stored);
  }
}

void main() {
  late Directory directory;
  late File file;
  late _ReadGateDatabase db;
  AppDatabase? writer;
  late PinService pin;
  late String device, part;
  late EditDrafts edits;

  PartInput named(PartInput input, String name) => PartInput(
    nameText: name,
    descriptionText: input.descriptionText,
    specsText: input.specsText,
    uomText: input.uomText,
    categoryId: input.categoryId,
    styleId: input.styleId,
    typeId: input.typeId,
    defaultSupplierId: input.defaultSupplierId,
    active: input.active,
  );
  Future<CatalogRepository> external() async {
    writer = AppDatabase.forTesting(NativeDatabase(file));
    await writer!.customSelect('SELECT 1').get();
    return CatalogRepository(writer!, PinService(writer!.settingsDao), device);
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('issue134-snapshot-photo-');
    file = File('${directory.path}/synthetic.sqlite');
    db = _ReadGateDatabase(file);
    writer = null;
    device = await db.settingsDao.ensureDeviceId();
    pin = PinService(db.settingsDao);
    await db.taxonomyDao.insertCategory(
      id: 'c',
      name: 'Electrical',
      deviceId: device,
    );
    await db.taxonomyDao.insertStyle(
      id: 's',
      categoryId: 'c',
      name: 'Outlet',
      deviceId: device,
    );
    await db.taxonomyDao.insertType(
      id: 't',
      styleId: 's',
      name: 'Duplex',
      deviceId: device,
    );
    part = await CatalogRepository(db, pin, device).createGeneralPart(
      name: 'Original visible value',
      categoryId: 'c',
      styleId: 's',
      typeId: 't',
    );
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
  });
  tearDown(() async {
    if (!db.gatedParts.release.isCompleted) db.gatedParts.release.complete();
    await writer?.close();
    await db.close();
    await directory.delete(recursive: true);
  });

  test('fresh input and base share one real SQLite snapshot across an external repository commit', () async {
    await db.customSelect('PRAGMA journal_mode = WAL').get();
    final catalog = await external();
    db.gatedParts.armed = true;
    final pending = edits.openPart(part);
    await db.gatedParts.read.future.timeout(const Duration(seconds: 2));
    await catalog.updatePart(
      partId: part,
      name: 'External committed value',
      description: '',
      uom: 'ea',
      active: true,
      categoryId: 'c',
      styleId: 's',
      typeId: 't',
    );
    db.gatedParts.release.complete();
    final session = (await pending as FreshEdit<PartEditSession>).session;
    expect(session.initial.nameText, 'Original visible value');
    session.replace(named(session.initial, 'My later unfinished edit'));
    await session.flush();
    await expectLater(session.save(), throwsStateError);
    expect((await catalog.getPart(part))!.name, 'External committed value');
    expect(session.initial.nameText, 'My later unfinished edit');
  });

  for (final action in ['clear', 'attach']) {
    test(
      '$action photo cleanup failure retains committed draft base through capture and reopen',
      () async {
        final bytes = Uint8List.fromList(
          image.encodePng(image.Image(width: 2, height: 2)),
        );
        final catalog = CatalogRepository(db, pin, device);
        await catalog.attachPhoto(
          partId: part,
          bytes: bytes,
          root: directory,
          store: const _BaselinePhotoStore(),
        );
        final original = (await catalog.getPart(part))!;
        final session =
            (await edits.openPart(part) as FreshEdit<PartEditSession>).session;
        session.replace(named(session.initial, '  Before committed photo  '));
        await session.flush();
        final messages = <String>[];
        final previousPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) messages.add(message);
        };
        addTearDown(() => debugPrint = previousPrint);
        final actionFuture = action == 'clear'
            ? session.clearPhoto(
                store: const _CleanupFailureStore(),
                root: directory,
              )
            : session.attachPhoto(
                bytes: bytes,
                store: const _CleanupFailureStore(),
                root: directory,
              );
        await actionFuture;
        final phase = action == 'clear' ? 'clear commit' : 'attachment commit';
        expect(messages, contains(contains(phase)));
        expect(messages.join('\n'), isNot(contains(directory.path)));
        final changed = (await catalog.getPart(part))!;
        expect(changed.revision, original.revision + 1);
        if (action == 'clear') {
          expect(changed.photoPath, isNull);
        } else {
          expect(changed.photoPath, isNot(original.photoPath));
        }
        session.replace(
          named(session.initial, '  After committed cleanup failure  '),
        );
        await session.leave(LeaveIntent.back);
        await db.close();
        db = _ReadGateDatabase(file);
        pin = PinService(db.settingsDao);
        edits = EditDrafts(db: db, pin: pin, deviceId: device);
        final opening = await edits.openPart(part);
        expect(opening, isA<RecoverableEdit<PartEditSession>>());
        final recovered = await (opening as RecoverableEdit<PartEditSession>)
            .resume();
        expect(
          recovered.initial.nameText,
          '  After committed cleanup failure  ',
        );
        await recovered.save();
        final saved = (await CatalogRepository(db, pin, device).getPart(part))!;
        expect(saved.name, 'After committed cleanup failure');
        expect(saved.photoPath, changed.photoPath);
        expect(saved.revision, original.revision + 2);
      },
    );
  }
}
