import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  testWidgets(
    'closing a recovered creation keeps its receipt until Open job acknowledges it',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final deviceId = await db.settingsDao.ensureDeviceId();
      final pin = PinService(db.settingsDao);
      final edits = EditDrafts(db: db, pin: pin, deviceId: deviceId);
      final session =
          (await edits.openNewJob() as FreshEdit<NewJobEditSession>).session;
      session.replace(const NewJobInput(nameText: 'Receipt survives Close'));
      await session.flush();
      final created = await session.save();

      await tester.pumpWidget(
        WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();
      expect(find.text('Created ${created.name}'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/control'),
        isNotNull,
      );
      expect((await db.select(db.jobs).get()).map((job) => job.id), [
        created.id,
      ]);

      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Open job'));
      await tester.pumpAndSettle();

      expect(find.text('No parts on this job yet'), findsOneWidget);
      expect(find.text(created.name), findsOneWidget);
      expect((await db.select(db.jobs).get()).map((job) => job.id), [
        created.id,
      ]);
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/control'),
        isNull,
      );
    },
  );

  testWidgets(
    'Start another acknowledges the old Job; canceling its draft creates no second Job',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final deviceId = await db.settingsDao.ensureDeviceId();
      final pin = PinService(db.settingsDao);
      final edits = EditDrafts(db: db, pin: pin, deviceId: deviceId);
      final session =
          (await edits.openNewJob() as FreshEdit<NewJobEditSession>).session;
      session.replace(const NewJobInput(nameText: 'Only saved Job'));
      await session.flush();
      final created = await session.save();

      await tester.pumpWidget(
        WiredPartsApp(db: db, pin: pin, deviceId: deviceId),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Start another job'));
      await tester.pumpAndSettle();

      final nameField = find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(nameField).controller!.text, isEmpty);
      await tester.enterText(nameField, 'Unfinished second Job');
      await tester.pumpAndSettle();
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/input'),
        isNotNull,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      final jobs = await db.select(db.jobs).get();
      expect(jobs, hasLength(1));
      expect(jobs.single.id, created.id);
      expect(jobs.single.name, 'Only saved Job');
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/input'),
        isNull,
      );
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/control'),
        isNull,
      );
    },
  );

  testWidgets(
    'Back retains a typed name for Resume and Cancel discards only the draft',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final deviceId = await db.settingsDao.ensureDeviceId();
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: deviceId,
        ),
      );
      await tester.pumpAndSettle();
      const rawName = '  Backed-out name · exact text  ';
      Finder nameField() => find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(TextField),
      );

      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), rawName);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(await db.select(db.jobs).get(), isEmpty);
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/input'),
        isNotNull,
      );
      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(await db.select(db.jobs).get(), isEmpty);
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/input'),
        isNull,
      );
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/control'),
        isNull,
      );
    },
  );

  testWidgets(
    'Create opens the saved Job and acknowledges its receipt after the detail frame',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final deviceId = await db.settingsDao.ensureDeviceId();
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: deviceId,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();
      const name = 'Create opens this Job';
      final nameField = find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(TextField),
      );
      await tester.enterText(nameField, name);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(find.text('No parts on this job yet'), findsOneWidget);
      expect(find.text(name), findsOneWidget);
      final jobs = await db.select(db.jobs).get();
      expect(jobs, hasLength(1));
      expect(jobs.single.name, name);
      expect(
        await db.settingsDao.getSetting('local_edit_v1/job-new/control'),
        isNull,
      );
    },
  );

  testWidgets(
    'unfinished New Job name resumes exactly after normal close and reopen',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('new-job-draft-');
      final file = File('${directory.path}/synthetic.sqlite');
      var db = AppDatabase.forTesting(NativeDatabase(file));
      var dbOpen = true;
      late final String deviceId;

      addTearDown(
        () => tester.runAsync(() async {
          if (dbOpen) await db.close();
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        }),
      );

      deviceId = (await tester.runAsync(db.settingsDao.ensureDeviceId))!;
      Future<void> pumpApp() async {
        await tester.pumpWidget(
          WiredPartsApp(
            db: db,
            pin: PinService(db.settingsDao),
            deviceId: deviceId,
          ),
        );
        await tester.pumpAndSettle();
      }

      Finder nameField() => find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(TextField),
      );

      await pumpApp();
      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();
      const rawName = '  Riverside pump repair · phase 2  ';
      await tester.enterText(nameField(), rawName);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, rawName);

      expect(
        await tester.runAsync(tester.binding.handleRequestAppExit),
        AppExitResponse.exit,
      );
      dbOpen = false;
      await tester.pumpWidget(const SizedBox.shrink());

      db = AppDatabase.forTesting(NativeDatabase(file));
      dbOpen = true;
      await pumpApp();
      await tester.tap(find.byTooltip('New job'));
      await tester.pumpAndSettle();

      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(nameField(), findsOneWidget);
      expect((tester.widget<TextField>(nameField()).controller!).text, rawName);
      expect(await tester.runAsync(() => db.select(db.jobs).get()), isEmpty);
    },
  );
}
