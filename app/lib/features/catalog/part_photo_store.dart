import 'dart:io';

import 'package:flutter/foundation.dart' hide Category;
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
      throw const FormatException(
        'Could not read photo. Try a JPEG or PNG, or Choose photo again.',
      );
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

  /// Returns a **relative** filename (not a sandbox-absolute path).
  Future<String> saveForPart({
    required String partId,
    required Uint8List bytes,
    Directory? root,
  }) async {
    final compressed = await compute(compress, bytes);
    final dir = root ?? await photosDirectory();
    await dir.create(recursive: true);
    final name = '$partId-${DateTime.now().millisecondsSinceEpoch}.jpg';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(compressed, flush: true);
    return name;
  }

  /// Resolves [stored] to a file inside [root] (or `part_photos`). Host
  /// paths from a crafted backup never open or delete files outside that dir.
  Future<File> resolveFile(String stored, {Directory? root}) async {
    final dir = root ?? await photosDirectory();
    await dir.create(recursive: true);
    var name = _photoBasename(stored);
    if (!_isSafePhotoBasename(name)) {
      name = '.rejected-photo';
    }
    final file = File(p.normalize(p.join(dir.path, name)));
    if (!_isInsideDirectory(dir, file)) {
      return File(p.join(dir.path, '.rejected-photo'));
    }
    return file;
  }

  Future<void> deleteAt(String stored, {Directory? root}) async {
    final file = await resolveFile(stored, root: root);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Deletes versioned `$partId-*.jpg` files (and a leftover `$partId.jpg`).
  Future<void> deleteAllForPart(String partId, {Directory? root}) async {
    final dir = root ?? await photosDirectory();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == '$partId.jpg' || name.startsWith('$partId-')) {
        await entity.delete();
      }
    }
  }

  Future<Directory> photosDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'part_photos'));
  }
}

String _photoBasename(String stored) {
  if (stored.contains('\\')) return p.windows.basename(stored);
  return p.posix.basename(stored);
}

bool _isSafePhotoBasename(String name) {
  if (name.isEmpty || name == '.' || name == '..') return false;
  if (name.contains('\u0000')) return false;
  return true;
}

bool _isInsideDirectory(Directory dir, File file) {
  final root = p.canonicalize(dir.path);
  final path = p.canonicalize(file.path);
  final rootPrefix = root.endsWith(p.separator) ? root : '$root${p.separator}';
  return path == root || path.startsWith(rootPrefix);
}
