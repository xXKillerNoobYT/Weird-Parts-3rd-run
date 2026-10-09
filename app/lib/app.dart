import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

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
    this.failDeviceProfileWrite = false,
    this.beforeRestore,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;
  final AppDatabase Function()? reopenDatabase;
  final LocalDataReset reset;

  final bool failDeviceProfileWrite;

  /// Test hook: after `_wiping` is set, before decrypt. Production is a no-op.
  final Future<void> Function()? beforeRestore;

  @override
  State<WiredPartsApp> createState() => _WiredPartsAppState();
}

class _WiredPartsAppState extends State<WiredPartsApp>
    with WidgetsBindingObserver {
  late AppDatabase _db;
  late PinService _pin;
  late String _deviceId;
  var _generation = 0;
  var _wiping = false;
  var _exiting = false;
  Future<AppExitResponse>? _exitRequest;
  Future<void>? _storageShutdown;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _db = widget.db;
    _pin = widget.pin;
    _deviceId = widget.deviceId;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _closeStorage() {
    return _storageShutdown ??= Future<void>.sync(_db.close)
        .catchError((Object error, StackTrace stack) {
          _storageShutdown = null;
          Error.throwWithStackTrace(error, stack);
        });
  }

  @override
  Future<AppExitResponse> didRequestAppExit() {
    // A replacement/export must finish before its storage can be closed.
    if (_wiping || BackupIo.isBusy) {
      return Future.value(AppExitResponse.cancel);
    }
    if (_exitRequest != null) return _exitRequest!;
    setState(() => _exiting = true);
    _exitRequest = _closeStorage()
        .timeout(const Duration(seconds: 5))
        .then<AppExitResponse>(
          (_) => AppExitResponse.exit,
          onError: (Object error, StackTrace stack) {
            _exitRequest = null;
            // Storage may already be closed. Keep editing blocked, and retry
            // the same pending shutdown on the next ordinary exit request.
            _messenger.currentState?.showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not close local storage. The app remains open; try closing again.',
                ),
              ),
            );
            return AppExitResponse.cancel;
          },
        );
    return _exitRequest!;
  }

  Future<void> _wipeLocalData() async {
    if (_wiping || _exiting) {
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
      load: () =>
          BackupCodec().decrypt(Uint8List.fromList(fileBytes), password),
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
    if (_wiping || _exiting) {
      throw const RestoreBusyException();
    }
    _wiping = true;
    final keepDeviceId = _deviceId;
    var closed = false;
    AppDatabase? next;
    try {
      await widget.beforeRestore?.call();
      final payload = await load();
      backupSqliteSchemaVersion(payload.sqliteBytes);
      final localDeviceProfile = await _db
          .select(_db.deviceProfiles)
          .getSingleOrNull();
      if (localDeviceProfile == null || localDeviceProfile.id != keepDeviceId) {
        throw StateError(
          'Local device profile does not match this installation',
        );
      }
      await _db.close();
      closed = true;
      await BackupStore(
        supportDir: widget.reset.supportDir,
        photosDir: widget.reset.photosDir,
        failDeviceProfileWrite: widget.failDeviceProfileWrite,
      ).replaceWithPayload(
        payload: payload,
        localDeviceProfile: localDeviceProfile,
        reset: widget.reset,
      );
      next = widget.reopenDatabase?.call() ?? AppDatabase();
      try {
        await next.partsDao.relativizeAbsolutePhotoPaths();
        await afterOpen(next, payload);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _bindLive(next!, keepDeviceId));
    } catch (e) {
      if (closed) {
        next ??= widget.reopenDatabase?.call() ?? AppDatabase();
        if (mounted) {
          setState(() => _bindLive(next!, keepDeviceId));
        }
      }
      rethrow;
    } finally {
      try {
        if (!mounted) await next?.close();
      } finally {
        _wiping = false;
      }
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
    var bound = false;
    try {
      final deviceId = await next.settingsDao.ensureDeviceId();
      if (!mounted) return;
      setState(() => _bindLive(next, deviceId));
      bound = true;
    } finally {
      if (!bound) await next.close();
    }
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
        scaffoldMessengerKey: _messenger,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
          useMaterial3: true,
        ),
        builder: (context, navigator) => AbsorbPointer(
          absorbing: _exiting,
          child: ExcludeFocus(
            excluding: _exiting,
            child: navigator ?? const SizedBox.shrink(),
          ),
        ),
        home: HomeShell(key: ValueKey(_generation)),
      ),
    );
  }
}
