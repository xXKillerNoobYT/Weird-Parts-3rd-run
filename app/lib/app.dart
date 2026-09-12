import 'package:flutter/material.dart';

import 'data/app_database.dart';
import 'features/pin/pin_service.dart';
import 'features/shell/home_shell.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    required this.db,
    required this.pin,
    required this.deviceId,
    required super.child,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      db != old.db || pin != old.pin || deviceId != old.deviceId;
}

class WiredPartsApp extends StatelessWidget {
  const WiredPartsApp({
    required this.db,
    required this.pin,
    required this.deviceId,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      db: db,
      pin: pin,
      deviceId: deviceId,
      child: MaterialApp(
        title: 'Wired Parts',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
          useMaterial3: true,
        ),
        home: const HomeShell(),
      ),
    );
  }
}
