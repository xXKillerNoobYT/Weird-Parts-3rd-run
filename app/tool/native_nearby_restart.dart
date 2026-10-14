import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:wired_parts/data/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/sqlite_file.dart';

import 'nearby_lan_workspace.dart';
import 'native_nearby_test_crypto.dart';
import 'native_nearby_test_commands.dart';
import 'native_nearby_test_fixture.dart';

const nativeRestartRun = 'nearby-lifecycle-20261007a';

final class NativeRestartExpectation {
  NativeRestartExpectation._(
    this.role,
    this.ownerDigest,
    this.proof,
    this._path,
  );

  final ValidationRole role;
  final String ownerDigest;
  final PrivateSnapshotProof proof;
  final String _path;

  static NativeRestartExpectation read({
    required bool enabled,
    required String platform,
    required String run,
    required String role,
    required String path,
    required String sourceRevision,
    required String sourceTree,
  }) {
    try {
      if (!enabled ||
          run != nativeRestartRun ||
          !((platform == 'windows' && role == 'receiver') ||
              (platform == 'macos' && role == 'sender')) ||
          !RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceRevision) ||
          !RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceTree) ||
          path.length > 1024 ||
          !p.isAbsolute(path) ||
          p.normalize(path) != path ||
          FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.file) {
        rejectNativeTest();
      }
      final file = File(path);
      if (file.resolveSymbolicLinksSync() != path ||
          file.lengthSync() > 8192 ||
          file.lengthSync() == 0) {
        rejectNativeTest();
      }
      final data = nativeTestMap(jsonDecode(file.readAsStringSync()), {
        'format',
        'run',
        'role',
        'sourceRevision',
        'sourceTree',
        'stage',
        'ownerDigest',
        'proof',
      });
      if (data['format'] != 1 ||
          data['run'] != run ||
          data['role'] != role ||
          data['sourceRevision'] != sourceRevision ||
          data['sourceTree'] != sourceTree ||
          data['stage'] != 'postLeg3' ||
          data['ownerDigest'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['ownerDigest'] as String)) {
        rejectNativeTest();
      }
      final proof = PrivateSnapshotProof.fromJson(data['proof']);
      if (proof.schemaVersion != 2 ||
          proof.tableCount != 13 ||
          proof.assetCount != 1 ||
          !proof.integrityValid ||
          !proof.referencesValid) {
        rejectNativeTest();
      }
      return NativeRestartExpectation._(
        ValidationRole.values.byName(role),
        data['ownerDigest'] as String,
        proof,
        path,
      );
    } catch (_) {
      rejectNativeTest('restart-admission-rejected');
    }
  }

  ValidationWorkspace open({Directory? temporaryDirectory}) {
    ValidationWorkspace? workspace;
    try {
      final temp = (temporaryDirectory ?? Directory.systemTemp)
          .resolveSymbolicLinksSync();
      final root = p.join(
        temp,
        'wired-parts-lan-$nativeRestartRun-${role.name}',
      );
      if (p.isWithin(root, _path) || root == _path) rejectNativeTest();
      void check() {
        for (final name in [
          '',
          'support',
          'documents',
          'temporary',
          'cache',
          'library',
          'downloads',
          'receipts',
          p.join('support', 'part_photos'),
        ]) {
          if (FileSystemEntity.typeSync(
                p.join(root, name),
                followLinks: false,
              ) !=
              FileSystemEntityType.directory) {
            rejectNativeTest();
          }
        }
        if (FileSystemEntity.typeSync(
                  p.join(root, 'validation-owner.json'),
                  followLinks: false,
                ) !=
                FileSystemEntityType.file ||
            FileSystemEntity.typeSync('$root.lock', followLinks: false) !=
                FileSystemEntityType.file ||
            FileSystemEntity.typeSync(
                  p.join(root, 'support', kRestoreSwapMarkerName),
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound ||
            sha256
                    .convert(
                      File(p.join(root, 'validation-owner.json'))
                          .readAsBytesSync(),
                    )
                    .toString() !=
                ownerDigest) {
          rejectNativeTest();
        }
      }

      check();
      workspace = openExistingNativeFixture(
        run: nativeRestartRun,
        role: role,
        temporaryDirectory: temporaryDirectory,
      );
      check();
      return workspace;
    } catch (_) {
      workspace?.close();
      rejectNativeTest('restart-fixture-rejected');
    }
  }

  void verify(NativeFixtureSnapshot actual) {
    final job = actual.domain['jobs']
        ?.where((row) => row['id'] == '$nativeRestartRun-sender-job')
        .singleOrNull;
    if (actual.digest != proof.domainDigest ||
        actual.assetsDigest != proof.assetsDigest ||
        actual.completeSettingsDigest != proof.completeSettingsDigest ||
        actual.privateSharedSettingsDigest !=
            proof.sharedSettingsDigestIncludingPin ||
        actual.profileDigest != proof.profileDigest ||
        actual.privatePinDigest != proof.pinDigest ||
        actual.ownerDigest != ownerDigest ||
        actual.schemaVersion != proof.schemaVersion ||
        actual.domain.length != proof.tableCount ||
        actual.rowCount != proof.rowCount ||
        actual.assets.length != proof.assetCount ||
        actual.referenceCount != proof.referenceCount ||
        !actual.integrityValid ||
        !actual.referencesValid ||
        actual.setting('editor_pin_hash') is! String ||
        (actual.setting('editor_pin_hash') as String).isEmpty ||
        job == null ||
        job['notes'] is! String ||
        !(job['notes'] as String).endsWith(
          ' [native-nearby-test:leg1] [native-nearby-test:leg2]',
        )) {
      rejectNativeTest('restart-state-mismatch');
    }
  }
}

Future<void> prepareNativeRestartExpectation({
  required Directory archive,
  required ValidationRole role,
  required NativeTestSnapshotResult postLeg3,
  required String acceptedPinDigest,
  required String sourceRevision,
  required String sourceTree,
  required File destination,
}) async {
  Directory? scratch;
  ValidationWorkspace? workspace;
  AppDatabase? db;
  try {
    final archivePath = archive.resolveSymbolicLinksSync();
    if (archivePath != p.normalize(archive.path) ||
        !p.isAbsolute(destination.path) ||
        p.normalize(destination.path) != destination.path ||
        destination.parent.resolveSymbolicLinksSync() !=
            destination.parent.path ||
        p.isWithin(archivePath, destination.path) ||
        FileSystemEntity.typeSync(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(acceptedPinDigest) ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceRevision) ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceTree)) {
      rejectNativeTest();
    }
    for (final entry in archive.listSync(recursive: true, followLinks: false)) {
      if (FileSystemEntity.typeSync(entry.path, followLinks: false) ==
          FileSystemEntityType.link) {
        rejectNativeTest();
      }
    }
    final ownerFile = File(p.join(archivePath, 'validation-owner.json'));
    final owner = nativeTestMap(jsonDecode(ownerFile.readAsStringSync()), {
      'format',
      'run',
      'role',
      'root',
      'initialized',
    });
    if (owner['format'] != 1 ||
        owner['run'] != nativeRestartRun ||
        owner['role'] != role.name ||
        owner['initialized'] != true ||
        owner['root'] is! String ||
        !p.isAbsolute(owner['root'] as String) ||
        owner['root'] == archivePath ||
        p.basename(owner['root'] as String) !=
            'wired-parts-lan-$nativeRestartRun-${role.name}' ||
        FileSystemEntity.typeSync(
              p.join(archivePath, 'support', kRestoreSwapMarkerName),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
      rejectNativeTest();
    }
    scratch = Directory.systemTemp.createTempSync('native-restart-expected-');
    workspace = ValidationWorkspace.open(
      run: nativeRestartRun,
      role: role,
      temporaryDirectory: scratch,
    );
    final archiveSupport = p.join(archivePath, 'support');
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final original = File(p.join(archiveSupport, '$kSqliteFileName$suffix'));
      if (suffix.isEmpty || original.existsSync()) {
        original.copySync(
          p.join(workspace.support.path, '$kSqliteFileName$suffix'),
        );
      }
    }
    workspace.photos.createSync();
    for (final original in Directory(
      p.join(archiveSupport, 'part_photos'),
    ).listSync(followLinks: false)) {
      if (original is! File) rejectNativeTest();
      original.copySync(
        p.join(workspace.photos.path, p.basename(original.path)),
      );
    }
    ownerFile.copySync(p.join(workspace.root.path, 'validation-owner.json'));
    db = AppDatabase.forTesting(
      NativeDatabase.opened(
        raw.sqlite3.open(
          p.join(workspace.support.path, kSqliteFileName),
          mode: raw.OpenMode.readOnly,
        ),
        enableMigrations: false,
      ),
    );
    final state = await NativeFixtureSnapshot.capture(db, workspace);
    final at = state.setting('last_nearby_at');
    if (state.digest != postLeg3.digest ||
        state.assetsDigest != postLeg3.assetsDigest ||
        state.sharedSettingsDigest != postLeg3.sharedSettingsDigest ||
        state.profileDigest != postLeg3.profileDigest ||
        state.schemaVersion != postLeg3.schemaVersion ||
        state.domain.length != postLeg3.tableCount ||
        state.rowCount != postLeg3.rowCount ||
        state.assets.length != postLeg3.assetCount ||
        !postLeg3.integrityValid ||
        !postLeg3.referencesValid ||
        !postLeg3.profileEqual ||
        !postLeg3.ownershipEqual ||
        state.privatePinDigest != acceptedPinDigest ||
        state.setting('last_nearby_peer') != postLeg3.lastNearbySourceId ||
        at is! String ||
        DateTime.tryParse(at)?.millisecondsSinceEpoch !=
            postLeg3.lastNearbyAtMillis) {
      rejectNativeTest();
    }
    final proof = <String, Object>{
      'domainDigest': state.digest,
      'assetsDigest': state.assetsDigest,
      'completeSettingsDigest': state.completeSettingsDigest,
      'sharedSettingsDigestIncludingPin': state.privateSharedSettingsDigest,
      'profileDigest': state.profileDigest,
      'pinDigest': state.privatePinDigest,
      'schemaVersion': state.schemaVersion,
      'tableCount': state.domain.length,
      'rowCount': state.rowCount,
      'assetCount': state.assets.length,
      'referenceCount': state.referenceCount,
      'integrityValid': state.integrityValid,
      'referencesValid': state.referencesValid,
    };
    final parsed = PrivateSnapshotProof.fromJson(proof);
    NativeRestartExpectation._(
      role,
      state.ownerDigest,
      parsed,
      destination.path,
    ).verify(state);
    destination.createSync(exclusive: true);
    destination.writeAsStringSync(
      jsonEncode(<String, Object>{
        'format': 1,
        'run': nativeRestartRun,
        'role': role.name,
        'sourceRevision': sourceRevision,
        'sourceTree': sourceTree,
        'stage': 'postLeg3',
        'ownerDigest': state.ownerDigest,
        'proof': proof,
      }),
      flush: true,
    );
  } catch (_) {
    rejectNativeTest('restart-preparation-rejected');
  } finally {
    try {
      try {
        await db?.close();
      } finally {
        try {
          workspace?.close();
        } finally {
          if (scratch != null &&
              p.basename(scratch.path).startsWith('native-restart-expected-') &&
              p.isWithin(
                Directory.systemTemp.resolveSymbolicLinksSync(),
                scratch.resolveSymbolicLinksSync(),
              )) {
            scratch.deleteSync(recursive: true);
          }
        }
      }
    } catch (_) {
      rejectNativeTest('restart-preparation-cleanup-failed');
    }
  }
}
