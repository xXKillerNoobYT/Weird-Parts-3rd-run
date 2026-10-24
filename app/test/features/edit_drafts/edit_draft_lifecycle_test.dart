import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

class _ObservedDatabase extends AppDatabase {
  _ObservedDatabase(File file) : super.forTesting(NativeDatabase(file));
  var closeCalls = 0;
  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
  }
}

void main() {
  testWidgets(
    'normal exit refuses failed draft flush, keeps editing, then closes after exact file-backed flush',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('issue134-exit-');
      final file = File('${directory.path}/synthetic.sqlite');
      final db = _ObservedDatabase(file);
      addTearDown(
        () => tester.runAsync(() async {
          await db.close();
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        }),
      );
      final device = (await tester.runAsync(db.settingsDao.ensureDeviceId))!;
      final job = (await tester.runAsync(
        () => JobsRepository(db, device).createJob('Exit draft job'),
      ))!;
      await tester.pumpWidget(
        WiredPartsApp(
          db: db,
          pin: PinService(db.settingsDao),
          deviceId: device,
        ),
      );
      await tester.pumpAndSettle();
      final scope = tester.widget<AppScope>(find.byType(AppScope));
      final session = (await tester.runAsync(
        () => scope.edits!.openJobLine(job),
      ) as FreshEdit<JobLineEditSession>).session;
      JobLineInput input(String name) => JobLineInput(
        useCustom: true,
        partId: null,
        brandVersionId: null,
        customNameText: name,
        neededText: '  not yet numeric  ',
        pullText: '0',
        customNotes: null,
        uom: null,
        notes: null,
        splits: const [],
      );
      await tester.runAsync(() async {
        session.replace(input('Before failed exit'));
        await session.flush();
      });
      await tester.runAsync(
        () => db.customStatement(
          "CREATE TRIGGER refuse_exit_flush BEFORE UPDATE ON app_settings WHEN NEW.key LIKE 'local_edit_v1/%/input' BEGIN SELECT RAISE(ABORT, 'synthetic exit flush failure'); END",
        ),
      );
      expect(
        await tester.runAsync(tester.binding.handleRequestAppExit),
        AppExitResponse.cancel,
      );
      await tester.pump();
      expect(db.closeCalls, 0);
      expect(
        find.textContaining('Could not save unfinished edits'),
        findsOneWidget,
      );
      final blockers = tester
          .widgetList<AbsorbPointer>(find.byType(AbsorbPointer))
          .where((w) => w.absorbing);
      expect(blockers, isEmpty);
      await tester.runAsync(() async {
        await db.customStatement('DROP TRIGGER refuse_exit_flush');
        session.replace(input('  Kept editing after cancelled exit  '));
        await session.flush();
      });
      expect(
        await tester.runAsync(tester.binding.handleRequestAppExit),
        AppExitResponse.exit,
      );
      expect(db.closeCalls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      final reopened = AppDatabase.forTesting(NativeDatabase(file));
      await tester.runAsync(() async {
        try {
          final owner = EditDrafts(
            db: reopened,
            pin: PinService(reopened.settingsDao),
            deviceId: device,
          );
          final recovery = await owner.openJobLine(
            job,
          ) as RecoverableEdit<JobLineEditSession>;
          final restored = await recovery.resume();
          expect(
            restored.initial.customNameText,
            '  Kept editing after cancelled exit  ',
          );
          expect(restored.initial.neededText, '  not yet numeric  ');
          expect(
            await JobsRepository(reopened, device).listLinesForJob(job),
            isEmpty,
          );
        } finally {
          await reopened.close();
          await directory.delete(recursive: true);
        }
      });
    },
  );
}
