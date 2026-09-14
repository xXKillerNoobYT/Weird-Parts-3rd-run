import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:wired_parts/features/catalog/part_photo_store.dart';

Uint8List _png({int width = 32, int height = 32}) {
  final raw = img.Image(width: width, height: height);
  img.fill(raw, color: img.ColorRgb8(20, 80, 160));
  return Uint8List.fromList(img.encodePng(raw));
}

void main() {
  test('compress shrinks a large image to max edge JPEG', () {
    final jpeg = PartPhotoStore.compress(_png(width: 2400, height: 1200));
    final decoded = img.decodeJpg(jpeg);
    expect(decoded, isNotNull);
    expect(decoded!.width, PartPhotoStore.maxEdge);
    expect(decoded.height, 800);
  });

  test('saveForPart stores a versioned relative jpeg name', () async {
    final dir = Directory.systemTemp.createTempSync('wp-photo-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final stored = await const PartPhotoStore().saveForPart(
      partId: 'part-1',
      bytes: _png(),
      root: dir,
    );
    expect(p.isAbsolute(stored), isFalse);
    expect(stored, startsWith('part-1-'));
    expect(stored, endsWith('.jpg'));
    final file = await const PartPhotoStore().resolveFile(stored, root: dir);
    expect(file.existsSync(), isTrue);
  });

  test('resolveFile does not open a host path outside part_photos', () async {
    final photos = Directory.systemTemp.createTempSync('wp-photo-root-');
    final host = Directory.systemTemp.createTempSync('wp-photo-host-');
    addTearDown(() {
      photos.deleteSync(recursive: true);
      host.deleteSync(recursive: true);
    });
    File(p.join(photos.path, 'part-1-1.jpg')).writeAsBytesSync(const [9, 9]);
    final secret = File(p.join(host.path, 'secret.txt'))
      ..writeAsStringSync('do-not-open');
    final file = await const PartPhotoStore().resolveFile(
      secret.path,
      root: photos,
    );
    expect(p.isWithin(photos.path, file.path), isTrue);
    expect(file.path, isNot(secret.path));
    expect(secret.existsSync(), isTrue);
    expect(secret.readAsStringSync(), 'do-not-open');
  });

  test('deleteAt does not delete a host file outside part_photos', () async {
    final photos = Directory.systemTemp.createTempSync('wp-photo-del-root-');
    final host = Directory.systemTemp.createTempSync('wp-photo-del-host-');
    addTearDown(() {
      photos.deleteSync(recursive: true);
      host.deleteSync(recursive: true);
    });
    final secret = File(p.join(host.path, 'secret.txt'))
      ..writeAsStringSync('keep-me');
    await const PartPhotoStore().deleteAt(secret.path, root: photos);
    expect(secret.existsSync(), isTrue);
    expect(secret.readAsStringSync(), 'keep-me');
  });

  test('resolveFile falls back to copied basename when absolute path is gone',
      () async {
    final dir = Directory.systemTemp.createTempSync('wp-photo-restore-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'part-1-1.jpg')).writeAsBytesSync(const [9, 9]);
    final file = await const PartPhotoStore().resolveFile(
      r'C:\Users\old\part_photos\part-1-1.jpg',
      root: dir,
    );
    expect(p.basename(file.path), 'part-1-1.jpg');
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), [9, 9]);
  });
}
