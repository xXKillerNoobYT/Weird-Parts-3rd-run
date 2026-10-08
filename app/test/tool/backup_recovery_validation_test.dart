import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import '../../tool/backup_recovery_scenario.dart';

void main() {
  test('restart refuses missing evidence without creating a shop', () {
    final temp = Directory.systemTemp.createTempSync('recovery-missing-');
    addTearDown(() => temp.deleteSync(recursive: true));
    expect(
      () => RecoveryScenario.open(
        run: 'missing',
        action: RecoveryAction.restart,
        temporaryDirectory: temp,
      ),
      throwsStateError,
    );
    expect(temp.listSync(), isEmpty);
  });

  test('an initialized shop without a manifest cannot restart or reseed', () {
    final temp = Directory.systemTemp.createTempSync('recovery-interrupted-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final scenario = RecoveryScenario.open(
      run: 'interrupted',
      action: RecoveryAction.exercise,
      temporaryDirectory: temp,
    );
    scenario.source.markInitialized();
    scenario.receiver.markInitialized();
    scenario.close();
    expect(
      () => RecoveryScenario.open(
        run: 'interrupted',
        action: RecoveryAction.restart,
        temporaryDirectory: temp,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Restart requires recovery evidence',
        ),
      ),
    );
    expect(
      () => RecoveryScenario.open(
        run: 'interrupted',
        action: RecoveryAction.exercise,
        temporaryDirectory: temp,
      ),
      throwsStateError,
    );
  });

  testWidgets(
    'production callback rejects damaged archives and restores every domain relationship across reopen',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('recovery-behavior-');
      final scenario = RecoveryScenario.open(
        run: 'behavior',
        action: RecoveryAction.exercise,
        temporaryDirectory: temp,
        codec: BackupCodec(iterations: 1000),
      );
      addTearDown(() {
        scenario.close();
        temp.deleteSync(recursive: true);
      });
      late Map<String, Object?> source;
      await tester.runAsync(() async {
        await scenario.seed();
        source = await scenario.export();
      });
      final registry = source['records'] as Map;
      expect(registry.keys.toSet(), {
        'categories',
        'styles',
        'types',
        'devices',
        'brands',
        'suppliers',
        'parts',
        'part_devices',
        'brand_versions',
        'supplier_listings',
        'jobs',
        'job_lines',
        'order_splits',
      });
      final prefix = '${scenario.source.run}-sender';
      expect(
        (registry['parts'] as List).single,
        containsPair('id', '$prefix-part'),
      );
      expect(
        (registry['job_lines'] as List).single,
        allOf(
          containsPair('job_id', '$prefix-job'),
          containsPair('part_id', '$prefix-part'),
          containsPair('brand_version_id', '$prefix-brand-version'),
        ),
      );
      expect(
        (registry['order_splits'] as List).single,
        allOf(
          containsPair('job_line_id', '$prefix-line'),
          containsPair('supplier_id', '$prefix-supplier'),
        ),
      );
      expect(
        (registry['jobs'] as List).singleWhere(
          (row) => row['deleted_at'] != null,
        ),
        allOf(
          containsPair('id', '$prefix-deleted-job'),
          containsPair('revision', 7),
          containsPair('origin_device_id', scenario.source.deviceId),
        ),
      );
      final db = scenario.openDatabase(scenario.receiver);
      var liveDatabase = db;
      addTearDown(() => liveDatabase.close());
      await tester.runAsync(
        () => db.customStatement(
          'UPDATE device_profiles SET display_name = ?, created_at = ?',
          ['  Synthetic receiver name  ', 1700000123],
        ),
      );
      final receiverProfileBefore = await tester.runAsync(
        () =>
            db.customSelect('SELECT * FROM device_profiles ORDER BY id').get(),
      );
      expect(receiverProfileBefore!.single.data, {
        'id': scenario.receiver.deviceId,
        'display_name': '  Synthetic receiver name  ',
        'created_at': 1700000123,
      });
      var reopens = 0;
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: scenario.receiver.deviceId,
          reset: LocalDataReset(
            supportDir: scenario.receiver.support,
            documentsDir: scenario.receiver.documents,
            photosDir: scenario.receiver.photos,
          ),
          reopenDatabase: () {
            reopens++;
            liveDatabase = scenario.openDatabase(scenario.receiver);
            return liveDatabase;
          },
        ),
      );
      await tester.pump();
      AppScope scope() => tester.widget<AppScope>(find.byType(AppScope));
      await tester.runAsync(
        () => scenario.exercise(
          scope: scope,
          settle: () => tester.pump(),
          sourceReceipt: source,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(scenario.readManifest()['state'], 'restored');
      expect(reopens, 1);
      final reports = scenario.receiver.receipts
          .listSync()
          .whereType<File>()
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .toList();
      expect(reports.map((row) => row['step']).toSet(), {
        'wrongPassword',
        'damagedArchive',
        'unsupportedSchema',
        'restore',
      });
      expect(reports.every((row) => row['validation'] == 'pass'), isTrue);
      for (final row in reports.where((row) => row['step'] != 'restore')) {
        expect(row['after']['deviceProfiles'], row['before']['deviceProfiles']);
        expect(row['after']['sqliteSha256'], row['before']['sqliteSha256']);
      }
      final restoreReport = reports.singleWhere(
        (row) => row['step'] == 'restore',
      );
      expect(restoreReport['after']['deviceProfiles'], [
        receiverProfileBefore.single.data,
      ]);
      expect(
        restoreReport['after']['deviceProfiles'],
        restoreReport['before']['deviceProfiles'],
      );
      expect(
        {for (final row in reports) row['step']: row['actualOutcome']},
        {
          'wrongPassword': 'rejected',
          'damagedArchive': 'rejected',
          'unsupportedSchema': 'rejected',
          'restore': 'restored',
        },
      );
      for (final file
          in scenario.receiver.receipts.listSync().whereType<File>()) {
        expect(file.readAsStringSync(), isNot(contains('editor_pin_hash')));
      }
      final live = scope().db;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(live.close);
      final reopened = scenario.openDatabase(scenario.receiver);
      liveDatabase = reopened;
      try {
        await tester.runAsync(() => scenario.restart(reopened));
        final profileAfterRestart = await tester.runAsync(
          () => reopened
              .customSelect('SELECT * FROM device_profiles ORDER BY id')
              .get(),
        );
        expect(
          profileAfterRestart!.single.data,
          receiverProfileBefore.single.data,
        );
        await tester.runAsync(
          () => reopened.customStatement(
            'UPDATE device_profiles SET created_at = 1700000999',
          ),
        );
        await tester.runAsync(
          () => expectLater(scenario.restart(reopened), throwsStateError),
        );
        await tester.runAsync(
          () => reopened.customStatement(
            'UPDATE device_profiles SET created_at = 1700000123',
          ),
        );
        await tester.runAsync(
          () =>
              reopened.customStatement('UPDATE order_splits SET quantity = 99'),
        );
        await tester.runAsync(
          () => expectLater(scenario.restart(reopened), throwsStateError),
        );
      } finally {
        await tester.runAsync(reopened.close);
      }
      scenario.close();
      expect(
        () => RecoveryScenario.open(
          run: 'behavior',
          action: RecoveryAction.exercise,
          temporaryDirectory: temp,
        ),
        throwsStateError,
      );
      final archive = scenario.archive;
      final original = archive.readAsBytesSync();
      archive.writeAsBytesSync([1, 2, 3]);
      expect(scenario.readManifest, throwsStateError);
      archive.writeAsBytesSync(original);
    },
  );
}
