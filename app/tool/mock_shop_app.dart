import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import 'mock_shop/adapter.dart';
import 'mock_shop/fixture.dart';

enum MockProfileMode { temporary, create, resume }

({MockProfileMode mode, String? profileId}) mockProfileSelection(
  Map<String, String> environment,
) {
  final mode = environment['MOCK_SHOP_PROFILE_MODE'];
  final id = environment['MOCK_SHOP_PROFILE_ID'];
  if (mode == null && id == null) {
    return (mode: MockProfileMode.temporary, profileId: null);
  }
  if (id == null || (mode != 'create' && mode != 'resume')) {
    throw StateError('Mock profile requires an explicit create or resume mode');
  }
  MockLocalWorkspace.profileRoot(id);
  return (
    mode: mode == 'create' ? MockProfileMode.create : MockProfileMode.resume,
    profileId: id,
  );
}

final class _MockPaths extends PathProviderPlatform {
  _MockPaths(this.root);
  final Directory root;
  Future<String> _directory(String name) async {
    final directory = Directory('${root.path}/$name');
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<String> getApplicationSupportPath() async => root.path;
  @override
  Future<String> getApplicationDocumentsPath() => _directory('documents');
  @override
  Future<String> getTemporaryPath() => _directory('temporary');
  @override
  Future<String> getApplicationCachePath() => _directory('cache');
  @override
  Future<String> getLibraryPath() => _directory('library');
  @override
  Future<String> getDownloadsPath() => _directory('downloads');
}

Future<void> main() async {
  if (!const bool.fromEnvironment('MOCK_SHOP_TEST_APP')) {
    throw StateError('Mock shop entrypoint requires explicit test opt-in');
  }
  const input = String.fromEnvironment('MOCK_SHOP_FIXTURE_DIRECTORY');
  if (input.isEmpty || !p.isAbsolute(input)) {
    throw StateError('Mock shop input requires an absolute fixture directory');
  }
  final selection = mockProfileSelection(Platform.environment);
  final profileId = selection.profileId;
  final fixture = MockShopFixture.read(Directory(input));
  WidgetsFlutterBinding.ensureInitialized();
  final workspace = switch (selection.mode) {
    MockProfileMode.create => await MockLocalWorkspace.createProfile(
      profileId: profileId!,
    ),
    MockProfileMode.resume => await MockLocalWorkspace.resumeProfile(
      profileId: profileId!,
      fixture: fixture,
    ),
    MockProfileMode.temporary => await MockLocalWorkspace.create(),
  };
  PathProviderPlatform.instance = _MockPaths(workspace.root);
  final receipt = selection.mode == MockProfileMode.resume
      ? null
      : await workspace.import(fixture);
  final documents = Directory('${workspace.root.path}/documents');
  await documents.create();
  stdout.writeln(
    jsonEncode({
      'test_profile': 'mock-local-shop',
      'operation': selection.mode.name,
      'profile_id': profileId,
      'device_id': workspace.deviceId,
      'fixture_sha256': fixture.sha256Value,
      'database': workspace.databaseFile.path,
      'receipt': receipt?.toJson(),
      'pin_locked': !workspace.pin.isUnlocked,
      'native_acceptance': 'NOT_RUN',
    }),
  );
  runApp(
    WiredPartsApp(
      db: workspace.db,
      pin: workspace.pin,
      deviceId: workspace.deviceId,
      reopenDatabase: () =>
          AppDatabase.forTesting(NativeDatabase(workspace.databaseFile)),
      reset: LocalDataReset(
        supportDir: workspace.root,
        documentsDir: documents,
        photosDir: Directory('${workspace.root.path}/part_photos'),
      ),
    ),
  );
}
