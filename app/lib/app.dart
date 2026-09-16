import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'data/app_database.dart';
import 'features/backup/backup_codec.dart';
import 'features/backup/backup_store.dart';
import 'features/pin/pin_service.dart';
import 'features/reset/local_data_reset.dart';
import 'features/shell/home_shell.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    required this.db,
    required this.pin,
    required this.deviceId,
    required this.wipeLocalData,
    required this.restoreFromBackup,
    required super.child,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;
  final Future<void> Function() wipeLocalData;
  final Future<void> Function(List<int> fileBytes, String password)
  restoreFromBackup;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      db != old.db || pin != old.pin || deviceId != old.deviceId;
}

class RestoreBusyException implements Exception {
  const RestoreBusyException();
  @override
  String toString() => 'A restore or wipe is already in progress';
}

class WiredPartsApp extends StatefulWidget {
  const WiredPartsApp({
    required this.db,
    required this.pin,
    required this.deviceId,
    this.reopenDatabase,
    this.reset = const LocalDataReset(),
    this.keepLocalDeviceId,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;
  final AppDatabase Function()? reopenDatabase;
  final LocalDataReset reset;

  /// Test hook: identity write after a committed swap. Production uses
  /// [SettingsDao.keepLocalDeviceId]. Failures are retried then ignored.
  final Future<void> Function(AppDatabase db, String deviceId)?
  keepLocalDeviceId;

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
    if (!BackupIo.tryStart()) {
      throw const RestoreBusyException();
    }
    _wiping = true;
    try {
      await _db.close();
      await widget.reset.wipeFiles();
      await _reopen();
    } finally {
      _wiping = false;
      BackupIo.end();
    }
  }

  Future<void> _restoreFromBackup(List<int> fileBytes, String password) async {
    if (_wiping) {
      throw const RestoreBusyException();
    }
    _wiping = true;
    final keepDeviceId = _deviceId;
    var closed = false;
    AppDatabase? next;
    try {
      final payload = await BackupCodec().decrypt(
        Uint8List.fromList(fileBytes),
        password,
      );
      await _db.close();
      closed = true;
      await BackupStore(
        supportDir: widget.reset.supportDir,
        photosDir: widget.reset.photosDir,
      ).replaceWithPayload(payload: payload, reset: widget.reset);
      next = widget.reopenDatabase?.call() ?? AppDatabase();
      // Swap already committed; rollback copies are gone. Identity and
      // stamps must not report Restore failed.
      await _keepLocalDeviceIdBestEffort(next, keepDeviceId);
      try {
        await next.partsDao.relativizeAbsolutePhotoPaths();
        await next.settingsDao.setSetting(
          kLastBackupAtKey,
          payload.createdAt.toUtc().toIso8601String(),
        );
        await next.settingsDao.setSetting(
          kLastBackupSourceKey,
          payload.sourceDeviceId,
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() => _bindLive(next!, keepDeviceId));
    } catch (e) {
      if (closed) {
        next ??= widget.reopenDatabase?.call() ?? AppDatabase();
        await _keepLocalDeviceIdBestEffort(next, keepDeviceId);
        if (mounted) {
          setState(() => _bindLive(next!, keepDeviceId));
        }
      }
      rethrow;
    } finally {
      _wiping = false;
    }
  }

  Future<void> _keepLocalDeviceIdBestEffort(AppDatabase next, String id) async {
    Future<void> once() {
      final hook = widget.keepLocalDeviceId;
      if (hook != null) return hook(next, id);
      return next.settingsDao.keepLocalDeviceId(id);
    }

    try {
      await once();
    } catch (_) {
      try {
        await once();
      } catch (_) {}
    }
  }

  void _bindLive(AppDatabase next, String deviceId) {
    _db = next;
    _pin = PinService(next.settingsDao);
    _deviceId = deviceId;
    _generation++;
  }

  Future<void> _reopen() async {
    final next = widget.reopenDatabase?.call() ?? AppDatabase();
    final deviceId = await next.settingsDao.ensureDeviceId();
    if (!mounted) return;
    setState(() => _bindLive(next, deviceId));
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      db: _db,
      pin: _pin,
      deviceId: _deviceId,
      wipeLocalData: _wipeLocalData,
      restoreFromBackup: _restoreFromBackup,
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
