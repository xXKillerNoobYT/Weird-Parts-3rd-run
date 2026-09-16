import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

import 'backup_test_support.dart';

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

  testWidgets('restore succeeds if keepLocalDeviceId fails after the swap', (
    tester,
  ) async {
    final dest = Directory.systemTemp.createTempSync('wp-app-keep-id-');
    addTearDown(() => dest.deleteSync(recursive: true));
    late Uint8List bytes;
    const destId = 'dest-device-keep';
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var keepAttempts = 0;

    await tester.runAsync(() async {
      File(p.join(dest.path, kSqliteFileName)).writeAsBytesSync(
        await sqliteBytesWithSetting(key: 'marker', value: 'local-shop'),
      );
      final sqlite = await sqliteBytesWithSetting(
        key: 'marker',
        value: 'from-backup',
      );
      bytes = await BackupCodec(iterations: 1000).encrypt(
        BackupPayload(
          createdAt: DateTime.utc(2026, 9, 13, 18),
          sourceDeviceId: 'source-device',
          sqliteBytes: sqlite,
          photos: const {},
        ),
        'pw',
      );
      await db.settingsDao.keepLocalDeviceId(destId);
    });

    await tester.pumpWidget(
      WiredPartsApp(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: destId,
        reset: LocalDataReset(supportDir: dest, documentsDir: dest),
        reopenDatabase: () => AppDatabase.forTesting(
          NativeDatabase(File(p.join(dest.path, kSqliteFileName))),
        ),
        keepLocalDeviceId: (next, id) async {
          keepAttempts++;
          throw StateError('keep id');
        },
      ),
    );
    await tester.pump();
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    await tester.runAsync(() => scope.restoreFromBackup(bytes, 'pw'));
    await tester.pump();

    expect(keepAttempts, 2);
    final live = tester.widget<AppScope>(find.byType(AppScope));
    expect(live.deviceId, destId);
    await tester.runAsync(() async {
      expect(await live.db.settingsDao.getSetting('marker'), 'from-backup');
    });
    addTearDown(live.db.close);
  });

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

  testWidgets(
    'Backup restored when restoreFromBackup returns after identity skip',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final deviceId = await db.settingsDao.ensureDeviceId();
      final pin = PinService(db.settingsDao);
      final dir = Directory.systemTemp.createTempSync('wp-restore-ok-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final backup = File(p.join(dir.path, 'shop.wpbackup'));
      late Uint8List bytes;
      await tester.runAsync(() async {
        bytes = await BackupCodec(iterations: 1000).encrypt(
          BackupPayload(
            createdAt: DateTime.utc(2026, 9, 13, 18),
            sourceDeviceId: 'source-device',
            sqliteBytes: await sqliteBytesWithSetting(
              key: 'marker',
              value: 'from-backup',
            ),
            photos: const {},
          ),
          'pw',
        );
      });
      backup.writeAsBytesSync(bytes);

      await tester.pumpWidget(
        AppScope(
          db: db,
          pin: pin,
          deviceId: deviceId,
          wipeLocalData: () async {},
          restoreFromBackup: (_, _) async {},
          child: MaterialApp(
            home: BackupPage(pickOpenPath: () async => backup.path),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_backup_restore));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Restore'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'pw',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Backup restored'), findsOneWidget);
      expect(find.textContaining('Restore failed'), findsNothing);
    },
  );

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
