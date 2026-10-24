import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

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

    final app = await validationApplication(workspace);
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
