import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_page.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

import '../../../tool/backup_recovery_scenario.dart';

Widget _page({
  required AppDatabase db,
  required PinService pin,
  required String deviceId,
}) {
  return AppScope(
    db: db,
    pin: pin,
    deviceId: deviceId,
    wipeLocalData: () async {},
    restoreFromBackup: (fileBytes, password) async {},
    child: const MaterialApp(home: BackupPage()),
  );
}

void main() {
  setUp(BackupIo.end);
  tearDown(BackupIo.end);

  testWidgets('reloads last backup when the live database is replaced', (
    tester,
  ) async {
    final db1 = AppDatabase.forTesting(NativeDatabase.memory());
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db1.close);
    addTearDown(db2.close);

    await db1.settingsDao.setSetting(
      kLastBackupAtKey,
      '2026-01-01T00:00:00.000Z',
    );
    await db1.settingsDao.setSetting(kLastBackupSourceKey, 'old-dev');
    await db2.settingsDao.setSetting(
      kLastBackupAtKey,
      '2026-09-14T08:30:00.000Z',
    );
    await db2.settingsDao.setSetting(kLastBackupSourceKey, 'restored-dev');

    final pin1 = PinService(db1.settingsDao);
    final pin2 = PinService(db2.settingsDao);
    final id1 = await db1.settingsDao.ensureDeviceId();
    final id2 = await db2.settingsDao.ensureDeviceId();

    await tester.pumpWidget(_page(db: db1, pin: pin1, deviceId: id1));
    await tester.pumpAndSettle();
    expect(find.textContaining('old-dev'), findsOneWidget);

    await tester.pumpWidget(_page(db: db2, pin: pin2, deviceId: id2));
    await tester.pumpAndSettle();
    expect(find.textContaining('restored-dev'), findsOneWidget);
    expect(find.textContaining('old-dev'), findsNothing);
  });

  testWidgets('password dialog cancel does not dispose controllers early', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(_page(db: db, pin: pin, deviceId: deviceId));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pumpAndSettle();
    expect(find.text('Encrypt backup'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.save_alt), warnIfMissed: false);
    await tester.pump();
    expect(find.text('Encrypt backup'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Encrypt backup'), findsNothing);
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pumpAndSettle();
    expect(find.text('Encrypt backup'), findsOneWidget);
  });

  testWidgets('restore sets busy before PIN so export cannot start', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);
    await pin.setPin('1234');

    await tester.pumpWidget(_page(db: db, pin: pin, deviceId: deviceId));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_backup_restore));
    await tester.pumpAndSettle();
    expect(find.text('Editor PIN'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.save_alt), warnIfMissed: false);
    await tester.pump();
    expect(find.text('Editor PIN'), findsOneWidget);
    expect(find.text('Encrypt backup'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Editor PIN'), findsNothing);
  });

  testWidgets('backup page shows restore retry when recover failed', (
    tester,
  ) async {
    restoreRecoverError = StateError('photo replace');
    addTearDown(() => restoreRecoverError = null);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(_page(db: db, pin: pin, deviceId: deviceId));
    await tester.pumpAndSettle();
    expect(find.text('Restore did not finish'), findsOneWidget);
    expect(find.text(kRestoreRecoverRetryMessage), findsOneWidget);
  });

  testWidgets('home shell surfaces recover retry without crashing', (
    tester,
  ) async {
    restoreRecoverError = StateError('photo replace');
    addTearDown(() => restoreRecoverError = null);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: deviceId,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(kRestoreRecoverRetryMessage), findsOneWidget);
  });

  testWidgets('unsupported save location reports Backup failed, not a crash', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: deviceId,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: MaterialApp(
          home: BackupPage(
            pickSavePath: ({required suggestedName}) async {
              throw UnsupportedError('getSaveLocation');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      'test-backup',
    );
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .at(1),
      'test-backup',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Backup restored'), findsNothing);
    expect(find.textContaining('Backup failed'), findsOneWidget);
  });

  testWidgets('restore during wipe throws instead of reporting success', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('wp-app-busy-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, kSqliteFileName)).writeAsBytesSync([1]);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final gate = Completer<void>();

    await tester.pumpWidget(
      WiredPartsApp(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: deviceId,
        reopenDatabase: () => AppDatabase.forTesting(NativeDatabase.memory()),
        reset: _HangReset(gate, supportDir: dir, documentsDir: dir),
      ),
    );
    await tester.pumpAndSettle();
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final wipe = scope.wipeLocalData();
    await tester.pump();
    await expectLater(
      scope.restoreFromBackup([1], 'x'),
      throwsA(isA<RestoreBusyException>()),
    );
    gate.complete();
    await wipe;
  });

  for (final invalidProfile in ['missing', 'mismatched', 'multiple']) {
    testWidgets(
      'restore rejects a $invalidProfile local profile before closing the database',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync(
          'wp-app-invalid-profile-',
        );
        final scenario = RecoveryScenario.open(
          run: invalidProfile,
          action: RecoveryAction.exercise,
          temporaryDirectory: temp,
          codec: BackupCodec(iterations: 1000),
        );
        addTearDown(() {
          scenario.close();
          temp.deleteSync(recursive: true);
        });
        await tester.runAsync(() async {
          await scenario.seed();
          await scenario.export();
        });
        final db = scenario.openDatabase(scenario.receiver);
        addTearDown(db.close);
        await tester.runAsync(
          () => db.customStatement(switch (invalidProfile) {
            'missing' => 'DELETE FROM device_profiles',
            'mismatched' =>
              "UPDATE device_profiles SET id = 'different-local-installation'",
            _ => "INSERT INTO device_profiles (id, display_name, created_at) VALUES ('second-local-installation', 'Second local profile', 1700000999)",
          }),
        );
        final before = await tester.runAsync(
          () => scenario.receipt(db, scenario.receiver),
        );
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
              return scenario.openDatabase(scenario.receiver);
            },
          ),
        );
        await tester.pump();
        final scope = tester.widget<AppScope>(find.byType(AppScope));
        await tester.runAsync(
          () => expectLater(
            scope.restoreFromBackup(
              scenario.archive.readAsBytesSync(),
              'synthetic recovery archive only',
            ),
            invalidProfile == 'multiple'
                ? throwsA(isA<StateError>())
                : throwsA(
                    isA<StateError>().having(
                      (e) => e.message,
                      'message',
                      'Local device profile does not match this installation',
                    ),
                  ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(reopens, 0);
        final after = await tester.runAsync(
          () => scenario.receipt(db, scenario.receiver),
        );
        expect(after, before);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'staged device profile write failure preserves receiver shop and restart identity',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'wp-app-staged-identity-',
      );
      final scenario = RecoveryScenario.open(
        run: 'profile-failure',
        action: RecoveryAction.exercise,
        temporaryDirectory: temp,
        codec: BackupCodec(iterations: 1000),
      );
      addTearDown(() {
        scenario.close();
        temp.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        await scenario.seed();
        await scenario.export();
      });
      var live = scenario.openDatabase(scenario.receiver);
      addTearDown(() => live.close());
      await tester.runAsync(
        () => live.customStatement(
          'UPDATE device_profiles SET display_name = ?, created_at = ?',
          ['  Exact local profile  ', 1700000123],
        ),
      );
      final before = await tester.runAsync(
        () => scenario.receipt(live, scenario.receiver),
      );
      var reopens = 0;
      await tester.pumpWidget(
        WiredPartsApp(
          db: live,
          pin: PinService(live.settingsDao),
          deviceId: scenario.receiver.deviceId,
          reset: LocalDataReset(
            supportDir: scenario.receiver.support,
            documentsDir: scenario.receiver.documents,
            photosDir: scenario.receiver.photos,
          ),
          reopenDatabase: () {
            reopens++;
            live = scenario.openDatabase(scenario.receiver);
            return live;
          },
          failDeviceProfileWrite: true,
        ),
      );
      await tester.pump();
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      await tester.runAsync(
        () => expectLater(
          scope.restoreFromBackup(
            scenario.archive.readAsBytesSync(),
            'synthetic recovery archive only',
          ),
          throwsA(
            isA<BackupFormatException>().having(
              (e) => e.message,
              'message',
              contains('device profile write failure'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(reopens, 1);
      final after = await tester.runAsync(
        () => scenario.receipt(live, scenario.receiver),
      );
      expect(after, before);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(live.close);
      live = scenario.openDatabase(scenario.receiver);
      final restarted = await tester.runAsync(
        () => scenario.receipt(live, scenario.receiver),
      );
      expect(restarted, before);
      expect(restarted!['deviceProfiles'], [
        {
          'id': scenario.receiver.deviceId,
          'display_name': '  Exact local profile  ',
          'created_at': 1700000123,
        },
      ]);
    },
  );

  testWidgets('wipe during restore throws instead of silent success', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('wp-wipe-during-restore-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, kSqliteFileName)).writeAsBytesSync([1]);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final gate = Completer<void>();

    await tester.pumpWidget(
      WiredPartsApp(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: deviceId,
        reopenDatabase: () => AppDatabase.forTesting(NativeDatabase.memory()),
        reset: LocalDataReset(supportDir: dir, documentsDir: dir),
        beforeRestore: () => gate.future,
      ),
    );
    await tester.pumpAndSettle();
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final restore = scope.restoreFromBackup([1], 'x');
    await tester.pump();
    await expectLater(
      scope.wipeLocalData(),
      throwsA(isA<RestoreBusyException>()),
    );
    gate.complete();
    await expectLater(restore, throwsA(isA<BackupFormatException>()));
  });

  testWidgets('export lock stays busy after Backup page is popped', (
    tester,
  ) async {
    final hang = Completer<void>();
    addTearDown(() {
      if (!hang.isCompleted) hang.complete();
    });
    var flushStarted = false;
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: deviceId,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: MaterialApp(
          home: BackupPage(
            pickSavePath: ({required suggestedName}) async =>
                '/tmp/unused.wpbackup',
            flushWal: () async {
              flushStarted = true;
              await hang.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      'test-backup',
    );
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .at(1),
      'test-backup',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(flushStarted, isTrue);
    expect(BackupIo.isBusy, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(BackupIo.isBusy, isTrue);
    expect(find.text('Backup saved'), findsNothing);
  });

  testWidgets('export is blocked when another backup is already running', (
    tester,
  ) async {
    expect(BackupIo.tryStart(), isTrue);
    addTearDown(BackupIo.end);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: deviceId,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: const MaterialApp(home: BackupPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pumpAndSettle();
    expect(find.text(kBackupAlreadyInProgressMessage), findsOneWidget);
    expect(find.text('Encrypt backup'), findsNothing);
  });

  test('BackupIo tryStart fails while held', () {
    BackupIo.end();
    expect(BackupIo.tryStart(), isTrue);
    expect(BackupIo.tryStart(), isFalse);
    BackupIo.end();
    expect(BackupIo.tryStart(), isTrue);
    BackupIo.end();
  });

  test('BackupIo waitAndRun waits until the lock is released', () async {
    BackupIo.end();
    expect(BackupIo.tryStart(), isTrue);
    var started = false;
    final future = BackupIo.waitAndRun(() async {
      started = true;
      return 7;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(started, isFalse);
    BackupIo.end();
    expect(await future, 7);
    expect(BackupIo.isBusy, isFalse);
  });

  testWidgets('wipe rejects while BackupIo is held', (tester) async {
    expect(BackupIo.tryStart(), isTrue);
    addTearDown(BackupIo.end);

    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final dir = Directory.systemTemp.createTempSync('wp-wipe-busy-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(
      WiredPartsApp(
        db: db,
        pin: pin,
        deviceId: deviceId,
        reset: LocalDataReset(supportDir: dir, documentsDir: dir),
        reopenDatabase: () => AppDatabase.forTesting(NativeDatabase.memory()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('More'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset / wipe all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Wipe everything'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wipe failed'), findsOneWidget);
    expect(find.textContaining('already in progress'), findsOneWidget);
    expect(BackupIo.isBusy, isTrue);
  });

  testWidgets('leaving backup after closed db does not throw', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: deviceId,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('More'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup & restore'));
    await tester.pumpAndSettle();
    expect(find.text('Export encrypted backup'), findsOneWidget);

    await db.close();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Backup & restore'), findsOneWidget);
  });
}

class _HangReset extends LocalDataReset {
  _HangReset(this.gate, {super.supportDir, super.documentsDir});

  final Completer<void> gate;

  @override
  Future<void> wipeFiles() => gate.future;
}
