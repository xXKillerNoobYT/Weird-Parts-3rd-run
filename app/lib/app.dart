import 'package:flutter/material.dart';

import 'data/app_database.dart';
import 'features/pin/pin_service.dart';
import 'features/reset/local_data_reset.dart';
import 'features/shell/home_shell.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    required this.db,
    required this.pin,
    required this.deviceId,
    required this.wipeLocalData,
    required super.child,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;
  final Future<void> Function() wipeLocalData;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      db != old.db || pin != old.pin || deviceId != old.deviceId;
}

class WiredPartsApp extends StatefulWidget {
  const WiredPartsApp({
    required this.db,
    required this.pin,
    required this.deviceId,
    this.reopenDatabase,
    this.reset = const LocalDataReset(),
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;
  final AppDatabase Function()? reopenDatabase;
  final LocalDataReset reset;

  @override
  State<WiredPartsApp> createState() => _WiredPartsAppState();
}

class _WiredPartsAppState extends State<WiredPartsApp> {
  late AppDatabase _db;
  late PinService _pin;
  late String _deviceId;
  var _generation = 0;
  var _wiping = false;

  @override
  void initState() {
    super.initState();
    _db = widget.db;
    _pin = widget.pin;
    _deviceId = widget.deviceId;
  }

  Future<void> _wipeLocalData() async {
    if (_wiping) return;
    _wiping = true;
    try {
      await _db.close();
      await widget.reset.wipeFiles();
      final next = widget.reopenDatabase?.call() ?? AppDatabase();
      final deviceId = await next.settingsDao.ensureDeviceId();
      if (!mounted) return;
      setState(() {
        _db = next;
        _pin = PinService(next.settingsDao);
        _deviceId = deviceId;
        _generation++;
      });
    } finally {
      _wiping = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      db: _db,
      pin: _pin,
      deviceId: _deviceId,
      wipeLocalData: _wipeLocalData,
      child: MaterialApp(
        title: 'Wired Parts',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
          useMaterial3: true,
        ),
        home: HomeShell(key: ValueKey(_generation)),
      ),
    );
  }
}
