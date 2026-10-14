import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

const company = '10000000-0000-4000-8000-000000000001';
const shop = '10000000-0000-4000-8000-000000000002';
const job = '10000000-0000-4000-8000-000000000003';
const line = '10000000-0000-4000-8000-000000000004';
const user = '10000000-0000-4000-8000-000000000005';
const secondUser = '10000000-0000-4000-8000-000000000006';
const part = '10000000-0000-4000-8000-000000000007';
const version = '10000000-0000-4000-8000-000000000008';
const brand = '10000000-0000-4000-8000-000000000009';
const legacyDevice = '10000000-0000-4000-8000-000000000010';

String canonical(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(v[key])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

String digest(Object? value) =>
    hashes.sha256.convert(utf8.encode(canonical(value))).toString();

class FixtureSecureStore implements InstallationSecureStore {
  FixtureSecureStore({this.delegate});
  final InstallationSecureStore? delegate;
  final states = <String, ProtectedInstallationState>{};
  bool failBeforeWrite = false;
  bool loseWriteReply = false;
  bool failClear = false;
  int maximumBytes = 0;
  @override
  Future<ProtectedInstallationState?> readState(String namespace) async {
    if (delegate != null) {
      final actual = await delegate!.readState(namespace);
      if (actual == null) {
        states.remove(namespace);
      } else {
        states[namespace] = actual;
      }
    }
    return states[namespace];
  }

  @override
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  }) async {
    if ((await readState(namespace))?.revision != expectedRevision) {
      throw StateError('fixture CAS conflict');
    }
    maximumBytes = maximumBytes > bytes.length ? maximumBytes : bytes.length;
    if (bytes.length > kInstallationStateLimit) {
      throw StateError('fixture protected capacity');
    }
    final next = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final current = states[namespace] == null
        ? null
        : jsonDecode(utf8.decode(states[namespace]!.bytes))
              as Map<String, dynamic>;
    if (failBeforeWrite ||
        (failClear &&
            current?['pendingCommand'] != null &&
            next['pendingCommand'] == null)) {
      failBeforeWrite = false;
      throw StateError('fixture protected write failure');
    }
    if (delegate != null) {
      await delegate!.compareAndSwapState(
        namespace,
        expectedRevision: expectedRevision,
        nextRevision: nextRevision,
        bytes: bytes,
      );
      final actual = await readState(namespace);
      if (actual?.revision != nextRevision ||
          base64Encode(actual!.bytes) != base64Encode(bytes)) {
        throw StateError('native fixture CAS readback differs');
      }
    } else {
      states[namespace] = ProtectedInstallationState(nextRevision, bytes);
    }
    if (loseWriteReply) {
      loseWriteReply = false;
      throw StateError('fixture lost CAS response after persistence');
    }
    return nextRevision;
  }
}

/// Uses Drift's existing query interceptor only to pause real SQLite boundaries
/// for deterministic race regressions. Production has no corresponding hook.
class FixtureQueryInterceptor extends QueryInterceptor {
  Future<void> Function(String statement)? beforeSelect;
  Future<void> Function(String statement)? afterSelect;
  Future<void> Function(String statement)? beforeCustom;
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await beforeCustom?.call(statement);
    await executor.runCustom(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await beforeSelect?.call(statement);
    final rows = await executor.runSelect(statement, args);
    await afterSelect?.call(statement);
    return rows;
  }
}

enum FixtureBootstrapStage { seed, installation, facts }

final class FixtureBootstrapFailure implements Exception {
  const FixtureBootstrapFailure({
    required this.stage,
    required this.databasesClosed,
    this.storeIndex,
    this.readiness,
  });
  final FixtureBootstrapStage stage;
  final int? storeIndex;
  final InstallationReadiness? readiness;
  final bool databasesClosed;
  @override
  String toString() => 'Synthetic fixture bootstrap failed (${stage.name})';
}

class AtomicFixture {
  AtomicFixture._(
    this.directory,
    this.databases,
    this.secureStores,
    this.installations,
    this.devices,
    this.grants,
    this.facts,
    this.rootPair,
    this.files,
  );
  final Directory directory;
  final List<AppDatabase> databases;
  final List<FixtureSecureStore> secureStores;
  final List<InstallationSecurity> installations;
  final List<String> devices;
  final List<String> grants;
  Map<String, Object?> facts;
  final SimpleKeyPair rootPair;
  final List<File> files;

  static Future<AtomicFixture> create({
    Directory? ownedDirectory,
    List<File>? databaseFiles,
    InstallationSecureStore? nativeStore,
    String Function(int)? namespaceForStore,
    QueryExecutor Function(File)? databaseExecutor,
  }) async {
    final directory =
        ownedDirectory ??
        await Directory.systemTemp.createTemp('wp-atomic-command-');
    final files =
        databaseFiles ??
        [for (var i = 0; i < 2; i++) File(p.join(directory.path, '$i.db'))];
    if (files.length != 2 ||
        files.any((f) => f.existsSync()) ||
        (nativeStore != null &&
            (ownedDirectory == null || namespaceForStore == null))) {
      throw StateError(
        'fixture requires fresh owned stores and native namespaces',
      );
    }
    final namespaces = [
      for (var i = 0; i < 2; i++)
        namespaceForStore?.call(i) ?? 'synthetic.atomic-$i',
    ];
    for (final namespace in namespaces) {
      if (!namespace.startsWith('synthetic.') ||
          (nativeStore != null &&
              await nativeStore.readState(namespace) != null)) {
        throw StateError('fixture namespace is not fresh synthetic state');
      }
    }
    final acquired = <AppDatabase>[];
    var stage = FixtureBootstrapStage.seed;
    int? storeIndex;
    InstallationReadiness? readiness;
    AppDatabase open(int i) {
      final db = AppDatabase.forTesting(
        databaseExecutor?.call(files[i]) ?? NativeDatabase(files[i]),
      );
      acquired.add(db);
      return db;
    }

    try {
      final a = open(0);
      final now = DateTime.utc(2026, 1, 1);
      await a
          .into(a.jobs)
          .insert(
            JobsCompanion.insert(
              id: job,
              name: 'Synthetic job',
              originDeviceId: legacyDevice,
              createdAt: now,
              modifiedAt: now,
            ),
          );
      await a
          .into(a.jobLines)
          .insert(
            JobLinesCompanion.insert(
              id: line,
              jobId: job,
              customName: const Value('Synthetic line'),
              customNotes: const Value('Old custom note'),
              neededQty: 5,
              shopPullQty: const Value(1),
              uom: const Value('ea'),
              notes: const Value('Old note'),
              originDeviceId: legacyDevice,
              createdAt: now,
              modifiedAt: now,
            ),
          );
      await a
          .into(a.parts)
          .insert(
            PartsCompanion.insert(
              id: part,
              name: 'Synthetic part',
              originDeviceId: legacyDevice,
              createdAt: now,
              modifiedAt: now,
            ),
          );
      await a
          .into(a.brands)
          .insert(
            BrandsCompanion.insert(
              id: brand,
              name: 'Synthetic brand',
              originDeviceId: legacyDevice,
              createdAt: now,
              modifiedAt: now,
            ),
          );
      await a
          .into(a.brandVersions)
          .insert(
            BrandVersionsCompanion.insert(
              id: version,
              partId: part,
              brandId: brand,
              mpn: 'Synthetic variance',
              originDeviceId: legacyDevice,
              createdAt: now,
              modifiedAt: now,
            ),
          );
      await a.close();
      acquired.remove(a);
      await files[0].copy(files[1].path);
      final databases = [open(0), open(1)];
      final stores = [
        FixtureSecureStore(delegate: nativeStore),
        FixtureSecureStore(delegate: nativeStore),
      ];
      final installs = List.generate(
        2,
        (i) => InstallationSecurity(store: stores[i], namespace: namespaces[i]),
      );
      for (var i = 0; i < 2; i++) {
        stage = FixtureBootstrapStage.installation;
        storeIndex = i;
        await installs[i].start(databases[i]);
        readiness = installs[i].readiness;
        if (readiness != InstallationReadiness.ready ||
            installs[i].identity == null ||
            stores[i].states[namespaces[i]] == null) {
          throw StateError('Synthetic installation did not become ready');
        }
      }
      stage = FixtureBootstrapStage.facts;
      storeIndex = null;
      readiness = null;
      final devices = List.generate(2, (_) => const Uuid().v4());
      final grants = List.generate(2, (_) => const Uuid().v4());
      final rootPair = await Ed25519().newKeyPair();
      final baseline = jobLineLegacyBaselineCommitment(
        companyId: company,
        shopId: shop,
        row: await databases[0].select(databases[0].jobLines).getSingle(),
      );
      final facts = <String, Object?>{
        'v': 1,
        'company': company,
        'authority': 1,
        'policy': 'localContinuity',
        'devices': [
          for (var i = 0; i < 2; i++)
            {
              'id': devices[i],
              'installation': installs[i].identity!.id.value,
              'generation': installs[i].identity!.generation.value,
              'key': base64Encode(installs[i].identity!.publicKey),
              'grant': grants[i],
              'version': 1,
              'revoked': false,
              'shops': [shop],
              'capabilities': ['patchJobLine', 'deleteJobLine'],
            },
        ],
        'users': [
          for (final id in [user, secondUser])
            {
              'id': id,
              'credential': 1,
              'permission': 1,
              'revoked': false,
              'shops': [shop],
              'capabilities': ['patchJobLine', 'deleteJobLine'],
            },
        ],
        'entities': [
          {'kind': 'jobLine', 'id': line, 'shop': shop, 'baseline': baseline},
          {'kind': 'job', 'id': job, 'shop': shop},
          {'kind': 'part', 'id': part},
          {'kind': 'brandVersion', 'id': version},
        ],
      };
      final fixture = AtomicFixture._(
        directory,
        databases,
        stores,
        installs,
        devices,
        grants,
        facts,
        rootPair,
        files,
      );
      await fixture.publishFacts();
      return fixture;
    } catch (_) {
      var closed = true;
      for (final db in acquired.reversed) {
        try {
          await db.close();
        } catch (_) {
          closed = false;
        }
      }
      throw FixtureBootstrapFailure(
        stage: stage,
        storeIndex: storeIndex,
        readiness: readiness,
        databasesClosed: closed,
      );
    }
  }

  Future<void> publishFacts({Map<String, int>? floors}) async {
    final factsCompany = facts['company'] as String;
    final signature = await Ed25519().sign(
      utf8.encode(canonical(facts)),
      keyPair: rootPair,
    );
    final root = await rootPair.extractPublicKey();
    for (var i = 0; i < 2; i++) {
      final db = databases[i];
      await db
          .into(db.companyAuthorityFacts)
          .insert(
            CompanyAuthorityFactsCompanion.insert(
              companyId: factsCompany,
              commitment: digest(facts),
              signedBytes: canonical({
                'body': facts,
                'signature': base64Encode(signature.bytes),
              }),
            ),
            mode: InsertMode.insertOrReplace,
          );
      final state = secureStores[i].states[installations[i].namespace]!;
      final record =
          jsonDecode(utf8.decode(state.bytes)) as Map<String, dynamic>;
      record['v'] = 2;
      record['companyTrust'] = {
        'company': factsCompany,
        'root': base64Encode(root.bytes),
        'authority': facts['authority'],
        'facts': digest(facts),
        'policy': 'localContinuity',
      };
      record['pendingCommand'] = null;
      final path = await files[i].resolveSymbolicLinks();
      record['storePath'] = hashes.sha256
          .convert(
            utf8.encode(
              p.normalize(Platform.isWindows ? path.toLowerCase() : path),
            ),
          )
          .toString();
      if (floors != null) record['floors'] = floors;
      await secureStores[i].compareAndSwapState(
        installations[i].namespace,
        expectedRevision: state.revision,
        nextRevision: const Uuid().v4(),
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
      );
      await db.settingsDao.setSetting(
        kInstallationBindingKey,
        jsonEncode({
          'v': 1,
          'id': record['id'],
          'generation': record['generation'],
          'key': record['key'],
          'public': record['public'],
          'store': record['store'],
          'storePath': record['storePath'],
        }),
      );
      await installations[i].reconcile(db);
    }
  }

  JobLineCommands commands(
    int i, {
    Future<void> Function()? beforeCommit,
    Future<void> Function()? afterCommit,
  }) => JobLineCommands(
    authorization: JobLineAuthorization(
      db: databases[i],
      installation: installations[i],
    ),
    beforeCommit: beforeCommit,
    afterCommit: afterCommit,
  );

  JobLineCommand command(
    JobLineMutation mutation, {
    List<String> parents = const [],
    String? requestId,
    String companyId = company,
    String shopId = shop,
  }) => JobLineCommand(
    companyId: companyId,
    shopId: shopId,
    lineId: line,
    requestId: requestId ?? const Uuid().v4(),
    observedHeads: parents,
    mutation: mutation,
  );

  Future<Uint8List> assertion(
    int i,
    JobLineCommand command, {
    Map<String, Object?> changes = const {},
  }) async {
    final security = installations[i];
    final state = secureStores[i].states[security.namespace]!;
    final record = jsonDecode(utf8.decode(state.bytes)) as Map<String, dynamic>;
    final pair = await Ed25519().newKeyPairFromSeed(
      base64Decode(record['seed'] as String),
    );
    final body = <String, Object?>{
      'v': 1,
      'company': command.companyId,
      'shop': command.shopId,
      'line': command.lineId,
      'request': command.requestId,
      'command': command.commitment,
      'user': user,
      'device': devices[i],
      'installation': security.identity!.id.value,
      'generation': security.identity!.generation.value,
      'grant': grants[i],
      'credential': 1,
      'permission': 1,
      'authority': facts['authority'],
      'facts': digest(facts),
      ...changes,
    };
    final signature = await Ed25519().sign(
      utf8.encode(canonical(body)),
      keyPair: pair,
    );
    return Uint8List.fromList(
      utf8.encode(
        canonical({'body': body, 'signature': base64Encode(signature.bytes)}),
      ),
    );
  }

  Future<VerifiedJobLineSession> session(
    int i,
    JobLineCommand command, {
    Map<String, Object?> changes = const {},
  }) async =>
      commands(i).authorization
          .verify(command, await assertion(i, command, changes: changes));

  Future<JobLineCommandReceipt> commit(int i, JobLineCommand command) async =>
      commands(i).patchJobLine(await session(i, command), command);

  Future<JobLine> row(int i) =>
      databases[i].select(databases[i].jobLines).getSingle();
  Future<List<int>> counts(int i) async {
    final db = databases[i];
    return [
      for (final table in [
        'job_line_baselines',
        'job_line_operations',
        'job_line_receipts',
        'job_line_audits',
        'job_line_outgoing',
        'job_line_conflicts',
      ])
        (await db.customSelect('SELECT count(*) AS n FROM $table').getSingle())
            .read<int>('n'),
    ];
  }

  Future<void> reopen(int i) async {
    await databases[i].close();
    databases[i] = AppDatabase.forTesting(NativeDatabase(files[i]));
    installations[i] = InstallationSecurity(
      store: secureStores[i],
      namespace: installations[i].namespace,
    );
    await installations[i].start(databases[i]);
  }

  Future<void> dispose() async {
    for (final db in databases) {
      await db.close();
    }
    await directory.delete(recursive: true);
  }
}

String operationKey(JobLineCommandReceipt receipt) {
  final body =
      (jsonDecode(utf8.decode(receipt.operationBytes)) as Map)['body'] as Map;
  return '${body['generation']}/${body['request']}';
}
