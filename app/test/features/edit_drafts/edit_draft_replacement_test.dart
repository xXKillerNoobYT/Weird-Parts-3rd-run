import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import '../company/company_job_test_support.dart';

Future<List<Map<String, Object?>>> _draftRows(AppDatabase db) async =>
    (await db
            .customSelect(
              "SELECT key,value FROM app_settings WHERE key LIKE 'local_edit_v1/%' ORDER BY key",
            )
            .get())
        .map((row) => row.data)
        .toList();

JobLineInput _input(String text) => JobLineInput(
  useCustom: true,
  partId: null,
  brandVersionId: null,
  customNameText: text,
  neededText: ' 1..2 ',
  pullText: '0',
  customNotes: '  retained notes  ',
  uom: null,
  notes: null,
  splits: const [SplitInput(supplierId: null, quantityText: '')],
);

void main() {
  testWidgets(
    'actual whole-shop replacement replaces receiver drafts, blocks foreign input, and same-installation backup resumes exact base',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('issue134-replacement-');
      final support = Directory('${root.path}/receiver')..createSync();
      final documents = Directory('${root.path}/documents')..createSync();
      final photos = Directory('${root.path}/photos');
      final sourceSupport = Directory('${root.path}/sender')..createSync();
      final sourcePhotos = Directory('${root.path}/sender-photos');
      final file = File('${support.path}/$kSqliteFileName');
      final sourceFile = File('${sourceSupport.path}/$kSqliteFileName');
      final original = AppDatabase.forTesting(NativeDatabase(file));
      final source = AppDatabase.forTesting(NativeDatabase(sourceFile));
      final opened = <AppDatabase>[original, source];
      addTearDown(
        () => tester.runAsync(() async {
          BackupIo.end();
          for (final db in opened) {
            await db.close();
          }
          if (root.existsSync()) root.deleteSync(recursive: true);
        }),
      );
      final installation = InstallationSecurity(
        store: JobTestStore(),
        namespace: 'synthetic.draft-replacement',
      );
      late String device, localJob, sourceDevice, sourceJob;
      late BackupPayload incoming;
      late List<Map<String, Object?>> incomingDrafts;
      await tester.runAsync(() async {
        await installation.start(original);
        expect(installation.readiness, InstallationReadiness.ready);
        device = await original.settingsDao.ensureDeviceId();
        localJob = await JobsRepository(
          original,
          device,
        ).createJob('Receiver baseline job');
        sourceDevice = await source.settingsDao.ensureDeviceId();
        sourceJob = await JobsRepository(
          source,
          sourceDevice,
        ).createJob('Sender baseline job');
        final sourceEdits = EditDrafts(
          db: source,
          pin: PinService(source.settingsDao),
          deviceId: sourceDevice,
        );
        final sourceSession = (await sourceEdits.openJobLine(
          sourceJob,
        ) as FreshEdit<JobLineEditSession>).session;
        sourceSession.replace(_input('  Sender unfinished input  '));
        await sourceSession.leave(LeaveIntent.back);
        incomingDrafts = await _draftRows(source);
        await checkpointWalForExport(source);
        incoming =
            await BackupStore(
              supportDir: sourceSupport,
              photosDir: sourcePhotos,
            ).collect(
              sourceDeviceId: sourceDevice,
              createdAt: DateTime.utc(2026, 10, 21),
              sqliteBytes: await sourceFile.readAsBytes(),
            );
        await source.close();
      });
      await tester.pumpWidget(
        WiredPartsApp(
          db: original,
          pin: PinService(original.settingsDao),
          deviceId: device,
          installation: installation,
          reset: LocalDataReset(
            supportDir: support,
            documentsDir: documents,
            photosDir: photos,
          ),
          reopenDatabase: () {
            final db = AppDatabase.forTesting(NativeDatabase(file));
            opened.add(db);
            return db;
          },
        ),
      );
      await tester.pumpAndSettle();
      final firstScope = tester.widget<AppScope>(find.byType(AppScope));
      late JobLineEditSession oldSession;
      late List<int> localEncryptedBackup;
      late List<Map<String, Object?>> localDrafts;
      await tester.runAsync(() async {
        oldSession = (await firstScope.edits!.openJobLine(
          localJob,
        ) as FreshEdit<JobLineEditSession>).session;
        oldSession.replace(_input('  Receiver unfinished input  '));
        await oldSession.flush();
        localDrafts = await _draftRows(original);
        await checkpointWalForExport(original);
        final localPayload =
            await BackupStore(supportDir: support, photosDir: photos).collect(
              sourceDeviceId: device,
              createdAt: DateTime.utc(2026, 10, 20),
              sqliteBytes: await file.readAsBytes(),
            );
        localEncryptedBackup = await BackupCodec(iterations: 1000)
            .encrypt(localPayload, 'synthetic-password');
        expect(BackupIo.tryStart(), true);
        try {
          await firstScope.restoreFromPayload!(incoming);
        } finally {
          BackupIo.end();
        }
      });
      await tester.pumpAndSettle();
      final foreignScope = tester.widget<AppScope>(find.byType(AppScope));
      expect(foreignScope.db, isNot(same(original)));
      expect(foreignScope.edits, isNot(same(firstScope.edits)));
      await tester.runAsync(() async {
        expect(await _draftRows(foreignScope.db), incomingDrafts);
        expect(
          await JobsRepository(foreignScope.db, device).getJob(localJob),
          isNull,
        );
        final blocked = await foreignScope.edits!.openJobLine(sourceJob);
        expect(blocked, isA<BlockedEdit<JobLineEditSession>>());
        expect(
          (blocked as BlockedEdit<JobLineEditSession>).preservedInput,
          contains('Sender unfinished input'),
        );
        expect(await _draftRows(foreignScope.db), incomingDrafts);
        oldSession.replace(_input('Rejected callback after replacement'));
        await oldSession.flush();
        expect(await _draftRows(foreignScope.db), incomingDrafts);
        expect(BackupIo.tryStart(), true);
        try {
          await foreignScope.restoreFromBackup(
            localEncryptedBackup,
            'synthetic-password',
          );
        } finally {
          BackupIo.end();
        }
      });
      await tester.pumpAndSettle();
      final restoredScope = tester.widget<AppScope>(find.byType(AppScope));
      await tester.runAsync(() async {
        expect(restoredScope.db, isNot(same(foreignScope.db)));
        expect(installation.readiness, InstallationReadiness.ready);
        expect(await _draftRows(restoredScope.db), localDrafts);
        final recovery = await restoredScope.edits!.openJobLine(localJob);
        expect(recovery, isA<RecoverableEdit<JobLineEditSession>>());
        final resumed = await (recovery as RecoverableEdit<JobLineEditSession>)
            .resume();
        expect(resumed.initial.customNameText, '  Receiver unfinished input  ');
        expect(resumed.initial.neededText, ' 1..2 ');
        expect(resumed.initial.customNotes, '  retained notes  ');
        oldSession.replace(
          _input('Rejected callback after local backup restore'),
        );
        await oldSession.flush();
        expect(await _draftRows(restoredScope.db), localDrafts);
        expect(
          await JobsRepository(
            restoredScope.db,
            device,
          ).listLinesForJob(localJob),
          isEmpty,
        );
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
