import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/main.dart' as production;

import 'nearby_lan_workspace.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('LAN_VALIDATION_RUN');
  const roleName = String.fromEnvironment('LAN_VALIDATION_ROLE');
  final role = ValidationRole.values.singleWhere((r) => r.name == roleName);
  final workspace = ValidationWorkspace.open(run: run, role: role);
  PathProviderPlatform.instance = workspace;
  final db = AppDatabase();
  try {
    if (!workspace.initialized) {
      await seedValidationShop(db, workspace);
      workspace.markInitialized();
    }
    final receipt = await validationReceipt(db, workspace);
    final path = p.join(
      workspace.receipts.path,
      '${DateTime.now().toUtc().microsecondsSinceEpoch}.json',
    );
    File(path).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(receipt),
      flush: true,
    );
    debugPrint('Synthetic Nearby validation receipt: $path');
    debugPrint('Synthetic Nearby validation root: ${workspace.root.path}');
  } finally {
    await db.close();
  }
  await production.main();
}

Future<void> seedValidationShop(
  AppDatabase db,
  ValidationWorkspace workspace,
) async {
  final prefix = '${workspace.run}-${workspace.role.name}';
  final device = workspace.deviceId;
  await db.transaction(() async {
    await db.settingsDao.keepLocalDeviceId(
      device,
      displayName: 'LAN ${workspace.role.name} ${workspace.run}',
    );
    await db.settingsDao.setSetting('lan_validation_fixture', prefix);
    await db.jobsDao.insertJob(
      id: '$prefix-job',
      name: 'Synthetic ${workspace.role.name} shop ${workspace.run}',
      deviceId: device,
    );
    await db.taxonomyDao.insertCategory(
      id: '$prefix-category',
      name: 'Synthetic category',
      deviceId: device,
    );
    await db.taxonomyDao.insertStyle(
      id: '$prefix-type',
      categoryId: '$prefix-category',
      name: 'Synthetic type',
      deviceId: device,
    );
    await db.taxonomyDao.insertType(
      id: '$prefix-variant',
      styleId: '$prefix-type',
      name: 'Synthetic variant',
      deviceId: device,
    );
    await db.partsDao.insertGeneralPart(
      id: '$prefix-part',
      name: 'Synthetic ${workspace.role.name} part',
      deviceId: device,
      categoryId: '$prefix-category',
      styleId: '$prefix-type',
      typeId: '$prefix-variant',
    );
    final photoName = '$prefix.png';
    final picture = image.Image(width: 8, height: 8);
    image.fill(
      picture,
      color: workspace.role == ValidationRole.sender
          ? image.ColorRgb8(23, 120, 201)
          : image.ColorRgb8(201, 80, 23),
    );
    workspace.photos.createSync();
    File(p.join(workspace.photos.path, photoName))
        .writeAsBytesSync(image.encodePng(picture), flush: true);
    await db.partsDao.setPhotoPath('$prefix-part', photoName);
  });
}

Future<Map<String, Object?>> validationReceipt(
  AppDatabase db,
  ValidationWorkspace workspace,
) async {
  final jobs = await db.jobsDao.listActiveJobs();
  final parts = await db.partsDao.listParts();
  final profiles = await db.select(db.deviceProfiles).get();
  final categories = await db.taxonomyDao.listCategories();
  final types = await db.taxonomyDao.listStyles();
  final variants = await db.taxonomyDao.listTypes();
  final photos = <Map<String, Object?>>[];
  if (workspace.photos.existsSync()) {
    for (final file in workspace.photos.listSync().whereType<File>()) {
      photos.add({
        'name': p.basename(file.path),
        'sha256': sha256.convert(file.readAsBytesSync()).toString(),
      });
    }
  }
  photos.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  return {
    'format': 1,
    'observedAt': DateTime.now().toUtc().toIso8601String(),
    'run': workspace.run,
    'localRole': workspace.role.name,
    'root': workspace.root.path,
    'expectedLocalDeviceId': workspace.deviceId,
    'deviceIds': profiles.map((e) => e.id).toList(),
    'pinConfigured': await db.settingsDao.getSetting('editor_pin_hash') != null,
    'fixture': await db.settingsDao.getSetting('lan_validation_fixture'),
    'jobs': jobs.map((e) => {'id': e.id, 'name': e.name}).toList(),
    'parts': parts
        .map(
          (e) => {
            'id': e.id,
            'name': e.name,
            'categoryId': e.categoryId,
            'typeId': e.styleId,
            'variantId': e.typeId,
            'photo': e.photoPath,
          },
        )
        .toList(),
    'categoryIds': categories.map((e) => e.id).toList(),
    'typeIds': types.map((e) => e.id).toList(),
    'variantIds': variants.map((e) => e.id).toList(),
    'photos': photos,
  };
}
