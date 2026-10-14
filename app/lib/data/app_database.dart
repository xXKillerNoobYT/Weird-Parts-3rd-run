import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

import 'daos/jobs_dao.dart';
import 'daos/parts_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/taxonomy_dao.dart';
import 'tables/app_settings.dart';
import 'tables/device_profile.dart';
import 'sqlite_file.dart';
import 'tables/jobs.dart';
import 'tables/parts.dart';
import 'tables/taxonomy.dart';

part 'app_database.g.dart';

const kAppSchemaVersion = 2;

@DriftDatabase(
  tables: [
    DeviceProfiles,
    AppSettings,
    Categories,
    Styles,
    Types,
    Devices,
    Brands,
    Suppliers,
    Parts,
    PartDevices,
    BrandVersions,
    SupplierListings,
    Jobs,
    JobLines,
    OrderSplits,
  ],
  daos: [SettingsDao, TaxonomyDao, PartsDao, JobsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : this._(_DatabaseWorkerLifetime());

  AppDatabase._(_DatabaseWorkerLifetime lifetime)
    : _waitForWorkerExit = lifetime.waitForExit,
      super(_open(lifetime));

  AppDatabase.forTesting(
    QueryExecutor executor, {
    Future<void> Function()? waitForWorkerExit,
  }) : this._forTesting(executor, waitForWorkerExit);

  AppDatabase._forTesting(super.e, this._waitForWorkerExit);

  final Future<void> Function()? _waitForWorkerExit;
  Future<void>? _closeFuture;

  @override
  Future<void> close() {
    // Connections without an owned worker retain Drift's close semantics.
    if (_waitForWorkerExit == null) return super.close();
    return _closeFuture ??= _closeOwnedWorker().catchError((
      Object error,
      StackTrace stack,
    ) {
      _closeFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _closeOwnedWorker() async {
    await super.close();
    // Drift's remote-close acknowledgment can precede SQLite disposal.
    // Engine teardown must also await the actual owned isolate exit.
    await _waitForWorkerExit?.call();
  }

  @override
  int get schemaVersion => kAppSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(brandVersions, brandVersions.varianceName);
        await m.addColumn(brandVersions, brandVersions.isMain);
      }
    },
  );
}

LazyDatabase _open(_DatabaseWorkerLifetime lifetime) {
  return LazyDatabase(() async {
    // Prefer Application Support over Documents: OneDrive-backed Documents
    // on Windows can fail SQLite open (SQLITE_CANTOPEN / code 14).
    final support = await getApplicationSupportDirectory();
    Directory? documents;
    try {
      documents = await getApplicationDocumentsDirectory();
    } on MissingPlatformDirectoryException {
      documents = null;
    }
    final file = resolveSqliteFile(
      supportDir: support,
      documentsDir: documents,
    );
    return NativeDatabase.createInBackground(
      file,
      readPool: 0,
      isolateSetup: _registerWorkerExit(lifetime.prepareExitSignal()),
    );
  });
}

// This factory captures only a SendPort, never the unsendable owner/ReceivePort.
void Function() _registerWorkerExit(SendPort port) =>
    () => Isolate.current.addOnExitListener(port);

class _DatabaseWorkerLifetime {
  Future<void>? _exited;

  SendPort prepareExitSignal() {
    final port = ReceivePort('Wired Parts database worker exit');
    _exited = port.first.then<void>((_) {}).whenComplete(port.close);
    return port.sendPort;
  }

  Future<void> waitForExit() async {
    // Never-opened LazyDatabase instances have no worker and no receive port.
    await _exited;
  }
}
