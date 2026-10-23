import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/part_photo_store.dart';
import 'package:wired_parts/features/catalog/part_write_companion.dart';

import '../warehouse/warehouse_test_support.dart';

class _RecordingCompanion implements PartWriteCompanion {
  _RecordingCompanion({
    List<String>? events,
    this.rejectBeforeWrite = false,
    this.failAfterWrite = false,
    this.writeWitness = false,
  }) : events = events ?? <String>[];

  final bool rejectBeforeWrite;
  final bool failAfterWrite;
  final bool writeWitness;
  final List<String> events;
  final transactionStates = <String, List<bool>>{};
  AppDatabase? _db;

  void _recordTransaction(String hook, AppDatabase db) {
    transactionStates.putIfAbsent(hook, () => []).add(db.hasCallerTransaction);
  }

  @override
  void validatePhotoOperation() => events.add('validate');

  @override
  Future<void> beforePhotoReferenceWrite(AppDatabase db, String partId) async {
    _db = db;
    events.add('before');
    _recordTransaction('before', db);
    if (rejectBeforeWrite) throw StateError('synthetic before-hook refusal');
  }

  @override
  Future<void> afterPhotoReferenceWrite(AppDatabase db, String partId) async {
    _db = db;
    events.add('after');
    _recordTransaction('after', db);
    if (writeWitness) {
      await db.settingsDao.setSetting('test_photo_companion_witness', partId);
    }
    if (failAfterWrite) throw StateError('synthetic after-hook failure');
  }

  @override
  void photoReferenceCommitted() {
    events.add('commit');
    transactionStates
        .putIfAbsent('commit', () => [])
        .add(_db?.hasCallerTransaction ?? true);
  }
}

class _TrackingPhotoStore extends PartPhotoStore {
  _TrackingPhotoStore(this.events);

  final List<String> events;

  @override
  Future<void> deleteAt(String stored, {Directory? root}) async {
    events.add('cleanup');
    await super.deleteAt(stored, root: root);
  }
}

Uint8List _png(int red, int green, int blue) {
  final image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  return Uint8List.fromList(img.encodePng(image));
}

Future<Map<String, List<int>>> _photoSnapshot(Directory directory) async {
  if (!await directory.exists()) return {};
  final files = await directory
      .list()
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
  files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  return {
    for (final file in files) p.basename(file.path): await file.readAsBytes(),
  };
}

Future<WarehouseFixture> _fixture() async {
  final fixture = await WarehouseFixture.create();
  await fixture.pin.setPin('2468');
  expect(await fixture.pin.unlock('2468'), isTrue);
  return fixture;
}

void main() {
  test(
    'before-hook refusal removes staged photo and preserves prior state',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.db.close);
      final photos = await Directory.systemTemp.createTemp('wp-photo-before-');
      addTearDown(() => photos.delete(recursive: true));
      final first = await fixture.catalog.attachPhoto(
        partId: fixture.partId,
        bytes: _png(20, 80, 140),
        root: photos,
      );
      final priorSql = await fixture.snapshot();
      final priorPhotos = await _photoSnapshot(photos);
      final companion = _RecordingCompanion(rejectBeforeWrite: true);

      await expectLater(
        fixture.catalog.attachPhoto(
          partId: fixture.partId,
          bytes: _png(210, 30, 40),
          root: photos,
          companion: companion,
        ),
        throwsStateError,
      );

      expect(await fixture.snapshot(), priorSql);
      expect((await fixture.catalog.getPart(fixture.partId))!.photoPath, first);
      expect(await _photoSnapshot(photos), priorPhotos);
      expect(
        await File(p.join(photos.path, first)).readAsBytes(),
        priorPhotos[first],
      );
      expect(companion.events, ['validate', 'before']);
      expect(companion.transactionStates['before'], [true]);
    },
  );

  test(
    'after-hook failure rolls back reference and settings witness',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.db.close);
      final photos = await Directory.systemTemp.createTemp('wp-photo-after-');
      addTearDown(() => photos.delete(recursive: true));
      final first = await fixture.catalog.attachPhoto(
        partId: fixture.partId,
        bytes: _png(20, 80, 140),
        root: photos,
      );
      final priorSql = await fixture.snapshot();
      final priorPhotos = await _photoSnapshot(photos);
      final companion = _RecordingCompanion(
        failAfterWrite: true,
        writeWitness: true,
      );

      await expectLater(
        fixture.catalog.attachPhoto(
          partId: fixture.partId,
          bytes: _png(210, 30, 40),
          root: photos,
          companion: companion,
        ),
        throwsStateError,
      );

      expect(await fixture.snapshot(), priorSql);
      expect(
        await fixture.db.settingsDao.getSetting('test_photo_companion_witness'),
        isNull,
      );
      expect((await fixture.catalog.getPart(fixture.partId))!.photoPath, first);
      expect(await _photoSnapshot(photos), priorPhotos);
      expect(companion.events, ['validate', 'before', 'after']);
      expect(companion.transactionStates['before'], [true]);
      expect(companion.transactionStates['after'], [true]);
    },
  );

  test('successful hooks commit once before old-photo cleanup', () async {
    final fixture = await _fixture();
    addTearDown(fixture.db.close);
    final photos = await Directory.systemTemp.createTemp('wp-photo-commit-');
    addTearDown(() => photos.delete(recursive: true));
    final first = await fixture.catalog.attachPhoto(
      partId: fixture.partId,
      bytes: _png(20, 80, 140),
      root: photos,
    );
    final events = <String>[];
    final companion = _RecordingCompanion(events: events, writeWitness: true);
    final store = _TrackingPhotoStore(events);

    final second = await fixture.catalog.attachPhoto(
      partId: fixture.partId,
      bytes: _png(210, 30, 40),
      root: photos,
      store: store,
      companion: companion,
    );

    expect(events, ['validate', 'before', 'after', 'commit', 'cleanup']);
    expect(companion.transactionStates['before'], [true]);
    expect(companion.transactionStates['after'], [true]);
    expect(companion.transactionStates['commit'], [false]);
    expect(
      await fixture.db.settingsDao.getSetting('test_photo_companion_witness'),
      fixture.partId,
    );
    expect((await fixture.catalog.getPart(fixture.partId))!.photoPath, second);
    expect(
      await File(p.join(photos.path, second)).readAsBytes(),
      PartPhotoStore.compress(_png(210, 30, 40)),
    );
    expect(await File(p.join(photos.path, first)).exists(), isFalse);
    expect(await _photoSnapshot(photos), {
      second: PartPhotoStore.compress(_png(210, 30, 40)),
    });
  });
}
