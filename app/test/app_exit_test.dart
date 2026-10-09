import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/sqlite_file.dart';
import 'package:wired_parts/features/backup/backup_codec.dart';
import 'package:wired_parts/features/backup/backup_store.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';

import 'features/backup/backup_test_support.dart';

class _ObservedDatabase extends AppDatabase {
  _ObservedDatabase([File? file])
    : super.forTesting(
        file == null ? NativeDatabase.memory() : NativeDatabase(file),
      );

  _ObservedDatabase.failOnOpen()
    : super.forTesting(
        NativeDatabase.memory(
          setup: (_) => throw StateError('Synthetic reopen failure'),
        ),
      );

  Completer<void>? closeGate;
  var closeCalls = 0;
  var failNextClose = false;
  var closed = false;

  @override
  Future<void> close() async {
    closeCalls++;
    await closeGate?.future;
    if (failNextClose) {
      failNextClose = false;
      throw StateError('Synthetic close failure');
    }
    await super.close();
    closed = true;
  }

  Future<void> cleanUp() async {
    if (!closed) {
      await super.close();
      closed = true;
    }
  }
}

class _ControlledReset extends LocalDataReset {
  _ControlledReset([this.gate]);
  final Completer<void>? gate;
  @override
  Future<void> wipeFiles() async => await gate?.future;
}

Future<String> _mount(
  WidgetTester tester,
  _ObservedDatabase db, {
  LocalDataReset reset = const LocalDataReset(),
  AppDatabase Function()? reopenDatabase,
  Future<void> Function()? beforeRestore,
}) async {
  final deviceId = (await tester.runAsync(db.settingsDao.ensureDeviceId))!;
  await tester.pumpWidget(
    WiredPartsApp(
      db: db,
      pin: PinService(db.settingsDao),
      deviceId: deviceId,
      reset: reset,
      reopenDatabase: reopenDatabase,
      beforeRestore: beforeRestore,
    ),
  );
  await tester.pumpAndSettle();
  return deviceId;
}

void main() {
  setUp(BackupIo.end);
  tearDown(BackupIo.end);

  testWidgets('exit awaits the live database and coalesces repeated requests', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    db.closeGate = Completer<void>();
    var resolved = false;
    final first = tester.binding.handleRequestAppExit().then((value) {
      resolved = true;
      return value;
    });
    final second = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(db.closeCalls, 1);
    expect(resolved, isFalse);
    await expectLater(
      scope.wipeLocalData(),
      throwsA(isA<RestoreBusyException>()),
    );
    await expectLater(
      scope.restoreFromBackup([1], 'invalid-development-archive'),
      throwsA(isA<RestoreBusyException>()),
    );
    db.closeGate!.complete();
    await tester.runAsync(() async {
      expect(await first, AppExitResponse.exit);
      expect(await second, AppExitResponse.exit);
    });
    expect(db.closed, isTrue);
    expect(db.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('exit closes the replacement database after an actual restore', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('wp-exit-after-restore-');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    final documents = Directory(p.join(root.path, 'documents'))..createSync();
    final photos = Directory(p.join(root.path, 'photos'));
    final file = File(p.join(support.path, kSqliteFileName));
    final original = _ObservedDatabase(file);
    _ObservedDatabase? replacement;
    addTearDown(() async {
      await original.cleanUp();
      await replacement?.cleanUp();
      root.deleteSync(recursive: true);
    });
    await _mount(
      tester,
      original,
      reset: LocalDataReset(
        supportDir: support,
        documentsDir: documents,
        photosDir: photos,
      ),
      reopenDatabase: () => replacement = _ObservedDatabase(file),
    );
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final payload = BackupPayload(
      sourceDeviceId: 'synthetic-source',
      createdAt: DateTime.utc(2026, 10, 9),
      sqliteBytes: (await tester.runAsync(
        () => sqliteBytesWithSetting(key: 'marker', value: 'restored'),
      ))!,
      photos: const {},
    );
    await tester.runAsync(() => scope.restoreFromPayload!(payload));
    await tester.pumpAndSettle();
    final live = tester.widget<AppScope>(find.byType(AppScope)).db;
    expect(live, same(replacement));
    expect(original.closed, isTrue);
    expect(original.closeCalls, 1);
    expect(
      await tester.runAsync(() => live.settingsDao.getSetting('marker')),
      'restored',
    );
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.exit,
    );
    expect(replacement!.closed, isTrue);
    expect(replacement!.closeCalls, 1);
    expect(original.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('exit during restore is cancelled without closing storage', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    final gate = Completer<void>();
    await _mount(tester, db, beforeRestore: () => gate.future);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final restore = scope.restoreFromBackup([1], 'invalid-development-archive');
    await tester.pump();
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(db.closeCalls, 0);
    gate.complete();
    await expectLater(restore, throwsA(isA<BackupFormatException>()));
    expect(
      await tester.runAsync(db.settingsDao.ensureDeviceId),
      scope.deviceId,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('exit during backup is cancelled without closing storage', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    expect(BackupIo.tryStart(), isTrue);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
    expect(db.closeCalls, 0);
    BackupIo.end();
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.exit,
    );
    expect(db.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed database close cancels exit and permits a fresh retry', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    db.failNextClose = true;
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.cancel,
    );
    expect(db.closed, isFalse);
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    await expectLater(
      scope.wipeLocalData(),
      throwsA(isA<RestoreBusyException>()),
    );
    await tester.pump();
    expect(
      find.textContaining('Could not close local storage'),
      findsOneWidget,
    );
    expect(
      await tester.runAsync(tester.binding.handleRequestAppExit),
      AppExitResponse.exit,
    );
    expect(db.closed, isTrue);
    expect(db.closeCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('timed out exit retains the one pending shutdown for retry', (
    tester,
  ) async {
    final db = _ObservedDatabase();
    addTearDown(db.cleanUp);
    await _mount(tester, db);
    db.closeGate = Completer<void>();
    final first = tester.binding.handleRequestAppExit();
    await tester.pump(const Duration(seconds: 6));
    expect(await first, AppExitResponse.cancel);
    expect(db.closeCalls, 1);
    final second = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(db.closeCalls, 1);
    db.closeGate!.complete();
    expect(await tester.runAsync(() => second), AppExitResponse.exit);
    expect(db.closeCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final surface in ['route', 'dialog']) {
    testWidgets('shutdown blocks buttons and keyboard on an open $surface', (
      tester,
    ) async {
      final db = _ObservedDatabase();
      addTearDown(db.cleanUp);
      await _mount(tester, db);
      final text = TextEditingController(text: 'original');
      addTearDown(text.dispose);
      var writes = 0;
      final editor = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(key: const ValueKey('synthetic-editor'), controller: text),
          FilledButton(
            onPressed: () => writes++,
            child: const Text('Write synthetic change'),
          ),
        ],
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      if (surface == 'route') {
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => Scaffold(body: editor)),
          ),
        );
      } else {
        unawaited(
          showDialog<void>(
            context: navigator.context,
            builder: (_) => AlertDialog(content: editor),
          ),
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('synthetic-editor')));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      db.closeGate = Completer<void>();
      db.failNextClose = true;
      final exit = tester.binding.handleRequestAppExit();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.tap(
        find.text('Write synthetic change'),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(writes, 0);
      db.closeGate!.complete();
      expect(await tester.runAsync(() => exit), AppExitResponse.cancel);
      await tester.pump();
      await tester.tap(
        find.text('Write synthetic change'),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(writes, 0);
      expect(text.text, 'original');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed replacement initialization closes the unbound database', (
    tester,
  ) async {
    final original = _ObservedDatabase();
    final next = _ObservedDatabase.failOnOpen();
    addTearDown(original.cleanUp);
    addTearDown(next.cleanUp);
    await _mount(
      tester,
      original,
      reset: _ControlledReset(),
      reopenDatabase: () => next,
    );
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    await tester.runAsync(
      () => expectLater(scope.wipeLocalData(), throwsA(isA<StateError>())),
    );
    expect(original.closed, isTrue);
    expect(next.closed, isTrue);
    expect(next.closeCalls, 1);
    expect(BackupIo.isBusy, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unmounted wipe closes the newly opened replacement once', (
    tester,
  ) async {
    final original = _ObservedDatabase();
    final next = _ObservedDatabase();
    addTearDown(original.cleanUp);
    addTearDown(next.cleanUp);
    final gate = Completer<void>();
    await _mount(
      tester,
      original,
      reset: _ControlledReset(gate),
      reopenDatabase: () => next,
    );
    final scope = tester.widget<AppScope>(find.byType(AppScope));
    final wipe = scope.wipeLocalData();
    await tester.pumpAndSettle();
    expect(original.closed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await tester.runAsync(() => wipe);
    expect(next.closed, isTrue);
    expect(next.closeCalls, 1);
    expect(BackupIo.isBusy, isFalse);
  });
}
