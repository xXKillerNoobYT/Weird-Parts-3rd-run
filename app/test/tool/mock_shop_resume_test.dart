import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';

import '../../tool/mock_shop/adapter.dart';
import '../../tool/mock_shop/fixture.dart';
import '../../tool/mock_shop_app.dart' as inspection;

bool _sameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _removePath(String path) {
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.link:
      Link(path).deleteSync();
    case FileSystemEntityType.directory:
      for (final child in Directory(path).listSync(followLinks: false)) {
        _removePath(child.path);
      }
      Directory(path).deleteSync();
    case FileSystemEntityType.file:
      File(path).deleteSync();
    case FileSystemEntityType.notFound:
      break;
    default:
      throw StateError('Unexpected synthetic test path type');
  }
}

void _mutateDatabase(File file, void Function(raw.Database db) mutate) {
  final db = raw.sqlite3.open(file.path);
  try {
    mutate(db);
  } finally {
    db.dispose();
  }
}

void main() {
  late MockShopFixture fixture;
  final opened = <MockLocalWorkspace>[];
  final profileIds = <String>[];
  final profileFor = <MockLocalWorkspace, String>{};
  final extraPaths = <String>[];

  String profileId() {
    final value = 'resume-${const Uuid().v4()}';
    profileIds.add(value);
    return value;
  }

  Future<MockLocalWorkspace> create({bool imported = true}) async {
    final id = profileId();
    final workspace = await MockLocalWorkspace.createProfile(profileId: id);
    opened.add(workspace);
    profileFor[workspace] = id;
    if (imported) await workspace.import(fixture);
    return workspace;
  }

  Future<MockLocalWorkspace> resume(String id) async {
    final workspace = await MockLocalWorkspace.resumeProfile(
      profileId: id,
      fixture: fixture,
    );
    opened.add(workspace);
    profileFor[workspace] = id;
    return workspace;
  }

  Future<void> expectRefused(String id) async {
    final root = MockLocalWorkspace.profileRoot(id);
    final paths = [
      '${root.path}/wired_parts.sqlite',
      '${root.path}/wired_parts.sqlite-wal',
      '${root.path}/wired_parts.sqlite-shm',
      '${root.path}/owner',
      '${root.path}/profile.json',
    ];
    final before = {
      for (final path in paths)
        path: File(path).existsSync() ? File(path).readAsBytesSync() : null,
    };
    await expectLater(resume(id), throwsStateError);
    for (final path in paths) {
      final after = File(path).existsSync()
          ? File(path).readAsBytesSync()
          : null;
      expect(
        _sameBytes(before[path], after),
        isTrue,
        reason: 'Refused resume changed existing profile state',
      );
    }
  }

  setUpAll(() {
    fixture = MockShopFixture.read(Directory('test/fixtures/mock_shop'));
  });
  tearDown(() async {
    for (final workspace in opened.reversed) {
      await workspace.close();
    }
    for (final id in profileIds) {
      final root = MockLocalWorkspace.profileRoot(id);
      _removePath(root.path);
      _removePath('${root.path}.lock');
    }
    for (final path in extraPaths) {
      _removePath(path);
    }
    opened.clear();
    profileIds.clear();
    profileFor.clear();
    extraPaths.clear();
  });

  test('profile identifiers cannot select arbitrary or default paths', () {
    for (final id in [
      '',
      '../default',
      '/tmp/default',
      'UPPER',
      'with space',
      List.filled(49, 'a').join(),
    ]) {
      expect(() => MockLocalWorkspace.profileRoot(id), throwsArgumentError);
    }
  });

  test(
    'native launch selection preserves temporary mode and requires intent',
    () {
      expect(
        inspection.mockProfileSelection({}).mode,
        inspection.MockProfileMode.temporary,
      );
      for (final mode in ['create', 'resume']) {
        final selection = inspection.mockProfileSelection({
          'MOCK_SHOP_PROFILE_MODE': mode,
          'MOCK_SHOP_PROFILE_ID': 'synthetic-profile',
        });
        expect(selection.mode.name, mode);
        expect(selection.profileId, 'synthetic-profile');
      }
      for (final environment in [
        {'MOCK_SHOP_PROFILE_ID': 'synthetic-profile'},
        {'MOCK_SHOP_PROFILE_MODE': 'resume'},
        {
          'MOCK_SHOP_PROFILE_MODE': 'automatic',
          'MOCK_SHOP_PROFILE_ID': 'synthetic-profile',
        },
      ]) {
        expect(
          () => inspection.mockProfileSelection(environment),
          throwsStateError,
        );
      }
      expect(
        () => inspection.mockProfileSelection({
          'MOCK_SHOP_PROFILE_MODE': 'resume',
          'MOCK_SHOP_PROFILE_ID': '../default',
        }),
        throwsArgumentError,
      );
    },
  );

  test(
    'persistent profiles refuse a nonfrozen fixture without mutation',
    () async {
      final alternate = MockShopFixture.decode(
        utf8.encode(jsonEncode(fixture.raw)),
        MockShopFixture.readSourceBytes(Directory('test/fixtures/mock_shop')),
        requireFrozen: false,
      );
      final workspace = await create(imported: false);
      final beforeImport = await workspace.publicBusinessDigest();
      await expectLater(workspace.import(alternate), throwsStateError);
      expect(await workspace.publicBusinessDigest() == beforeImport, isTrue);
      await workspace.import(fixture);
      await workspace.close();
      final before = workspace.databaseFile.readAsBytesSync();
      await expectLater(
        MockLocalWorkspace.resumeProfile(
          profileId: profileFor[workspace]!,
          fixture: alternate,
        ),
        throwsStateError,
      );
      expect(
        _sameBytes(before, workspace.databaseFile.readAsBytesSync()),
        isTrue,
      );
    },
  );

  test('initialized profile publishes only public ownership binding', () async {
    final workspace = await create(imported: false);
    final binding = File('${workspace.root.path}/profile.json');
    expect(binding.existsSync(), isFalse);
    await workspace.import(fixture);
    final record =
        jsonDecode(binding.readAsStringSync()) as Map<String, dynamic>;
    expect(record['format'], 1);
    expect(record['profile_id'], profileFor[workspace]);
    expect(record['root'], workspace.root.resolveSymbolicLinksSync());
    expect(record['fixture_sha256'], fixture.sha256Value);
    expect(record['schema_version'], kAppSchemaVersion);
    expect(record['device_id'], workspace.deviceId);
    expect(
      record.keys.any((key) => RegExp('pin|secret|verifier').hasMatch(key)),
      isFalse,
    );
  });

  test(
    'resume preserves edited rows, identities and PIN while locked',
    () async {
      final original = await create();
      final id = profileFor[original]!;
      final currentPin = ephemeralMockPin();
      await original.pin.setPin(currentPin);
      expect(await original.pin.unlock(currentPin), isTrue);
      final verifier = await original.db.settingsDao.getSetting(
        'editor_pin_hash',
      );
      final deviceId = original.deviceId;
      final repo = JobsRepository(original.db, deviceId);
      final lineId = fixture.nativeId('material', 'MAT-001-01');
      final line = (await repo.getJobLine(lineId))!;
      await repo.updateLine(
        lineId: line.id,
        partId: line.partId,
        brandVersionId: line.brandVersionId,
        customName: line.customName,
        customNotes: line.customNotes,
        neededQty: line.neededQty,
        shopPullQty: line.shopPullQty,
        uom: line.uom,
        notes: 'Deliberate resume regression edit',
      );
      final before = await original.publicBusinessDigest();
      final jobs = (await original.db.select(original.db.jobs).get())
          .map((job) => job.id)
          .toSet();
      final relationships =
          (await original.db
                  .customSelect(
                    'SELECT id, job_id, part_id, brand_version_id FROM job_lines ORDER BY id',
                  )
                  .get())
              .map((row) => row.data)
              .toList();
      await original.close();

      final restored = await resume(id);
      expect(restored.deviceId, deviceId);
      expect(restored.pin.isUnlocked, isFalse);
      expect(await restored.pin.isPinSet(), isTrue);
      expect(
        await restored.db.settingsDao.getSetting('editor_pin_hash') == verifier,
        isTrue,
        reason: 'Resume must preserve the existing PIN state',
      );
      expect(await restored.publicBusinessDigest() == before, isTrue);
      final restoredJobs = await restored.db.select(restored.db.jobs).get();
      expect(restoredJobs, hasLength(7));
      expect(restoredJobs.map((job) => job.id).toSet(), jobs);
      expect(
        (await restored.db
                .customSelect(
                  'SELECT id, job_id, part_id, brand_version_id FROM job_lines ORDER BY id',
                )
                .get())
            .map((row) => row.data)
            .toList(),
        relationships,
      );
      final restoredRepo = JobsRepository(restored.db, restored.deviceId);
      expect(
        (await restoredRepo.getJobLine(lineId))!.notes,
        'Deliberate resume regression edit',
      );
      final wrongPin =
          '${currentPin[0] == '0' ? '1' : '0'}${currentPin.substring(1)}';
      expect(await restored.pin.unlock(wrongPin), isFalse);
      expect(restored.pin.isUnlocked, isFalse);
      expect(await restored.pin.unlock(currentPin), isTrue);
      expect(await restored.publicBusinessDigest() == before, isTrue);
    },
  );

  test(
    'exclusive profile claim survives until close and existing create refuses',
    () async {
      final first = await create();
      final id = profileFor[first]!;
      await expectLater(
        MockLocalWorkspace.createProfile(profileId: id),
        throwsStateError,
      );
      await expectLater(resume(id), throwsStateError);
      final before = await first.publicBusinessDigest();
      await first.close();
      await expectLater(
        MockLocalWorkspace.createProfile(profileId: id),
        throwsStateError,
      );
      final reopened = await resume(id);
      expect(await reopened.publicBusinessDigest() == before, isTrue);
    },
  );

  test(
    'temporary reopen helper cannot repair or unlock a named profile',
    () async {
      final workspace = await create();
      await workspace.db.delete(workspace.db.deviceProfiles).go();
      workspace.pin.lock();
      final before = await workspace.db.settingsDao.getSetting(
        'editor_pin_hash',
      );
      await expectLater(workspace.reopen(), throwsStateError);
      expect(
        (await workspace.db.select(workspace.db.deviceProfiles).get()).isEmpty,
        isTrue,
        reason: 'Refused named reopen must not create a device profile',
      );
      expect(workspace.pin.isUnlocked, isFalse);
      expect(
        await workspace.db.settingsDao.getSetting('editor_pin_hash') == before,
        isTrue,
      );
      expect(await workspace.db.select(workspace.db.jobs).get(), hasLength(7));
    },
  );

  test(
    'interrupted import cannot publish an initialized resume profile',
    () async {
      final workspace = await create(imported: false);
      final id = profileFor[workspace]!;
      await expectLater(
        workspace.import(
          fixture,
          beforeCommit: () async => throw StateError('Synthetic import fault'),
        ),
        throwsStateError,
      );
      expect(File('${workspace.root.path}/profile.json').existsSync(), isFalse);
      expect(await workspace.db.select(workspace.db.jobs).get(), isEmpty);
      await workspace.close();
      await expectRefused(id);
    },
  );

  test('missing profile resume never initializes a database', () async {
    final id = profileId();
    final root = MockLocalWorkspace.profileRoot(id);
    await expectRefused(id);
    expect(root.existsSync(), isFalse);
  });

  test(
    'unowned profile refuses without replacement and releases failed claim',
    () async {
      final id = profileId();
      final root = MockLocalWorkspace.profileRoot(id)..createSync();
      final sentinel = File('${root.path}/unowned-data')
        ..writeAsStringSync('keep');
      await expectRefused(id);
      await expectLater(
        MockLocalWorkspace.createProfile(profileId: id),
        throwsStateError,
      );
      expect(sentinel.readAsStringSync(), 'keep');
      _removePath(root.path);
      final recovered = await MockLocalWorkspace.createProfile(profileId: id);
      opened.add(recovered);
      await recovered.import(fixture);
    },
  );

  test('owner marker mismatch refuses without writes', () async {
    final workspace = await create();
    await workspace.close();
    File('${workspace.root.path}/owner').writeAsStringSync('unowned');
    await expectRefused(profileFor[workspace]!);
  });

  test('profile binding mismatches refuse without writes', () async {
    final mismatches = <String, Object>{
      'format': 99,
      'profile_id': 'another-profile',
      'root': Directory.systemTemp.path,
      'fixture_sha256': 'different-fixture',
      'schema_version': kAppSchemaVersion + 1,
      'device_id': 'changed-device',
    };
    for (final entry in mismatches.entries) {
      final workspace = await create();
      await workspace.close();
      final file = File('${workspace.root.path}/profile.json');
      final binding =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      binding[entry.key] = entry.value;
      file.writeAsStringSync(jsonEncode(binding));
      await expectRefused(profileFor[workspace]!);
    }
  });

  test('missing initialized binding refuses without writes', () async {
    final workspace = await create();
    await workspace.close();
    File('${workspace.root.path}/profile.json').deleteSync();
    await expectRefused(profileFor[workspace]!);
  });

  test(
    'missing or mismatched import marker refuses without reimport',
    () async {
      for (final missing in [true, false]) {
        final workspace = await create();
        await workspace.close();
        _mutateDatabase(workspace.databaseFile, (db) {
          if (missing) {
            db.execute(
              "DELETE FROM app_settings WHERE key = 'mock_shop_import_v1'",
            );
          } else {
            db.execute(
              "UPDATE app_settings SET value = 'changed' "
              "WHERE key = 'mock_shop_import_v1'",
            );
          }
        });
        await expectRefused(profileFor[workspace]!);
      }
    },
  );

  test(
    'missing, changed or duplicate device profile refuses without repair',
    () async {
      for (final mutation in ['missing', 'changed', 'duplicate']) {
        final workspace = await create();
        await workspace.close();
        _mutateDatabase(workspace.databaseFile, (db) {
          switch (mutation) {
            case 'missing':
              db.execute('DELETE FROM device_profiles');
            case 'changed':
              db.execute("UPDATE device_profiles SET id = 'changed-device'");
            case 'duplicate':
              db.execute(
                'INSERT INTO device_profiles '
                '(id, display_name, created_at) VALUES (?, ?, ?)',
                ['second-device', 'Synthetic duplicate', 1],
              );
          }
        });
        await expectRefused(profileFor[workspace]!);
      }
    },
  );

  test('missing or invalid PIN state refuses without replacement', () async {
    for (final missing in [true, false]) {
      final workspace = await create();
      await workspace.close();
      _mutateDatabase(workspace.databaseFile, (db) {
        if (missing) {
          db.execute("DELETE FROM app_settings WHERE key = 'editor_pin_hash'");
        } else {
          db.execute(
            "UPDATE app_settings SET value = 'invalid' "
            "WHERE key = 'editor_pin_hash'",
          );
        }
      });
      await expectRefused(profileFor[workspace]!);
    }
  });

  test('company marker refuses before legacy workspace admission', () async {
    final workspace = await create();
    await workspace.close();
    _mutateDatabase(workspace.databaseFile, (db) {
      db.execute(
        'INSERT INTO company_join_events '
        '(request_id, ordinal, kind, evidence_bytes) VALUES (?, ?, ?, ?)',
        ['synthetic-company-marker', 1, 'blocked', 'synthetic'],
      );
    });
    await expectRefused(profileFor[workspace]!);
  });

  test('installation binding refuses even without company rows', () async {
    final workspace = await create();
    await workspace.close();
    _mutateDatabase(workspace.databaseFile, (db) {
      db.execute('INSERT INTO app_settings (key, value) VALUES (?, ?)', [
        'local_installation_binding_v1',
        'synthetic-binding',
      ]);
    });
    await expectRefused(profileFor[workspace]!);
  });

  test('unsupported schema refuses without migration', () async {
    for (final version in [kAppSchemaVersion - 1, kAppSchemaVersion + 1]) {
      final workspace = await create();
      await workspace.close();
      _mutateDatabase(
        workspace.databaseFile,
        (db) => db.execute('PRAGMA user_version = $version'),
      );
      await expectRefused(profileFor[workspace]!);
    }
  });

  test('missing schema table refuses without recreating it', () async {
    final workspace = await create();
    await workspace.close();
    _mutateDatabase(
      workspace.databaseFile,
      (db) => db.execute('DROP TABLE suppliers'),
    );
    await expectRefused(profileFor[workspace]!);
  });

  test(
    'dangling material references refuse before writable admission',
    () async {
      for (final field in ['job_id', 'part_id', 'brand_version_id']) {
        final workspace = await create();
        await workspace.close();
        _mutateDatabase(workspace.databaseFile, (db) {
          db.execute('UPDATE job_lines SET $field = ? WHERE id = ?', [
            'missing-reference',
            fixture.nativeId('material', 'MAT-001-01'),
          ]);
        });
        await expectRefused(profileFor[workspace]!);
      }
    },
  );

  test('corrupt database refuses without rewriting the file', () async {
    final workspace = await create();
    await workspace.close();
    final bytes = workspace.databaseFile.readAsBytesSync();
    bytes[0] = 0;
    workspace.databaseFile.writeAsBytesSync(bytes, flush: true);
    await expectRefused(profileFor[workspace]!);
  });

  test(
    'missing database refuses without creating an empty replacement',
    () async {
      final workspace = await create();
      await workspace.close();
      workspace.databaseFile.deleteSync();
      await expectRefused(profileFor[workspace]!);
      expect(workspace.databaseFile.existsSync(), isFalse);
    },
  );

  test(
    'redirected root, owner, binding, database or sidecars refuse',
    () async {
      for (final target in [
        'root',
        'owner',
        'profile.json',
        'wired_parts.sqlite',
        'wired_parts.sqlite-wal',
        'wired_parts.sqlite-shm',
      ]) {
        final workspace = await create();
        await workspace.close();
        final original = target == 'root'
            ? workspace.root.path
            : '${workspace.root.path}/$target';
        final retained = '$original-retained';
        if (target == 'root') {
          Directory(original).renameSync(retained);
          extraPaths.add(retained);
        } else if (File(original).existsSync()) {
          File(original).renameSync(retained);
        } else {
          File(retained).writeAsStringSync('Synthetic sidecar target');
        }
        Link(original).createSync(retained);
        await expectRefused(profileFor[workspace]!);
      }
    },
  );

  test('failed resume releases its claim for later valid admission', () async {
    final workspace = await create();
    final id = profileFor[workspace]!;
    await workspace.close();
    final owner = File('${workspace.root.path}/owner');
    final original = owner.readAsBytesSync();
    owner.writeAsStringSync('unowned');
    await expectRefused(id);
    owner.writeAsBytesSync(original, flush: true);
    final restored = await resume(id);
    expect(restored.deviceId, workspace.deviceId);
    expect(restored.pin.isUnlocked, isFalse);
    expect(await restored.db.select(restored.db.jobs).get(), hasLength(7));
  });
}
