import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Compress and store part photos under Application Support.
class PartPhotoStore {
  const PartPhotoStore();

  static const maxEdge = 1600;
  static const jpegQuality = 75;

  /// Decode any common still image and write a JPEG no wider/taller than [maxEdge].
  static Uint8List compress(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Could not read photo');
    }
    var out = decoded;
    if (out.width > maxEdge || out.height > maxEdge) {
      if (out.width >= out.height) {
        out = img.copyResize(out, width: maxEdge);
      } else {
        out = img.copyResize(out, height: maxEdge);
      }
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: jpegQuality));
  }

  Future<String> saveForPart({
    required String partId,
    required Uint8List bytes,
    Directory? root,
  }) async {
    final compressed = compress(bytes);
    final dir = root ?? await photosDirectory();
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$partId.jpg'));
    await file.writeAsBytes(compressed, flush: true);
    return file.path;
  }

  Future<void> deleteAt(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<Directory> photosDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'part_photos'));
  }
}
