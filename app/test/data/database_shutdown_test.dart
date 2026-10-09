import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';

import '../../tool/backup_recovery_scenario.dart';

void main() {
  test(
    'remote close acknowledgment does not bypass pending worker exit',
    () async {
      final enteredWorkerWait = Completer<void>();
      final workerExited = Completer<void>();
      final db = AppDatabase.forTesting(
        NativeDatabase.memory(),
        waitForWorkerExit: () {
          enteredWorkerWait.complete();
          return workerExited.future;
        },
      );
      await db.settingsDao.ensureDeviceId();
      var closeCompleted = false;
      final first = db.close();
      final second = db.close();
      first.then((_) => closeCompleted = true);
      await enteredWorkerWait.future;
      expect(closeCompleted, isFalse);
      expect(identical(first, second), isTrue);
      workerExited.complete();
      await Future.wait([first, second]);
      expect(closeCompleted, isTrue);
    },
  );

  test('unopened production database closes without opening storage', () async {
    final db = AppDatabase();
    await db.close();
    await db.close();
  });

  test(
    'production background worker stops and preserves isolated records',
    () async {
      final temp = Directory.systemTemp.createTempSync('wp-worker-shutdown-');
      final scenario = RecoveryScenario.open(
        run: 'worker-shutdown',
        action: RecoveryAction.exercise,
        temporaryDirectory: temp,
      );
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = scenario.receiver;
      final db = AppDatabase();
      try {
        final id = await db.settingsDao.ensureDeviceId();
        await db.jobsDao.insertJob(
          id: 'offline-before-exit',
          name: 'Synthetic worker shutdown',
          deviceId: id,
        );
        await db.close().timeout(const Duration(seconds: 5));
        final reopened = AppDatabase.forTesting(
          NativeDatabase(
            File(p.join(scenario.receiver.support.path, kSqliteFileName)),
          ),
        );
        try {
          expect(await reopened.settingsDao.ensureDeviceId(), id);
          expect(
            (await reopened.jobsDao.listActiveJobs()).single.id,
            'offline-before-exit',
          );
        } finally {
          await reopened.close();
        }
      } finally {
        await db.close();
        PathProviderPlatform.instance = previousPaths;
        scenario.close();
        temp.deleteSync(recursive: true);
      }
    },
  );
}
