import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_page.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import 'backup_test_support.dart';

void main() {
  testWidgets('reloads last backup after restore and keeps password dialog alive',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    await db.settingsDao.setSetting(
      kLastBackupAtKey,
      '2026-01-01T00:00:00.000Z',
    );
    await db.settingsDao.setSetting(kLastBackupSourceKey, 'old-dev');
    final pin = PinService(db.settingsDao);

    final sqlite = await sqliteBytesWithSetting(key: 'marker', value: 'bak');
    final payload = BackupPayload(
      createdAt: DateTime.utc(2026, 9, 14, 8, 30),
      sourceDeviceId: 'restored-dev',
      sqliteBytes: sqlite,
      photos: const {},
    );
    final bytes = await BackupCodec(iterations: 1000).encrypt(payload, 'pw');
    final dir = Directory.systemTemp.createTempSync('wp-bak-page-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'shop.wpbackup'))
      ..writeAsBytesSync(bytes);

    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: deviceId,
        wipeLocalData: () async {},
        restoreFromBackup: (_, __) async {
          await db.settingsDao.setSetting(
            kLastBackupAtKey,
            payload.createdAt.toIso8601String(),
          );
          await db.settingsDao.setSetting(
            kLastBackupSourceKey,
            payload.sourceDeviceId,
          );
        },
        child: MaterialApp(
          home: BackupPage(
            codec: BackupCodec(iterations: 1000),
            pickOpenPath: () async => file.path,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('old-dev'), findsOneWidget);

    await tester.tap(find.text('Restore encrypted backup'));
    await tester.pumpAndSettle();
    expect(find.text('Restore this backup?'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Decrypt backup'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Backup restored'), findsOneWidget);
    expect(find.textContaining('restored-dev'), findsOneWidget);
    expect(find.textContaining('old-dev'), findsNothing);
  });
}
