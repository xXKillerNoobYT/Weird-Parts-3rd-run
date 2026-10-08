import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import 'nearby_lan_validation.dart';
import 'nearby_lan_workspace.dart';

enum RecoveryAction { exercise, restart }

enum RecoveryStep {
  wrongPassword,
  damagedArchive,
  unsupportedSchema,
  restore,
  restart,
}

class RecoveryScenario {
  RecoveryScenario._(this.run, this.source, this.receiver, this.codec);

  final String run;
  final ValidationWorkspace source;
  final ValidationWorkspace receiver;
  final BackupCodec codec;
  File get archive => File(p.join(receiver.root.path, 'shop.wpbackup'));
  File get manifest =>
      File(p.join(receiver.root.path, 'recovery-scenario.json'));

  static RecoveryAction actionForRun(
    String run, {
    Directory? temporaryDirectory,
  }) {
    _validateRun(run);
    final temp = (temporaryDirectory ?? Directory.systemTemp)
        .resolveSymbolicLinksSync();
    return File(
          p.join(
            temp,
            'wired-parts-lan-recovery-$run-receiver',
            'recovery-scenario.json',
          ),
        ).existsSync()
        ? RecoveryAction.restart
        : RecoveryAction.exercise;
  }

  static RecoveryScenario open({
    required String run,
    required RecoveryAction action,
    Directory? temporaryDirectory,
    BackupCodec? codec,
  }) {
    _validateRun(run);
    final temp = (temporaryDirectory ?? Directory.systemTemp)
        .resolveSymbolicLinksSync();
    final fixtureRun = 'recovery-$run';
    if (action == RecoveryAction.restart) {
      for (final role in ValidationRole.values) {
        final root = p.join(temp, 'wired-parts-lan-$fixtureRun-${role.name}');
        if (FileSystemEntity.typeSync(root, followLinks: false) !=
                FileSystemEntityType.directory ||
            !File(p.join(root, 'validation-owner.json')).existsSync()) {
          throw StateError('Restart requires the existing recovery workspaces');
        }
      }
      final saved = File(
        p.join(
          temp,
          'wired-parts-lan-$fixtureRun-receiver',
          'recovery-scenario.json',
        ),
      );
      if (!saved.existsSync()) {
        throw StateError('Restart requires recovery evidence');
      }
    }
    final source = ValidationWorkspace.open(
      run: fixtureRun,
      role: ValidationRole.sender,
      temporaryDirectory: temporaryDirectory,
    );
    try {
      final receiver = ValidationWorkspace.open(
        run: fixtureRun,
        role: ValidationRole.receiver,
        temporaryDirectory: temporaryDirectory,
      );
      final scenario = RecoveryScenario._(
        run,
        source,
        receiver,
        codec ?? BackupCodec(),
      );
      if (action == RecoveryAction.exercise &&
          (source.initialized || receiver.initialized)) {
        receiver.close();
        throw StateError('Recovery exercise requires a fresh run identifier');
      }
      if (action == RecoveryAction.restart) {
        try {
          scenario.readManifest();
        } catch (_) {
          receiver.close();
          rethrow;
        }
      }
      return scenario;
    } catch (_) {
      source.close();
      rethrow;
    }
  }

  AppDatabase openDatabase(ValidationWorkspace workspace) =>
      AppDatabase.forTesting(
        NativeDatabase(File(p.join(workspace.support.path, kSqliteFileName))),
      );

  Future<void> seed() async {
    for (final workspace in [source, receiver]) {
      final db = openDatabase(workspace);
      try {
        await seedValidationShop(db, workspace);
        await PinService(db.settingsDao).setPin('1234');
        await checkpointWalForExport(db);
        workspace.markInitialized();
      } finally {
        await db.close();
      }
    }
  }

  Future<Map<String, Object?>> receipt(
    AppDatabase db,
    ValidationWorkspace workspace,
  ) async {
    final content = await validationReceipt(db, workspace);
    final settings = await db.select(db.appSettings).get();
    final profiles = await db
        .customSelect('SELECT * FROM device_profiles ORDER BY id')
        .get();
    await checkpointWalForExport(db);
    final sqlite = File(p.join(workspace.support.path, kSqliteFileName))
        .readAsBytesSync();
    return {
      'sqliteSchemaVersion': backupSqliteSchemaVersion(sqlite),
      'sqliteSha256': sha256.convert(sqlite).toString(),
      'records': content['content'],
      'settings': {
        for (final row in settings)
          if (row.key != 'editor_pin_hash') row.key: row.value,
      },
      'pinConfigured': content['pinConfigured'],
      'localDeviceIds': content['deviceIds'],
      'deviceProfiles': profiles.map((row) => row.data).toList(),
      'photos': content['photos'],
    };
  }

  Future<Map<String, Object?>> export() async {
    final db = openDatabase(source);
    try {
      final before = await receipt(db, source);
      final store = BackupStore(
        supportDir: source.support,
        photosDir: source.photos,
      );
      final payload = await store.collect(
        sourceDeviceId: source.deviceId,
        createdAt: DateTime.utc(2026, 10, 7),
        sqliteBytes: await (await store.sqliteFile()).readAsBytes(),
      );
      final bytes = await codec.encrypt(payload, _password);
      await writeBytesAtomically(
        archive,
        bytes,
        stagingDir: Directory(p.join(receiver.root.path, 'archive-staging')),
      );
      return before;
    } finally {
      await db.close();
    }
  }

  Map<String, dynamic> readManifest() {
    final value = jsonDecode(manifest.readAsStringSync());
    if (value is! Map<String, dynamic> ||
        value['format'] != 1 ||
        value['run'] != run ||
        value['state'] != 'restored') {
      throw StateError(
        'Recovery manifest does not describe a completed restore',
      );
    }
    if (!archive.existsSync() ||
        value['archiveSha256'] !=
            sha256.convert(archive.readAsBytesSync()).toString()) {
      throw StateError('Recovery archive does not match the manifest');
    }
    if (value['source'] is! Map ||
        value['restored'] is! Map ||
        value['receiverDeviceProfiles'] is! List ||
        (value['receiverDeviceProfiles'] as List).length != 1) {
      throw StateError('Recovery manifest is missing shop receipts');
    }
    return value;
  }

  Future<void> exercise({
    required AppScope Function() scope,
    required Future<void> Function() settle,
    required Map<String, Object?> sourceReceipt,
  }) async {
    final bytes = archive.readAsBytesSync();
    final damaged = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
    final payload = await codec.decrypt(bytes, _password);
    final futureSqlite = Uint8List.fromList(payload.sqliteBytes);
    ByteData.sublistView(futureSqlite)
        .setUint32(60, kAppSchemaVersion + 1, Endian.big);
    final unsupported = await codec.encrypt(
      BackupPayload(
        createdAt: payload.createdAt,
        sourceDeviceId: payload.sourceDeviceId,
        sqliteBytes: futureSqlite,
        photos: payload.photos,
      ),
      _password,
    );
    final cases = [
      (
        RecoveryStep.wrongPassword,
        bytes,
        'incorrect synthetic password',
        'Wrong password or damaged backup',
      ),
      (
        RecoveryStep.damagedArchive,
        damaged,
        _password,
        'Wrong password or damaged backup',
      ),
      (
        RecoveryStep.unsupportedSchema,
        unsupported,
        _password,
        'Unsupported backup database schema',
      ),
      (RecoveryStep.restore, bytes, _password, null),
    ];
    final receiverBaseline = await receipt(scope().db, receiver);
    Map<String, Object?>? restored;
    for (final (step, input, password, expectedError) in cases) {
      final before = await receipt(scope().db, receiver);
      final pinBefore = await scope().db.settingsDao.getSetting(
        'editor_pin_hash',
      );
      String? error;
      try {
        await scope().restoreFromBackup(input, password);
      } catch (e) {
        error = '$e';
      }
      await settle();
      final after = await receipt(scope().db, receiver);
      final pinAfter = await scope().db.settingsDao.getSetting(
        'editor_pin_hash',
      );
      try {
        if (expectedError != null) {
          require(
            error?.contains(expectedError) == true,
            '${step.name} must reject the archive',
          );
          compareShop(before, after, sameSqlite: true);
          require(
            pinBefore == pinAfter,
            '${step.name} changed the synthetic PIN',
          );
        } else {
          require(error == null, 'Restore failed');
          compareRestored(
            sourceReceipt,
            after,
            receiverProfiles: receiverBaseline['deviceProfiles'] as List,
          );
          restored = after;
        }
      } catch (e) {
        writeReceipt(step, before, after, error: error, validationError: '$e');
        rethrow;
      }
      writeReceipt(step, before, after, error: error);
    }
    manifest.writeAsStringSync(
      jsonEncode({
        'format': 1,
        'run': run,
        'state': 'restored',
        'backupHeaderVersion': kBackupHeaderVersion,
        'archiveSha256': sha256.convert(bytes).toString(),
        'source': sourceReceipt,
        'receiverDeviceProfiles': receiverBaseline['deviceProfiles'],
        'restored': restored,
      }),
      flush: true,
    );
  }

  Future<void> restart(AppDatabase db) async {
    final saved = readManifest();
    final after = await receipt(db, receiver);
    final before = Map<String, Object?>.from(saved['restored'] as Map);
    try {
      compareRestored(
        Map<String, Object?>.from(saved['source'] as Map),
        after,
        receiverProfiles: saved['receiverDeviceProfiles'] as List,
      );
      compareShop(before, after);
    } catch (e) {
      writeReceipt(RecoveryStep.restart, before, after, validationError: '$e');
      rethrow;
    }
    writeReceipt(RecoveryStep.restart, before, after);
  }

  void compareRestored(
    Map<String, Object?> expected,
    Map<String, Object?> actual, {
    required List<Object?> receiverProfiles,
  }) {
    require(
      _same(expected['records'], actual['records']),
      'Restored domain records or relationships differ',
    );
    require(
      _same(expected['photos'], actual['photos']),
      'Restored photo bytes differ',
    );
    require(
      actual['sqliteSchemaVersion'] == kAppSchemaVersion,
      'Restored schema is not current',
    );
    require(
      _same(actual['localDeviceIds'], [receiver.deviceId]),
      'Receiver identity changed',
    );
    require(
      _same(actual['deviceProfiles'], receiverProfiles),
      'Receiver device profile changed',
    );
    require(
      actual['pinConfigured'] == true,
      'Restored synthetic PIN is missing',
    );
    final settings = actual['settings'] as Map;
    require(
      settings['lan_validation_fixture'] == '${source.run}-${source.role.name}',
      'Receiver sentinel was not replaced',
    );
    require(
      settings[kLastBackupSourceKey] == source.deviceId,
      'Restore source metadata is missing',
    );
    require(
      settings[kLastBackupAtKey] == DateTime.utc(2026, 10, 7).toIso8601String(),
      'Restore time metadata is missing',
    );
  }

  static void compareShop(
    Map<String, Object?> expected,
    Map<String, Object?> actual, {
    bool sameSqlite = false,
  }) {
    for (final field in [
      'sqliteSchemaVersion',
      'records',
      'settings',
      'pinConfigured',
      'localDeviceIds',
      'deviceProfiles',
      'photos',
      if (sameSqlite) 'sqliteSha256',
    ]) {
      require(_same(expected[field], actual[field]), 'Recovery changed $field');
    }
  }

  void writeReceipt(
    RecoveryStep step,
    Map<String, Object?> before,
    Map<String, Object?> after, {
    String? error,
    String? validationError,
  }) {
    File(
      p.join(
        receiver.receipts.path,
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-${step.name}.json',
      ),
    ).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'format': 1,
        'run': run,
        'platform': Platform.operatingSystem,
        'executable': Platform.resolvedExecutable,
        'step': step.name,
        'expectedOutcome':
            step == RecoveryStep.restore || step == RecoveryStep.restart
            ? 'restored'
            : 'rejected',
        'actualOutcome': error == null ? 'restored' : 'rejected',
        'error': error,
        'validation': validationError == null ? 'pass' : 'fail',
        'validationError': validationError,
        'backupHeaderVersion': kBackupHeaderVersion,
        'archiveSha256': sha256.convert(archive.readAsBytesSync()).toString(),
        'before': before,
        'after': after,
      }),
      flush: true,
    );
  }

  void close() {
    source.close();
    receiver.close();
  }
}

const _password = 'synthetic recovery archive only';

void _validateRun(String run) {
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,38}$').hasMatch(run)) {
    throw ArgumentError(
      'Recovery run must contain 1-39 lowercase letters, digits or hyphens',
    );
  }
}

bool _same(Object? left, Object? right) =>
    const DeepCollectionEquality().equals(left, right);

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
