import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'data/app_database.dart';
import 'features/backup/backup_codec.dart';
import 'features/backup/backup_store.dart';
import 'features/nearby/nearby_protocol.dart';
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
    this.restoreFromPayload,
    required super.child,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;
  final Future<void> Function() wipeLocalData;
  final Future<void> Function(List<int> fileBytes, String password)
  restoreFromBackup;
  final Future<void> Function(BackupPayload payload)? restoreFromPayload;

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
    this.beforeRestore,
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

  /// Test hook: after `_wiping` is set, before decrypt. Production is a no-op.
  final Future<void> Function()? beforeRestore;

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
    if (_wiping) {
      throw const RestoreBusyException();
    }
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
    await _applyShopPayload(
      load: () => BackupCodec().decrypt(
        Uint8List.fromList(fileBytes),
        password,
      ),
      afterOpen: (next, payload) async {
        await next.settingsDao.setSetting(
          kLastBackupAtKey,
          payload.createdAt.toUtc().toIso8601String(),
        );
        await next.settingsDao.setSetting(
          kLastBackupSourceKey,
          payload.sourceDeviceId,
        );
      },
    );
  }

  Future<void> _restoreFromPayload(BackupPayload payload) async {
    await _applyShopPayload(
      load: () async => payload,
      afterOpen: (next, loaded) async {
        await next.settingsDao.setSetting(
          kLastNearbyAtKey,
          loaded.createdAt.toUtc().toIso8601String(),
        );
        await next.settingsDao.setSetting(
          kLastNearbyPeerKey,
          loaded.sourceDeviceId,
        );
      },
    );
  }

  Future<void> _applyShopPayload({
    required Future<BackupPayload> Function() load,
    required Future<void> Function(AppDatabase next, BackupPayload payload)
    afterOpen,
  }) async {
    if (_wiping) {
      throw const RestoreBusyException();
    }
    _wiping = true;
    final keepDeviceId = _deviceId;
    var keepName = 'This device';
    try {
      keepName = await _db.settingsDao.deviceDisplayName();
    } catch (_) {}
    var closed = false;
    AppDatabase? next;
    try {
      await widget.beforeRestore?.call();
      final payload = await load();
      await _db.close();
      closed = true;
      await BackupStore(
        supportDir: widget.reset.supportDir,
        photosDir: widget.reset.photosDir,
      ).replaceWithPayload(payload: payload, reset: widget.reset);
      next = widget.reopenDatabase?.call() ?? AppDatabase();
      await _keepLocalDeviceIdBestEffort(
        next,
        keepDeviceId,
        displayName: keepName,
      );
      try {
        await next.partsDao.relativizeAbsolutePhotoPaths();
        await afterOpen(next, payload);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _bindLive(next!, keepDeviceId));
    } catch (e) {
      if (closed) {
        next ??= widget.reopenDatabase?.call() ?? AppDatabase();
        await _keepLocalDeviceIdBestEffort(
          next,
          keepDeviceId,
          displayName: keepName,
        );
        if (mounted) {
          setState(() => _bindLive(next!, keepDeviceId));
        }
      }
      rethrow;
    } finally {
      _wiping = false;
    }
  }

  Future<void> _keepLocalDeviceIdBestEffort(
    AppDatabase next,
    String id, {
    String? displayName,
  }) async {
    Future<void> once() {
      final hook = widget.keepLocalDeviceId;
      if (hook != null) return hook(next, id);
      return next.settingsDao.keepLocalDeviceId(id, displayName: displayName);
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
      restoreFromPayload: _restoreFromPayload,
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
