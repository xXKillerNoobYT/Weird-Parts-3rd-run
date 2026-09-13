import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:wired_parts/features/catalog/part_photo_store.dart';

void main() {
  test('compress shrinks a large image to max edge JPEG', () {
    final raw = img.Image(width: 2400, height: 1200);
    img.fill(raw, color: img.ColorRgb8(20, 80, 160));
    final png = Uint8List.fromList(img.encodePng(raw));

    final jpeg = PartPhotoStore.compress(png);
    final decoded = img.decodeJpg(jpeg);
    expect(decoded, isNotNull);
    expect(decoded!.width, PartPhotoStore.maxEdge);
    expect(decoded.height, 800);
    expect(decoded.width <= PartPhotoStore.maxEdge, isTrue);
    expect(decoded.height <= PartPhotoStore.maxEdge, isTrue);
  });

  test('saveForPart writes a jpeg under the given root', () async {
    final dir = Directory.systemTemp.createTempSync('wp-photo-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final raw = img.Image(width: 32, height: 32);
    img.fill(raw, color: img.ColorRgb8(1, 2, 3));
    final path = await const PartPhotoStore().saveForPart(
      partId: 'part-1',
      bytes: Uint8List.fromList(img.encodePng(raw)),
      root: dir,
    );
    expect(p.basename(path), 'part-1.jpg');
    expect(File(path).existsSync(), isTrue);
  });
}
