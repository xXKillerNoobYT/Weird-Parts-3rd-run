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
import 'features/installation/installation_security.dart';
import 'features/company/company_gate.dart';
import 'features/edit_drafts/edit_drafts.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    required this.db,
    required this.pin,
    required this.deviceId,
    required this.wipeLocalData,
    required this.restoreFromBackup,
    this.restoreFromPayload,
    this.installation,
    this.edits,
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
  final InstallationSecurity? installation;
  final EditDrafts? edits;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      db != old.db ||
      pin != old.pin ||
      deviceId != old.deviceId ||
      edits != old.edits;
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
    this.installation,
    this.enableCompanyBootstrap = false,
    this.pickCompanyRecoveryPath,
    this.pickCompanySourcePath,
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
  final InstallationSecurity? installation;
  final bool enableCompanyBootstrap;
  final Future<String?> Function()? pickCompanyRecoveryPath;
  final Future<String?> Function()? pickCompanySourcePath;

  @override
  State<WiredPartsApp> createState() => _WiredPartsAppState();
}

class _WiredPartsAppState extends State<WiredPartsApp>
    with WidgetsBindingObserver {
  late AppDatabase _db;
  late PinService _pin;
  late String _deviceId;
  late EditDrafts _edits;
  bool _storageCloseStarted = false;
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
    _edits = EditDrafts(
      db: _db,
      pin: _pin,
      deviceId: _deviceId,
      installation: widget.installation,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _closeStorage() {
    return _storageShutdown ??=
        Future<void>.sync(() async {
          await _edits.quiesce(StorageChange.exit);
          _storageCloseStarted = true;
          await _db.close();
        }).catchError((Object error, StackTrace stack) {
          _storageShutdown = null;
          if (!_storageCloseStarted && mounted && _exiting) {
            setState(() => _exiting = false);
          }
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
            if (!_storageCloseStarted && _storageShutdown == null && mounted) {
              setState(() => _exiting = false);
            }
            _messenger.currentState?.showSnackBar(
              SnackBar(
                content: Text(
                  _storageCloseStarted
                      ? 'Could not close local storage. The app remains open; try closing again.'
                      : 'Could not save unfinished edits. The app remains open. Keep editing or try closing again.',
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
      await requireLegacyBusinessStore(_db);
      await widget.reset.preflight();
      await _edits.quiesce(StorageChange.reset);
      InstallationResetIntent? intent;
      try {
        intent = await widget.installation?.prepareReset(_db);
      } catch (_) {
        if (mounted) setState(() => _bindLive(_db, _deviceId));
        rethrow;
      }
      try {
        await _db.close();
      } catch (error, stack) {
        var recovered = false;
        try {
          await _abortReset(_db, intent);
          if (mounted) setState(() => _bindLive(_db, _deviceId));
          recovered = true;
        } catch (_) {}
        if (!recovered && mounted) setState(() => _exiting = true);
        Error.throwWithStackTrace(error, stack);
      }
      try {
        if (intent != null) await widget.installation!.validateReset(intent);
        await widget.reset.wipeFiles();
      } catch (error, stack) {
        var recovered = false;
        if (error is LocalDataResetNoEffectFailure) {
          AppDatabase? next;
          try {
            final store = BackupStore(supportDir: widget.reset.supportDir);
            if (await store.hasInterruptedRestore() ||
                !await (await store.sqliteFile()).exists()) {
              throw StateError(
                'Storage cannot safely reopen for reset recovery',
              );
            }
            next = widget.reopenDatabase?.call() ?? AppDatabase();
            await _abortReset(next, intent);
            if (mounted) {
              setState(() => _bindLive(next!, _deviceId));
              recovered = true;
            }
          } catch (_) {
          } finally {
            if (!recovered) {
              try {
                await next?.close();
              } catch (_) {}
            }
          }
        }
        if (!recovered && mounted) setState(() => _exiting = true);
        if (error is LocalDataResetNoEffectFailure) {
          Error.throwWithStackTrace(error.cause, error.stackTrace);
        }
        Error.throwWithStackTrace(error, stack);
      }
      try {
        await _reopen(resetIntent: intent);
      } catch (error, stack) {
        if (mounted) setState(() => _exiting = true);
        Error.throwWithStackTrace(error, stack);
      }
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
    var quiesced = false;
    AppDatabase? next;
    InstallationRestoreIntent? intent;
    var replacementReturned = false;
    try {
      await widget.beforeRestore?.call();
      final payload = await load();
      backupSqliteSchemaVersion(payload.sqliteBytes);
      await requireLegacyBusinessStore(_db);
      await requireLegacyBusinessPayload(payload);
      final localDeviceProfile = await _db
          .select(_db.deviceProfiles)
          .getSingleOrNull();
      if (localDeviceProfile == null || localDeviceProfile.id != keepDeviceId) {
        throw StateError(
          'Local device profile does not match this installation',
        );
      }
      await _edits.quiesce(StorageChange.replacement);
      quiesced = true;
      intent = await widget.installation?.prepareBusinessRestore(_db);
      await _db.close();
      closed = true;
      await BackupStore(
        supportDir: widget.reset.supportDir,
        photosDir: widget.reset.photosDir,
        failDeviceProfileWrite: widget.failDeviceProfileWrite,
      ).replaceWithPayload(
        payload: payload,
        localDeviceProfile: localDeviceProfile,
        localInstallationBinding: intent?.binding,
        reset: widget.reset,
      );
      replacementReturned = true;
      next = widget.reopenDatabase?.call() ?? AppDatabase();
      if (widget.installation case final installation?) {
        if (installation.readiness != InstallationReadiness.unsupported) {
          await installation.reconcile(next);
          if (installation.readiness != InstallationReadiness.ready) {
            throw StateError('Restored installation binding needs recovery');
          }
        }
      }
      try {
        await next.partsDao.relativizeAbsolutePhotoPaths();
        await afterOpen(next, payload);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _bindLive(next!, keepDeviceId));
    } catch (e) {
      if (!closed && quiesced) {
        var retainedStorageReady = false;
        final installation = widget.installation;
        if (intent != null ||
            installation == null ||
            installation.readiness == InstallationReadiness.unsupported) {
          try {
            if (intent != null) {
              await installation!.abortBusinessRestore(_db, intent);
            }
            await requireLegacyBusinessStore(_db);
            retainedStorageReady = true;
          } catch (_) {}
        }
        if (mounted && retainedStorageReady) {
          setState(() => _bindLive(_db, keepDeviceId));
        }
      }
      if (closed) {
        next ??= widget.reopenDatabase?.call() ?? AppDatabase();
        if (!replacementReturned && intent != null) {
          try {
            if (!await BackupStore(supportDir: widget.reset.supportDir)
                .hasInterruptedRestore()) {
              await widget.installation!.abortBusinessRestore(next, intent);
            }
          } catch (_) {
            // An uncertain replacement keeps its pending security intent.
          }
        }
        await widget.installation?.start(next);
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
    _edits = EditDrafts(
      db: next,
      pin: _pin,
      deviceId: deviceId,
      installation: widget.installation,
    );
    _storageShutdown = null;
    _storageCloseStarted = false;
    _generation++;
  }

  Future<void> _abortReset(
    AppDatabase db,
    InstallationResetIntent? intent,
  ) async {
    if (intent != null) {
      await widget.installation!.abortReset(db, intent);
    } else {
      await requireLegacyBusinessStore(db);
    }
  }

  Future<void> _reopen({InstallationResetIntent? resetIntent}) async {
    final next = widget.reopenDatabase?.call() ?? AppDatabase();
    var bound = false;
    try {
      if (resetIntent != null) {
        await widget.installation!.completeReset(next, resetIntent);
      } else {
        await widget.installation?.start(next);
      }
      final deviceId = await next.settingsDao.ensureDeviceId();
      if (mounted) {
        setState(() => _bindLive(next, deviceId));
        bound = true;
      }
    } catch (error, stack) {
      try {
        await next.close();
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
    if (!bound) await next.close();
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
      installation: widget.installation,
      edits: _edits,
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
            child: Column(
              children: [
                if (widget.installation?.readiness ==
                        InstallationReadiness.needsRecovery ||
                    widget.installation?.readiness ==
                        InstallationReadiness.unavailable)
                  Material(
                    color: Colors.amber,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          widget.installation?.readiness ==
                                  InstallationReadiness.unavailable
                              ? 'Installation security is unavailable. Company operations, restore and reset are paused.'
                              : 'Installation identity needs recovery. Company operations are unavailable.',
                        ),
                      ),
                    ),
                  ),
                Expanded(child: navigator ?? const SizedBox.shrink()),
              ],
            ),
          ),
        ),
        home: widget.enableCompanyBootstrap && widget.installation != null
            ? CompanyBootstrapGate(
                key: ValueKey(_generation),
                db: _db,
                installation: widget.installation!,
                supportDirectory: widget.reset.supportDir,
                photosDirectory: widget.reset.photosDir,
                pickRecoveryPath: widget.pickCompanyRecoveryPath,
                pickSourcePath: widget.pickCompanySourcePath,
              )
            : HomeShell(key: ValueKey(_generation)),
      ),
    );
  }
}
