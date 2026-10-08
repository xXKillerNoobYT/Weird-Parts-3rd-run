import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_page.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import '../../../tool/backup_recovery_scenario.dart';

class _NoDiscovery implements NearbyDiscovery {
  @override
  Stream<List<NearbyPeer>> get peers => const Stream.empty();

  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {}
}

Future<Map<String, Object?>> _readShop(File file) async {
  final db = AppDatabase.forTesting(NativeDatabase(file));
  try {
    final jobs = await db
        .customSelect(
          'SELECT id, name FROM jobs WHERE deleted_at IS NULL ORDER BY id',
        )
        .get();
    final profiles = await db
        .customSelect(
          'SELECT id, display_name, created_at FROM device_profiles',
        )
        .get();
    final parts = await db.customSelect('SELECT photo_path FROM parts').get();
    final allJobs = await db
        .customSelect('SELECT COUNT(*) AS count FROM jobs')
        .getSingle();
    final pin = PinService(db.settingsDao);
    return {
      'jobs': jobs.map((row) => row.data).toList(),
      'totalJobs': allJobs.read<int>('count'),
      'profiles': profiles.map((row) => row.data).toList(),
      'photoPaths': parts.map((row) => row.read<String>('photo_path')).toList(),
      'pinSet': await pin.isPinSet(),
      'wrongPinAccepted': await pin.unlock('9999'),
      'shopPinAccepted': await pin.unlock('1234'),
    };
  } finally {
    await db.close();
  }
}

void main() {
  setUp(BackupIo.end);
  tearDown(BackupIo.end);

  testWidgets(
    'same Nearby page exports live WAL edits after receiving a shop',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'wp-nearby-page-restore-',
      );
      final scenario = RecoveryScenario.open(
        run: 'page-restore',
        action: RecoveryAction.exercise,
        temporaryDirectory: temp,
      );
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = scenario.receiver;
      AppDatabase? live;
      NearbyController? controller;
      addTearDown(() async {
        await live?.close();
        scenario.close();
        PathProviderPlatform.instance = previousPaths;
        temp.deleteSync(recursive: true);
      });
      final photoBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8ioAAAAASUVORK5CYII=',
      );
      late BackupPayload incoming;
      await tester.runAsync(() async {
        await scenario.seed();
        File(
          p.join(
            scenario.source.photos.path,
            'recovery-page-restore-sender.png',
          ),
        ).writeAsBytesSync(photoBytes);
        incoming =
            await BackupStore(
              supportDir: scenario.source.support,
              photosDir: scenario.source.photos,
            ).collect(
              sourceDeviceId: scenario.source.deviceId,
              createdAt: DateTime.utc(2026, 10, 7),
              sqliteBytes: File(
                p.join(scenario.source.support.path, kSqliteFileName),
              ).readAsBytesSync(),
            );
        live = scenario.openDatabase(scenario.receiver);
        await live!.customStatement(
          'UPDATE device_profiles SET display_name = ?, created_at = ?',
          ['  Exact receiving profile  ', 1700000123],
        );
      });
      final initialDb = live!;
      final initialPin = PinService(initialDb.settingsDao);
      await tester.pumpWidget(
        WiredPartsApp(
          db: initialDb,
          pin: initialPin,
          deviceId: scenario.receiver.deviceId,
          reset: LocalDataReset(
            supportDir: scenario.receiver.support,
            documentsDir: scenario.receiver.documents,
            photosDir: scenario.receiver.photos,
          ),
          reopenDatabase: () => live = scenario.openDatabase(scenario.receiver),
        ),
      );
      await tester.pumpAndSettle();
      final ready = Completer<NearbyController>();
      final page = NearbyPage(
        createController:
            ({
              required String deviceId,
              required String deviceName,
              required AppDatabase db,
              required Future<({BackupPayload payload, NearbyOffer offer})>
              Function()
              collectPayload,
              required NearbyApplyPayload applyPayload,
            }) {
              final created = NearbyController(
                deviceId: deviceId,
                deviceName: deviceName,
                discovery: _NoDiscovery(),
                readNetwork: () async => throw const NearbyException(
                  'Transport disabled in restore regression',
                ),
                collectPayload: collectPayload,
                applyPayload: applyPayload,
              );
              ready.complete(created);
              return created;
            },
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => page)));
      await tester.pump();
      controller = await tester.runAsync(
        () => ready.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pumpAndSettle();
      final pageState = tester.state(find.byType(NearbyPage));
      final before = await tester.runAsync(controller!.collectPayload);
      expect(before!.offer.jobs, 1);
      expect(before.offer.parts, 1);
      expect(before.offer.photos, 1);
      final beforeFile = File(p.join(temp.path, 'before.sqlite'))
        ..writeAsBytesSync(before.payload.sqliteBytes);
      final beforeShop = await tester.runAsync(() => _readShop(beforeFile));
      expect(beforeShop!['jobs'], [
        {
          'id': 'recovery-page-restore-receiver-job',
          'name': 'Synthetic receiver shop recovery-page-restore',
        },
      ]);

      await tester.runAsync(() => controller!.applyPayload(incoming));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.state(find.byType(NearbyPage)), same(pageState));
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      expect(scope.db, same(live));
      expect(scope.db, isNot(same(initialDb)));
      expect(scope.pin, isNot(same(initialPin)));
      expect(scope.pin.isUnlocked, isFalse);
      await tester.runAsync(() async {
        expect(await scope.pin.isPinSet(), isTrue);
        expect(await scope.pin.unlock('9999'), isFalse);
        expect(await scope.pin.unlock('1234'), isTrue);
        scope.pin.lock();
        expect(
          (await scope.db
                  .customSelect('SELECT * FROM device_profiles')
                  .getSingle())
              .data,
          {
            'id': 'lan-recovery-page-restore-receiver',
            'display_name': '  Exact receiving profile  ',
            'created_at': 1700000123,
          },
        );
        expect(
          (await scope.db.jobsDao.listActiveJobs())
              .map((job) => job.id)
              .toList(),
          ['recovery-page-restore-sender-job'],
        );
        expect(
          File(
            p.join(
              scenario.receiver.photos.path,
              'recovery-page-restore-sender.png',
            ),
          ).readAsBytesSync(),
          photoBytes,
        );
        expect(
          File(
            p.join(
              scenario.receiver.photos.path,
              'recovery-page-restore-receiver.png',
            ),
          ).existsSync(),
          isFalse,
        );
        final mode = await scope.db
            .customSelect('PRAGMA journal_mode=WAL')
            .getSingle();
        expect(mode.data.values.single, 'wal');
        await scope.db.customStatement('PRAGMA wal_autocheckpoint=0');
        await checkpointWalForExport(scope.db);
        await scope.db.jobsDao.insertJob(
          id: 'after-receive-job',
          name: 'Edited without leaving Nearby',
          deviceId: scope.deviceId,
        );
        expect(
          (await scope.db.jobsDao.getJob('after-receive-job'))!.name,
          'Edited without leaving Nearby',
        );
        final mainOnly = File(p.join(temp.path, 'main-only.sqlite'));
        File(p.join(scenario.receiver.support.path, kSqliteFileName))
            .copySync(mainOnly.path);
        expect((await _readShop(mainOnly))['jobs'], [
          {
            'id': 'recovery-page-restore-sender-job',
            'name': 'Synthetic sender shop recovery-page-restore',
          },
        ]);
      });

      try {
        await tester.runAsync(() async {
          final outgoing = await controller!.collectPayload();
          expect(
            outgoing.offer.sourceDeviceId,
            'lan-recovery-page-restore-receiver',
          );
          expect(outgoing.offer.sourceName, '  Exact receiving profile  ');
          expect(outgoing.offer.jobs, 2);
          expect(outgoing.offer.parts, 1);
          expect(outgoing.offer.photos, 1);
          expect(
            outgoing.payload.sourceDeviceId,
            'lan-recovery-page-restore-receiver',
          );
          expect(outgoing.payload.photos, {
            'recovery-page-restore-sender.png': photoBytes,
          });
          final outgoingFile = File(p.join(temp.path, 'outgoing.sqlite'))
            ..writeAsBytesSync(outgoing.payload.sqliteBytes);
          expect(await _readShop(outgoingFile), {
            'jobs': [
              {
                'id': 'after-receive-job',
                'name': 'Edited without leaving Nearby',
              },
              {
                'id': 'recovery-page-restore-sender-job',
                'name': 'Synthetic sender shop recovery-page-restore',
              },
            ],
            'totalJobs': 3,
            'profiles': [
              {
                'id': 'lan-recovery-page-restore-receiver',
                'display_name': '  Exact receiving profile  ',
                'created_at': 1700000123,
              },
            ],
            'photoPaths': ['recovery-page-restore-sender.png'],
            'pinSet': true,
            'wrongPinAccepted': false,
            'shopPinAccepted': true,
          });
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(controller.dispose);
      }
    },
  );
}
