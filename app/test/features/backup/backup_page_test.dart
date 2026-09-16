import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_page.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

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
  testWidgets('reloads last backup when the live database is replaced',
      (tester) async {
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

  testWidgets('password dialog cancel does not dispose controllers early',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(_page(db: db, pin: pin, deviceId: deviceId));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save_alt));
    await tester.pumpAndSettle();
    expect(find.text('Encrypt backup'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Encrypt backup'), findsNothing);
  });

  testWidgets('unsupported save location reports Backup failed, not a crash',
      (tester) async {
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
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ).first,
      'test-backup',
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ).at(1),
      'test-backup',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Backup restored'), findsNothing);
    expect(find.textContaining('Backup failed'), findsOneWidget);
  });

  testWidgets('restore during wipe throws instead of reporting success',
      (tester) async {
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
