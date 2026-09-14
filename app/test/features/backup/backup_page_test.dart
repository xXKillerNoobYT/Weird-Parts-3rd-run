import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/backup/backup_page.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

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
}
