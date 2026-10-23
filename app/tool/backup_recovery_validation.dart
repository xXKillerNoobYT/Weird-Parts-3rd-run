import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

import 'backup_recovery_scenario.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('RECOVERY_RUN');
  const actionName = String.fromEnvironment(
    'RECOVERY_ACTION',
    defaultValue: 'auto',
  );
  final action = actionName == 'auto'
      ? RecoveryScenario.actionForRun(run)
      : RecoveryAction.values.singleWhere((value) => value.name == actionName);
  final scenario = RecoveryScenario.open(run: run, action: action);
  PathProviderPlatform.instance = scenario.receiver;
  Map<String, Object?>? source;
  if (action == RecoveryAction.exercise) {
    await scenario.seed();
    source = await scenario.export();
  }
  final db = AppDatabase();
  final deviceId = await db.settingsDao.ensureDeviceId();
  final appKey = GlobalKey();
  runApp(
    WiredPartsApp(
      key: appKey,
      db: db,
      pin: PinService(db.settingsDao),
      deviceId: deviceId,
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  AppScope scope() {
    AppScope? found;
    appKey.currentContext!.visitChildElements((element) {
      if (element.widget is AppScope) found = element.widget as AppScope;
    });
    return found ?? (throw StateError('Production AppScope is missing'));
  }

  try {
    if (action == RecoveryAction.exercise) {
      await scenario.exercise(
        scope: scope,
        settle: () => WidgetsBinding.instance.endOfFrame,
        sourceReceipt: source!,
      );
    } else {
      await scenario.restart(scope().db);
    }
    debugPrint('RECOVERY ${action.name} PASS: ${scenario.receiver.root.path}');
  } catch (e) {
    exitCode = 1;
    debugPrint('RECOVERY ${action.name} FAIL: $e');
    rethrow;
  }
}
