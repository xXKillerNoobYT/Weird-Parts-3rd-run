import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';

import '../../tool/nearby_lan_validation.dart';
import '../../tool/nearby_lan_workspace.dart';
import '../../tool/native_nearby_restart.dart';
import '../../tool/native_nearby_test_crypto.dart';
import '../../tool/native_nearby_test_commands.dart';
import '../../tool/native_nearby_test_fixture.dart';

void main() {
  late Directory temp;
  late File expectationFile;
  late ValidationWorkspace workspace;
  late AppDatabase db;
  late NativeFixtureSnapshot baseline;
  late Map<String, dynamic> envelope;
  const revision = '1111111111111111111111111111111111111111';
  const tree = '2222222222222222222222222222222222222222';

  NativeRestartExpectation read({
    bool enabled = true,
    String platform = 'macos',
    String run = nativeRestartRun,
    String role = 'sender',
    String sourceRevision = revision,
    String sourceTree = tree,
    String? path,
  }) => NativeRestartExpectation.read(
    enabled: enabled,
    platform: platform,
    run: run,
    role: role,
    path: path ?? expectationFile.path,
    sourceRevision: sourceRevision,
    sourceTree: sourceTree,
  );
  void save() => expectationFile.writeAsStringSync(jsonEncode(envelope));
  Map<String, List<int>> bytes() => {
    for (final file in temp.listSync(recursive: true).whereType<File>())
      p.relative(file.path, from: temp.path): file.readAsBytesSync(),
  };

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('native-restart-unit-');
    workspace = ValidationWorkspace.open(
      run: nativeRestartRun,
      role: ValidationRole.sender,
      temporaryDirectory: temp,
    );
    db = AppDatabase.forTesting(
      NativeDatabase(File(p.join(workspace.support.path, kSqliteFileName))),
    );
    await seedValidationShop(db, workspace);
    await db.settingsDao.setSetting('editor_pin_hash', 'private-pin-canary');
    await db.customStatement('UPDATE jobs SET notes=notes||? WHERE id=?', [
      ' [native-nearby-test:leg1] [native-nearby-test:leg2]',
      '$nativeRestartRun-sender-job',
    ]);
    await db.settingsDao.setSetting(
      'last_nearby_peer',
      'lan-$nativeRestartRun-receiver',
    );
    await db.settingsDao.setSetting(
      'last_nearby_at',
      '2026-10-09T16:00:00.000Z',
    );
    workspace.markInitialized();
    baseline = await NativeFixtureSnapshot.capture(db, workspace);
    envelope = <String, dynamic>{
      'format': 1,
      'run': nativeRestartRun,
      'role': 'sender',
      'sourceRevision': revision,
      'sourceTree': tree,
      'stage': 'postLeg3',
      'ownerDigest': baseline.ownerDigest,
      'proof': <String, dynamic>{
        'domainDigest': baseline.digest,
        'assetsDigest': baseline.assetsDigest,
        'completeSettingsDigest': baseline.completeSettingsDigest,
        'sharedSettingsDigestIncludingPin':
            baseline.privateSharedSettingsDigest,
        'profileDigest': baseline.profileDigest,
        'pinDigest': baseline.privatePinDigest,
        'schemaVersion': baseline.schemaVersion,
        'tableCount': baseline.domain.length,
        'rowCount': baseline.rowCount,
        'assetCount': baseline.assets.length,
        'referenceCount': baseline.referenceCount,
        'integrityValid': baseline.integrityValid,
        'referencesValid': baseline.referencesValid,
      },
    };
    expectationFile = File(p.join(temp.path, 'private-expectation.json'));
    save();
    workspace.close();
  });
  tearDown(() async {
    await db.close();
    workspace.close();
    temp.deleteSync(recursive: true);
  });

  test(
    'exact post-leg3 proof verifies without changing stored bytes',
    () async {
      final expected = read();
      final before = bytes();
      expected.verify(await NativeFixtureSnapshot.capture(db, workspace));
      expect(bytes(), before);
      await db.close();
      workspace.close();
      final cold = bytes();
      final reopened = expected.open(temporaryDirectory: temp);
      reopened.close();
      expect(bytes(), cold);
    },
  );

  test(
    'entry flags, role, run, source and path refuse before file changes',
    () {
      final before = bytes();
      for (final attempt in <NativeRestartExpectation Function()>[
        () => read(enabled: false),
        () => read(platform: 'linux'),
        () => read(role: 'receiver'),
        () => read(run: 'nearby-integration-probe-x'),
        () => read(sourceRevision: tree),
        () => read(sourceTree: revision),
        () => read(sourceRevision: ''),
        () => read(path: 'relative.json'),
        () => read(path: p.join(temp.path, 'absent.json')),
      ]) {
        expect(attempt, throwsA(isA<NativeTestFailure>()));
      }
      expect(bytes(), before);
    },
  );

  for (final change in <String, Object?>{
    'format': 2,
    'stage': 'postLeg1',
    'role': 'receiver',
    'extra': true,
    'ownerDigest': 'private-canary-not-a-digest',
  }.entries) {
    test('expectation rejects ${change.key} mismatch without writes', () {
      envelope[change.key] = change.value;
      save();
      final before = bytes();
      expect(read, throwsA(isA<NativeTestFailure>()));
      expect(bytes(), before);
    });
  }

  for (final key in [
    'domainDigest',
    'assetsDigest',
    'completeSettingsDigest',
    'sharedSettingsDigestIncludingPin',
    'profileDigest',
    'pinDigest',
    'rowCount',
    'referenceCount',
  ]) {
    test('comparison rejects a changed $key without writes', () {
      final proof = envelope['proof'] as Map<String, dynamic>;
      proof[key] =
          key.endsWith('Digest') || key == 'sharedSettingsDigestIncludingPin'
          ? 'a' * 64
          : (proof[key] as int) + 1;
      save();
      final expected = read();
      final before = bytes();
      expect(
        () => expected.verify(baseline),
        throwsA(isA<NativeTestFailure>()),
      );
      expect(bytes(), before);
    });
  }

  for (final key in [
    'schemaVersion',
    'tableCount',
    'assetCount',
    'integrityValid',
    'referencesValid',
  ]) {
    test('admission rejects invalid proof $key without writes', () {
      final proof = envelope['proof'] as Map<String, dynamic>;
      proof[key] = proof[key] is bool ? false : 99;
      save();
      final before = bytes();
      expect(read, throwsA(isA<NativeTestFailure>()));
      expect(bytes(), before);
    });
  }

  for (final directory in [
    'support',
    'documents',
    'temporary',
    'cache',
    'library',
    'downloads',
    'receipts',
    p.join('support', 'part_photos'),
  ]) {
    test('missing $directory is rejected without recreating it', () async {
      final expected = read();
      await db.close();
      workspace.close();
      final source = Directory(p.join(workspace.root.path, directory));
      source.renameSync('${source.path}.saved');
      final before = bytes();
      expect(
        () => expected.open(temporaryDirectory: temp),
        throwsA(isA<NativeTestFailure>()),
      );
      expect(source.existsSync(), false);
      expect(bytes(), before);
    });
  }

  test(
    'pending restore is rejected without recovery or byte changes',
    () async {
      final expected = read();
      await db.close();
      workspace.close();
      File(p.join(workspace.support.path, kRestoreSwapMarkerName))
          .writeAsStringSync('in-progress');
      final before = bytes();
      expect(
        () => expected.open(temporaryDirectory: temp),
        throwsA(isA<NativeTestFailure>()),
      );
      expect(bytes(), before);
    },
  );

  test('changed owner and missing database refuse without writes', () async {
    final expected = read();
    await db.close();
    workspace.close();
    final file = File(p.join(workspace.support.path, kSqliteFileName));
    file.renameSync('${file.path}.saved');
    final before = bytes();
    expect(
      () => expected.open(temporaryDirectory: temp),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(bytes(), before);
    File('${file.path}.saved').renameSync(file.path);
    File(p.join(workspace.root.path, 'validation-owner.json'))
        .writeAsStringSync('{}');
    final altered = bytes();
    expect(
      () => expected.open(temporaryDirectory: temp),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(bytes(), altered);
  });

  for (final mutation in [
    'notes',
    'relation',
    'tombstone',
    'photo',
    'profile',
    'pin',
    'settings',
  ]) {
    test('actual $mutation change invalidates the accepted proof', () async {
      final expected = read();
      switch (mutation) {
        case 'notes':
          await db.customStatement(
            "UPDATE jobs SET notes='old pre-leg state' WHERE deleted_at IS NULL",
          );
        case 'relation':
          await db.customStatement(
            "UPDATE job_lines SET part_id='missing-part'",
          );
        case 'tombstone':
          await db.customStatement(
            'UPDATE jobs SET deleted_at=NULL WHERE deleted_at IS NOT NULL',
          );
        case 'photo':
          File(p.join(workspace.photos.path, '$nativeRestartRun-sender.png'))
              .writeAsBytesSync([1, 2, 3]);
        case 'profile':
          await db.customStatement(
            "UPDATE device_profiles SET display_name='changed'",
          );
        case 'pin':
          await db.settingsDao.setSetting(
            'editor_pin_hash',
            'changed-private-canary',
          );
        case 'settings':
          await db.settingsDao.setSetting('extra', 'changed');
      }
      final actual = await NativeFixtureSnapshot.capture(db, workspace);
      final before = bytes();
      expect(() => expected.verify(actual), throwsA(isA<NativeTestFailure>()));
      expect(bytes(), before);
    });
  }

  test('failure formatting never reveals private proof or input contents', () {
    envelope['proof'] = 'private-pin-canary';
    save();
    try {
      read();
      fail('malformed private proof accepted');
    } catch (error) {
      expect(error, isA<NativeTestFailure>());
      expect(error.toString(), 'NativeTestFailure');
      expect(
        (error as NativeTestFailure).outcome,
        'restart-admission-rejected',
      );
    }
  });
  Directory archivedCopy() {
    final archive = Directory(p.join(temp.path, 'cold-archive'))..createSync();
    for (final entry in workspace.root.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final path = p.join(
        archive.path,
        p.relative(entry.path, from: workspace.root.path),
      );
      if (entry is Directory) Directory(path).createSync(recursive: true);
      if (entry is File) entry.copySync(path);
    }
    return archive;
  }

  NativeTestSnapshotResult commitment({String? digest}) =>
      NativeTestSnapshotResult(
        digest: digest ?? baseline.digest,
        assetsDigest: baseline.assetsDigest,
        sharedSettingsDigest: baseline.sharedSettingsDigest,
        profileDigest: baseline.profileDigest,
        schemaVersion: 2,
        tableCount: baseline.domain.length,
        rowCount: baseline.rowCount,
        assetCount: 1,
        integrityValid: true,
        referencesValid: true,
        profileEqual: true,
        assetsEqual: true,
        settingsEqual: true,
        ownershipEqual: true,
        lastNearbySourceId: 'lan-$nativeRestartRun-receiver',
        lastNearbyAtMillis: DateTime.parse('2026-10-09T16:00:00.000Z')
            .millisecondsSinceEpoch,
      );

  test('archived-copy preparation binds native commitments and private PIN without changing archive bytes', () async {
    await db.close();
    final output = File(p.join(temp.path, 'prepared-private-expectation.json'));
    final archive = archivedCopy();
    final before = bytes();
    await prepareNativeRestartExpectation(
      archive: archive,
      role: ValidationRole.sender,
      postLeg3: commitment(),
      acceptedPinDigest: baseline.privatePinDigest,
      sourceRevision: revision,
      sourceTree: tree,
      destination: output,
    );
    final after = bytes()..remove(p.basename(output.path));
    expect(after, before);
    read(path: output.path).verify(baseline);
  });

  for (final mismatch in [
    'native-commitment',
    'private-pin',
    'existing-output',
    'live-installation',
  ]) {
    test(
      'archived preparation rejects $mismatch without modifying input or creating output',
      () async {
        await db.close();
        final output = File(
          p.join(temp.path, 'prepared-private-expectation.json'),
        );
        if (mismatch == 'existing-output') output.writeAsStringSync('retained');
        final archive = archivedCopy();
        final before = bytes();
        await expectLater(
          prepareNativeRestartExpectation(
            archive: mismatch == 'live-installation' ? workspace.root : archive,
            role: ValidationRole.sender,
            postLeg3: commitment(
              digest: mismatch == 'native-commitment' ? 'a' * 64 : null,
            ),
            acceptedPinDigest: mismatch == 'private-pin'
                ? 'a' * 64
                : baseline.privatePinDigest,
            sourceRevision: revision,
            sourceTree: tree,
            destination: output,
          ),
          throwsA(isA<NativeTestFailure>()),
        );
        expect(bytes(), before);
      },
    );
  }

  test('an expectation inside the installation is rejected without writes', () {
    final internal = File(
      p.join(workspace.documents.path, 'private-expectation.json'),
    );
    internal.writeAsStringSync(jsonEncode(envelope));
    final expected = read(path: internal.path);
    final before = bytes();
    expect(
      () => expected.open(temporaryDirectory: temp),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(bytes(), before);
  });
  test(
    'concurrent preparations never overwrite the same expectation destination',
    () async {
      await db.close();
      final archive = archivedCopy();
      final output = File(
        p.join(temp.path, 'concurrent-private-expectation.json'),
      );
      final before = bytes();
      Future<bool> prepare() async {
        try {
          await prepareNativeRestartExpectation(
            archive: archive,
            role: ValidationRole.sender,
            postLeg3: commitment(),
            acceptedPinDigest: baseline.privatePinDigest,
            sourceRevision: revision,
            sourceTree: tree,
            destination: output,
          );
          return true;
        } on NativeTestFailure {
          return false;
        }
      }

      final outcomes = await Future.wait([prepare(), prepare()]);
      expect(outcomes.where((success) => success).length, 1);
      read(path: output.path).verify(baseline);
      final after = bytes()..remove(p.basename(output.path));
      expect(after, before);
    },
  );
}
