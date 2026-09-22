import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

enum ValidationRole { sender, receiver }

class ValidationWorkspace extends PathProviderPlatform {
  ValidationWorkspace._(this.root, this.run, this.role, this.initialized);

  final Directory root;
  final String run;
  final ValidationRole role;
  final bool initialized;
  RandomAccessFile? _heldLock;

  Directory get support => Directory(p.join(root.path, 'support'));
  Directory get documents => Directory(p.join(root.path, 'documents'));
  Directory get photos => Directory(p.join(support.path, 'part_photos'));
  Directory get receipts => Directory(p.join(root.path, 'receipts'));
  String get deviceId => 'lan-$run-${role.name}';

  static ValidationWorkspace open({
    required String run,
    required ValidationRole role,
    Directory? temporaryDirectory,
  }) {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,47}$').hasMatch(run)) {
      throw ArgumentError(
        'Run must contain 1-48 lowercase letters, digits or hyphens',
      );
    }
    final temp = Directory(
      (temporaryDirectory ?? Directory.systemTemp).resolveSymbolicLinksSync(),
    );
    final root = Directory(
      p.join(temp.path, 'wired-parts-lan-$run-${role.name}'),
    );
    final type = FileSystemEntity.typeSync(root.path, followLinks: false);
    final marker = File(p.join(root.path, 'validation-owner.json'));
    var initialized = false;
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.directory ||
          FileSystemEntity.typeSync(marker.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw StateError('Refusing unowned validation directory');
      }
      final owner = jsonDecode(marker.readAsStringSync());
      if (owner is! Map ||
          owner['format'] != 1 ||
          owner['run'] != run ||
          owner['role'] != role.name ||
          owner['root'] != root.path ||
          owner['initialized'] != true) {
        throw StateError(
          'Validation ownership mismatch or interrupted initialization',
        );
      }
      initialized = true;
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError('Refusing symlink in validation directory');
        }
      }
    } else {
      root.createSync();
      marker.writeAsStringSync(
        jsonEncode({
          'format': 1,
          'run': run,
          'role': role.name,
          'root': root.path,
          'initialized': false,
        }),
        flush: true,
      );
    }
    final workspace = ValidationWorkspace._(root, run, role, initialized);
    workspace._heldLock = File(p.join(root.path, 'validation.lock'))
        .openSync(mode: FileMode.append);
    try {
      workspace._heldLock!.lockSync(FileLock.exclusive);
      for (final name in [
        'support',
        'documents',
        'temporary',
        'cache',
        'library',
        'downloads',
        'receipts',
      ]) {
        Directory(p.join(root.path, name)).createSync();
      }
    } catch (_) {
      workspace.close();
      rethrow;
    }
    return workspace;
  }

  void markInitialized() {
    File(p.join(root.path, 'validation-owner.json')).writeAsStringSync(
      jsonEncode({
        'format': 1,
        'run': run,
        'role': role.name,
        'root': root.path,
        'initialized': true,
      }),
      flush: true,
    );
  }

  void close() {
    _heldLock?.closeSync();
    _heldLock = null;
  }

  @override
  Future<String> getApplicationSupportPath() async => support.path;
  @override
  Future<String> getApplicationDocumentsPath() async => documents.path;
  @override
  Future<String> getTemporaryPath() async => p.join(root.path, 'temporary');
  @override
  Future<String> getApplicationCachePath() async => p.join(root.path, 'cache');
  @override
  Future<String> getLibraryPath() async => p.join(root.path, 'library');
  @override
  Future<String> getDownloadsPath() async => p.join(root.path, 'downloads');
}
