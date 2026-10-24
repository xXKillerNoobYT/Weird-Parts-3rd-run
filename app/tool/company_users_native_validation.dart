import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

import 'nearby_lan_validation.dart'
    show validationApplication, validationInstallationNamespace;
import 'nearby_lan_workspace.dart';

const _enabled = bool.fromEnvironment('NATIVE_COMPANY_USER_VALIDATION');
const _run = String.fromEnvironment('LAN_VALIDATION_RUN');
const _roleName = String.fromEnvironment('LAN_VALIDATION_ROLE');
const _revision = String.fromEnvironment('COMPANY_USER_SOURCE_REVISION');
const _tree = String.fromEnvironment('COMPANY_USER_SOURCE_TREE');
const _syntheticPin = '1234';
const _syntheticRecoveryPhrase = 'Synthetic Goal 2 recovery authority 123';

ValidationWorkspace? _heldWorkspace;
AppDatabase? _openedDatabase;

Future<void> main() async {
  late final ValidationRole role;
  try {
    role = _validateStartupArguments();
  } catch (_) {
    stderr.writeln('Company user validation startup failed.');
    exit(1);
  }
  WidgetsFlutterBinding.ensureInitialized();

  late final WiredPartsApp readyApp;
  try {
    final namespace = validationInstallationNamespace(
      run: _run,
      roleName: _roleName,
    );
    if (!namespace.startsWith('synthetic.lan.$_roleName.')) {
      throw StateError('invalid synthetic installation namespace');
    }
    final workspace = ValidationWorkspace.open(run: _run, role: role);
    _heldWorkspace = workspace;
    PathProviderPlatform.instance = workspace;

    final transport = CompanyUserTransportReceipts(
      directory: workspace.receipts,
      run: _run,
      role: _roleName,
      sourceRevision: _revision,
      sourceTree: _tree,
      processId: pid,
    );
    final app = await validationApplication(
      workspace,
      createCompanyJoinController: transport.createController,
    );
    _openedDatabase = app.db;
    final installation = app.installation;
    if (installation == null || installation.identity == null) {
      throw StateError('installation setup unavailable');
    }

    CompanyIdentity? createdCompany;
    if (role == ValidationRole.sender && !workspace.initialized) {
      final enrollment = CompanyEnrollment(
        installation: installation,
        db: app.db,
      );
      createdCompany = await enrollment.create(
        companyName: 'Synthetic Goal 2 company users $_run',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: _syntheticPin,
        recoveryPassphrase: _syntheticRecoveryPhrase,
        recoveryFile: File(p.join(workspace.documents.path, 'authority.wpca')),
        photosDirectory: workspace.photos,
      );
    }

    if (!workspace.initialized) workspace.markInitialized();
    final enrollment = CompanyEnrollment(
      installation: installation,
      db: app.db,
    );
    final choices = await enrollment.listCompanyUsers();
    final receiptCompany = createdCompany ?? await enrollment.readIdentity();
    final trust = await installation.readCompanyTrust(app.db);
    final protectedUser = trust == null
        ? {'present': false, 'available': false}
        : await _readProtectedUserProjection(enrollment, installation);
    final identity = installation.identity!;
    final receipt = <String, Object?>{
      'kind': 'company-user-startup@1',
      'passed': false,
      'scope': 'startup measurement and synthetic preparation only',
      'pid': pid,
      'os': Platform.operatingSystem,
      'run': _run,
      'role': _roleName,
      'sourceRevision': _revision,
      'sourceTree': _tree,
      'installation': {
        'id': identity.id.value,
        'generation': identity.generation.value,
        'receivingStoreGeneration':
            installation.receivingStoreGeneration?.value,
        'publicKeySha256': sha256.convert(identity.publicKey).toString(),
      },
      'companyIdentity': receiptCompany == null
          ? null
          : {
              'companyId': receiptCompany.companyId,
              'shopId': receiptCompany.shopId,
              'userId': receiptCompany.userId,
              'deviceId': receiptCompany.deviceId,
              'name': receiptCompany.name,
              'packageId': receiptCompany.packageId,
            },
      'companyId': trust?.companyId.value,
      'userChoices': [
        for (final choice in choices)
          {
            'userId': choice.userId,
            'name': choice.name,
            'available': choice.available,
          },
      ],
      'secondaryProtectedRecord': protectedUser,
      'appOwnsOrdinaryDatabaseExit': true,
      'normalQuitEvidence': 'external host process observation required',
      'transportMeasurements': {
        'passed': false,
        'localOnly': true,
        'file': p.basename(transport.filePath),
        'maxRecords': CompanyUserTransportReceipts.maxRecords,
        'maxRecordBytes': CompanyUserTransportReceipts.maxRecordBytes,
        'maxTotalBytes': CompanyUserTransportReceipts.maxTotalBytes,
      },
    };
    final receiptId = '$pid-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final file = File(
      p.join(
        _heldWorkspace!.receipts.path,
        'company-user-startup-$receiptId.json',
      ),
    );
    file.createSync(exclusive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(receipt),
      flush: true,
    );
    debugPrint('Company user validation startup receipt written.');
    readyApp = app;
  } catch (_) {
    try {
      await _openedDatabase?.close();
    } catch (_) {}
    _openedDatabase = null;
    try {
      _heldWorkspace?.close();
    } catch (_) {}
    _heldWorkspace = null;
    stderr.writeln('Company user validation startup failed.');
    exit(1);
  }
  runApp(readyApp);
}

/// A bounded local measurement sink, installed only by the guarded native target.
final class CompanyUserTransportReceipts {
  CompanyUserTransportReceipts({
    required Directory directory,
    required String run,
    required String role,
    required String sourceRevision,
    required String sourceTree,
    required int processId,
  }) : _metadata = Map.unmodifiable({
         'kind': 'company-user-transport@1',
         'passed': false,
         'localOnly': true,
         'os': Platform.operatingSystem,
         'run': run,
         'role': role,
         'pid': processId,
         'sourceRevision': sourceRevision,
         'sourceTree': sourceTree,
       }),
       _file = File(
         p.join(
           directory.path,
           'company-user-transport-$processId-${const Uuid().v4()}.jsonl',
         ),
       ) {
    if (!RegExp(r'^g2-users-\d{8}-[a-z0-9][a-z0-9-]{0,29}$').hasMatch(run) ||
        !{'sender', 'receiver'}.contains(role) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(sourceRevision) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(sourceTree) ||
        processId <= 0 ||
        processId > 2147483647) {
      throw ArgumentError('Invalid local transport measurement metadata');
    }
  }
  static const maxRecords = 128;
  static const maxRecordBytes = 1024;
  static const maxTotalBytes = maxRecords * maxRecordBytes;
  final Map<String, Object?> _metadata;
  final File _file;
  final List<List<int>> _records = [];
  int _bytes = 0;
  int _written = 0;
  bool _disabled = false;
  bool _closed = false;
  RandomAccessFile? _handle;
  Future<void>? _flushing;
  String get filePath => _file.path;
  int get capturedCount => _records.length;

  NearbyController createController(String alias) => NearbyController(
    deviceId: alias,
    deviceName: 'Nearby ${alias.substring(0, 6)}',
    discovery: LanNearbyDiscovery(),
    companyJoin: true,
    onTransportObservation: record,
  );

  void record(NearbyTransportObservation event) {
    if (_disabled || _closed || _records.length >= maxRecords) return;
    try {
      final bytes = utf8.encode(
        '${jsonEncode({..._metadata, ...event.toJson()})}\n',
      );
      if (bytes.length > maxRecordBytes ||
          _bytes + bytes.length > maxTotalBytes) {
        return;
      }
      _records.add(bytes);
      _bytes += bytes.length;
      _scheduleFlush();
    } catch (_) {}
  }

  void _scheduleFlush() {
    if (_disabled || _flushing != null || _written == _records.length) return;
    _flushing =
        Future<void>(() async {
          try {
            if (_handle == null) {
              await _file.create(exclusive: true);
              if (await FileSystemEntity.type(_file.path, followLinks: false) !=
                  FileSystemEntityType.file) {
                throw const FileSystemException(
                  'Transport measurement file unavailable',
                );
              }
              _handle = await _file.open(mode: FileMode.writeOnlyAppend);
            }
            final end = _records.length;
            final bytes = [
              for (var index = _written; index < end; index++)
                ..._records[index],
            ];
            await _handle!.writeFrom(bytes);
            await _handle!.flush();
            _written = end;
          } catch (_) {
            _disabled = true;
            try {
              await _handle?.close();
            } catch (_) {}
            _handle = null;
          }
        }).whenComplete(() {
          _flushing = null;
          _scheduleFlush();
        });
  }

  Future<void> drain() async {
    while (_flushing != null) {
      await _flushing;
    }
  }

  Future<void> close() async {
    _closed = true;
    await drain();
    try {
      await _handle?.close();
    } catch (_) {}
    _handle = null;
  }
}

ValidationRole _validateStartupArguments() {
  final runMatch = RegExp(r'^g2-users-(\d{8})-([a-z0-9][a-z0-9-]{0,29})$')
      .firstMatch(_run);
  final digits = runMatch?.group(1);
  final date = digits == null
      ? null
      : DateTime.tryParse(
          '${digits.substring(0, 4)}-${digits.substring(4, 6)}-${digits.substring(6, 8)}T00:00:00Z',
        );
  if (!_enabled ||
      date == null ||
      date.toUtc().toIso8601String().substring(0, 10).replaceAll('-', '') !=
          runMatch![1] ||
      _run.length > 48 ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(_revision) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(_tree) ||
      !{'sender', 'receiver'}.contains(_roleName)) {
    throw StateError('company-user-validation-arguments-refused');
  }
  if ((_roleName == 'sender' && !Platform.isWindows) ||
      (_roleName == 'receiver' && !Platform.isMacOS)) {
    throw StateError('company-user-validation-host-refused');
  }
  return _roleName == 'sender'
      ? ValidationRole.sender
      : ValidationRole.receiver;
}

Future<Map<String, Object?>> _readProtectedUserProjection(
  CompanyEnrollment enrollment,
  InstallationSecurity installation,
) async {
  final namespace = validationInstallationNamespace(
    run: _run,
    roleName: _roleName,
  );
  if (!namespace.startsWith('synthetic.lan.$_roleName.')) {
    return {'present': false, 'available': false};
  }
  final slot = companyUserNamespace(namespace);
  ProtectedInstallationState? saved;
  try {
    saved = await installation.store.readState(slot);
  } catch (_) {
    return {'present': true, 'available': false};
  }
  if (saved == null) {
    return {'present': false, 'available': false};
  }
  try {
    final lifecycle = await enrollment.userLifecycleStatus();
    final choices = await enrollment.listCompanyUsers();
    final additional = choices.skip(1).toList();
    if (lifecycle == null ||
        additional.length != 1 ||
        additional.single.userId != lifecycle.userId ||
        additional.single.disabled != lifecycle.disabled) {
      throw const FormatException('unavailable');
    }
    final latest = await installation.store.readState(slot);
    if (latest == null ||
        latest.revision != saved.revision ||
        !_sameBytes(latest.bytes, saved.bytes)) {
      throw const FormatException('unavailable');
    }
    final choice = additional.single;
    return {
      'present': true,
      'byteLength': saved.bytes.length,
      'available': choice.available,
      'disabled': lifecycle.disabled,
      'attemptsRemaining': lifecycle.attemptsRemaining,
      'disableReceiptSaved': lifecycle.confirmed,
      'certificatePublic': {
        'userId': choice.userId,
        'credentialVersion': 1,
        'permissionVersion': 1,
      },
    };
  } catch (_) {
    return {
      'present': true,
      'byteLength': saved.bytes.length,
      'available': false,
    };
  }
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
