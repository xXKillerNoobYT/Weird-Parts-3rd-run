import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

import '../../tool/company_users_native_validation.dart';
import '../../tool/nearby_lan_validation.dart';
import '../../tool/nearby_lan_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wired_parts/installation_security');

  ValidationWorkspace owned() {
    final temporary = Directory.systemTemp.createTempSync(
      'startup-receipt-test-',
    );
    final workspace = ValidationWorkspace.open(
      run: 'g2-users-20261026-startup-a',
      role: ValidationRole.receiver,
      temporaryDirectory: temporary,
    );
    workspace.markInitialized();
    addTearDown(() {
      workspace.close();
      expect(
        temporary.resolveSymbolicLinksSync(),
        startsWith(Directory.systemTemp.resolveSymbolicLinksSync()),
      );
      temporary.deleteSync(recursive: true);
    });
    return workspace;
  }

  CompanyUserStartupFailureReporter reporter({
    bool enabled = true,
    String run = 'g2-users-20261026-startup-a',
    String? revision,
  }) => CompanyUserStartupFailureReporter(
    enabled: enabled,
    run: run,
    role: 'receiver',
    sourceRevision: revision ?? 'a' * 40,
    sourceTree: 'b' * 40,
    processId: 123,
    observation: DateTime.utc(2026, 10, 26),
  );

  const unavailable = CompanyUserStartupFailure(
    CompanyUserStartupStage.protectedStore,
    InstallationReadiness.unavailable,
  );

  testWidgets(
    'unavailable native storage refuses before writing device identity',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousPaths = PathProviderPlatform.instance;
      final temporary = Directory.systemTemp.createTempSync(
        'startup-failure-test-',
      );
      final workspace = ValidationWorkspace.open(
        run: 'g2-users-20261026-startup-a',
        role: ValidationRole.receiver,
        temporaryDirectory: temporary,
      );
      final file = File(p.join(workspace.support.path, 'wired_parts.sqlite'));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var reads = 0;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      messenger.setMockMethodCallHandler(channel, (call) async {
        reads++;
        expect(call.method, 'readState');
        throw PlatformException(
          code: 'installation_unavailable',
          message: 'unexportable-test-value',
          details: {'osStatus': -25308, 'private': 'unexportable-test-value'},
        );
      });
      try {
        await tester.runAsync(() async {
          final seed = AppDatabase.forTesting(NativeDatabase(file));
          expect(
            await seed.customSelect('SELECT id FROM device_profiles').get(),
            isEmpty,
          );
          await seed.close();
        });
        workspace.markInitialized();
        final before = sha256.convert(file.readAsBytesSync()).toString();
        Object? failure;
        WiredPartsApp? returned;
        ValidationApplicationStage? stage;
        InstallationReadiness? readiness;
        await tester.runAsync(() async {
          try {
            returned = await validationApplication(
              workspace,
              onStartupStage: (current, observed) {
                stage = current;
                readiness = observed;
              },
            );
          } catch (error) {
            failure = error;
          } finally {
            await returned?.db.close();
          }
        });
        expect(reads, 1);
        expect(
          failure,
          isNotNull,
          reason: 'An unavailable protected store must refuse before ensureDeviceId',
        );
        expect(stage, ValidationApplicationStage.protectedStore);
        expect(readiness, InstallationReadiness.unavailable);
        expect(sha256.convert(file.readAsBytesSync()).toString(), before);
        final moved = file.renameSync('${file.path}.closed');
        moved.renameSync(file.path);
        expect(
          await finishCompanyUserStartupFailure(
            failure: CompanyUserStartupFailure(
              CompanyUserStartupStage.protectedStore,
              readiness,
            ),
            workspace: workspace,
            reporter: reporter(),
          ),
          isTrue,
        );
        final receiptFile = workspace.receipts
            .listSync()
            .whereType<File>()
            .single;
        final text = receiptFile.readAsStringSync();
        final receipt = jsonDecode(text) as Map;
        expect(receipt.keys.toSet(), {
          'kind',
          'passed',
          'run',
          'role',
          'sourceRevision',
          'sourceTree',
          'pid',
          'observedUtc',
          'stage',
          'category',
          'installationReadiness',
        });
        expect(receipt['kind'], 'company-user-startup-failure@1');
        expect(receipt['passed'], isFalse);
        expect(receipt['stage'], 'protectedStore');
        expect(receipt['category'], 'installationUnavailable');
        expect(receipt['installationReadiness'], 'unavailable');
        expect(receiptFile.lengthSync(), lessThanOrEqualTo(1024));
        for (final forbidden in [
          'unexportable-test-value',
          'osStatus',
          '-25308',
          file.path,
        ]) {
          expect(text, isNot(contains(forbidden)));
        }
        final reopened = ValidationWorkspace.open(
          run: workspace.run,
          role: workspace.role,
          temporaryDirectory: temporary,
        );
        reopened.close();
        expect(sha256.convert(file.readAsBytesSync()).toString(), before);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = previousPlatform;
        PathProviderPlatform.instance = previousPaths;
        workspace.close();
        expect(
          temporary.resolveSymbolicLinksSync(),
          startsWith(Directory.systemTemp.resolveSymbolicLinksSync()),
        );
        temporary.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'ready native startup preserves routing and creates no failure receipt',
    (tester) async {
      final workspace = owned();
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousPaths = PathProviderPlatform.instance;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final states = <String, Map<String, Object?>>{};
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        final namespace = args['namespace'] as String;
        if (call.method == 'readState') return states[namespace];
        if (call.method == 'compareAndSwapState') {
          states[namespace] = {
            'revision': args['nextRevision'],
            'bytes': args['bytes'],
          };
          return {'revision': args['nextRevision']};
        }
        throw UnsupportedError(call.method);
      });
      WiredPartsApp? app;
      ValidationApplicationStage? last;
      InstallationReadiness? readiness;
      try {
        app = await tester.runAsync(
          () => validationApplication(
            workspace,
            onStartupStage: (stage, observed) {
              last = stage;
              readiness = observed;
            },
          ),
        );
        expect(app!.installation!.readiness, InstallationReadiness.ready);
        expect(last, ValidationApplicationStage.appConstruction);
        expect(readiness, InstallationReadiness.ready);
        expect(workspace.receipts.listSync(), isEmpty);
        expect(
          await tester.runAsync(
            () async =>
                (await app!.db
                        .customSelect('SELECT id FROM device_profiles')
                        .get())
                    .length,
          ),
          1,
        );
      } finally {
        await tester.runAsync(() async {
          await app?.db.close();
        });
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = previousPlatform;
        PathProviderPlatform.instance = previousPaths;
      }
    },
  );

  test('closed claim and invalid metadata cannot publish', () {
    final workspace = owned();
    for (final invalid in [
      reporter(enabled: false),
      reporter(run: 'invalid'),
      reporter(revision: 'private-value'),
    ]) {
      expect(() => invalid.publish(workspace, unavailable), throwsStateError);
    }
    expect(workspace.receipts.listSync(), isEmpty);
    workspace.close();
    expect(() => reporter().publish(workspace, unavailable), throwsStateError);
    expect(workspace.receipts.listSync(), isEmpty);
  });

  for (final directory in [false, true]) {
    test('occupied ${directory ? 'directory' : 'file'} target is preserved', () {
      final workspace = owned();
      final target = p.join(
        workspace.receipts.path,
        'company-user-startup-failure-123-${DateTime.utc(2026, 10, 26).microsecondsSinceEpoch}.json',
      );
      if (directory) {
        Directory(target).createSync();
      } else {
        File(target).writeAsStringSync('preserve-public-sentinel');
      }
      expect(
        () => reporter().publish(workspace, unavailable),
        throwsStateError,
      );
      if (directory) {
        expect(Directory(target).existsSync(), isTrue);
      } else {
        expect(File(target).readAsStringSync(), 'preserve-public-sentinel');
      }
    });
  }

  test('redirected receipts refuse without writing into target', () {
    final workspace = owned();
    final target = Directory(
      p.join(workspace.root.parent.path, 'redirect-target'),
    )..createSync();
    workspace.receipts.renameSync('${workspace.receipts.path}-original');
    final link = Link(workspace.receipts.path)..createSync(target.path);
    try {
      expect(
        () => reporter().publish(workspace, unavailable),
        throwsStateError,
      );
      expect(target.listSync(), isEmpty);
    } finally {
      link.deleteSync();
    }
  });

  test(
    'non-directory receipts and changed owner marker refuse publication',
    () {
      final workspace = owned();
      final marker = File(p.join(workspace.root.path, 'validation-owner.json'));
      final original = marker.readAsStringSync();
      marker.writeAsStringSync(
        jsonEncode({...jsonDecode(original) as Map, 'run': 'different'}),
      );
      expect(
        () => reporter().publish(workspace, unavailable),
        throwsStateError,
      );
      expect(workspace.receipts.listSync(), isEmpty);
      marker.writeAsStringSync(original);
      workspace.receipts.renameSync('${workspace.receipts.path}-original');
      final sentinel = File(workspace.receipts.path)
        ..writeAsStringSync('preserve');
      expect(
        () => reporter().publish(workspace, unavailable),
        throwsStateError,
      );
      expect(sentinel.readAsStringSync(), 'preserve');
    },
  );

  test(
    'publication and close errors preserve failure and release claim',
    () async {
      final workspace = owned();
      final closed = <String>[];
      expect(
        await finishCompanyUserStartupFailure(
          failure: unavailable,
          workspace: workspace,
          reporter: reporter(enabled: false),
          closeTransport: () async {
            closed.add('transport');
            throw StateError('unexportable');
          },
          closeDatabase: () async {
            closed.add('database');
            throw StateError('unexportable');
          },
        ),
        isFalse,
      );
      expect(closed, ['transport', 'database']);
      expect(
        unavailable.category,
        CompanyUserStartupCategory.installationUnavailable,
      );
      expect(workspace.receipts.listSync(), isEmpty);
      expect(() => workspace.requireOwnedReceipts(), throwsStateError);
      final reopened = ValidationWorkspace.open(
        run: workspace.run,
        role: workspace.role,
        temporaryDirectory: workspace.root.parent,
      );
      reopened.close();
    },
  );

  test('fixed categories and one bounded attempt never expand error text', () {
    final workspace = owned();
    const expected = {
      InstallationReadiness.unsupported:
          CompanyUserStartupCategory.installationUnsupported,
      InstallationReadiness.unavailable:
          CompanyUserStartupCategory.installationUnavailable,
      InstallationReadiness.needsRecovery:
          CompanyUserStartupCategory.installationRecoveryRequired,
      InstallationReadiness.ready:
          CompanyUserStartupCategory.installationIdentityMissing,
    };
    for (final entry in expected.entries) {
      expect(
        CompanyUserStartupFailure(
          CompanyUserStartupStage.protectedStore,
          entry.key,
        ).category,
        entry.value,
      );
    }
    expect(
      const CompanyUserStartupFailure(
        CompanyUserStartupStage.receiptWrite,
        InstallationReadiness.ready,
      ).category,
      CompanyUserStartupCategory.stageFailed,
    );
    final once = reporter();
    final file = once.publish(workspace, unavailable);
    final before = file.readAsBytesSync();
    expect(() => once.publish(workspace, unavailable), throwsStateError);
    expect(file.readAsBytesSync(), before);
    expect(workspace.receipts.listSync(), hasLength(1));
  });
}
