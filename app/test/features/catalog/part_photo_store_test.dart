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

  test('resolveFile still opens a leftover absolute path', () async {
    final dir = Directory.systemTemp.createTempSync('wp-photo-abs-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final absolute = File(p.join(dir.path, 'old.jpg'))
      ..writeAsBytesSync(const [1, 2, 3]);
    final file = await const PartPhotoStore().resolveFile(absolute.path);
    expect(file.path, absolute.path);
    expect(file.existsSync(), isTrue);
  });
}
