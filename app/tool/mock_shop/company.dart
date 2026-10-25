import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/nearby/nearby_controller.dart';
import 'package:wired_parts/features/nearby/nearby_discovery.dart';
import 'package:wired_parts/features/nearby/nearby_protocol.dart';

import 'adapter.dart';
import 'fixture.dart';

final class _MockProtectedStore
    implements InstallationSecureStore, RecoveryFilePublisher {
  final _states = <String, ProtectedInstallationState>{};

  @override
  Future<ProtectedInstallationState?> readState(String namespace) async =>
      _states[namespace];

  @override
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  }) async {
    if (_states[namespace]?.revision != expectedRevision) {
      throw StateError('Mock protected-store revision changed');
    }
    _states[namespace] = ProtectedInstallationState(
      nextRevision,
      Uint8List.fromList(bytes),
    );
    return nextRevision;
  }

  @override
  Future<void> writeRecoveryFileExclusive(String path, Uint8List bytes) async {
    final file = File(path);
    await file.create(exclusive: true);
    await file.writeAsBytes(bytes, flush: true);
  }
}

final class MockCompanyMember {
  MockCompanyMember._(this.root, this._store, this._namespace, this._pin);
  final Directory root;
  final _MockProtectedStore _store;
  final String _namespace;
  final String _pin;
  late AppDatabase _db;
  late InstallationSecurity _installation;
  late CompanyEnrollment _enrollment;
  late OwnerSession _owner;
  AppDatabase get db => _db;
  InstallationSecurity get installation => _installation;
  CompanyEnrollment get enrollment => _enrollment;
  OwnerSession get owner => _owner;
  final _notesRequests = <String, PatchJobDetails>{};

  Future<void> _open() async {
    _db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/shop.sqlite')),
    );
    _installation = InstallationSecurity(store: _store, namespace: _namespace);
    await installation.start(db);
    _enrollment = CompanyEnrollment(installation: installation, db: db);
  }

  Future<void> reopen() async {
    await enrollment.signOut();
    await db.close();
    await _open();
    _owner = await enrollment.signIn(_pin);
  }

  CompanyJobCommands get commands => CompanyJobCommands(enrollment: enrollment);

  Future<List<CompanyJobView>> views() =>
      commands.listJobViews(ownerSession: owner);

  Future<void> importJobs(MockShopFixture fixture) async {
    final expectedIds = {
      for (final id in fixture.jobs.keys) fixture.nativeId('company-job', id),
    };
    final existing = await db.select(db.companyJobs).get();
    if (existing.any((j) => !expectedIds.contains(j.jobId))) {
      throw StateError('Company fixture contains an unrelated Job');
    }
    if ((await db.select(db.companyJobNames).get()).isNotEmpty ||
        (await db.select(db.companyJobLifecycles).get()).isNotEmpty) {
      throw StateError('Company fixture has subsequent edits');
    }
    final acceptedDetails = {
      for (final id in fixture.jobs.keys)
        fixture.nativeId('company-details-request', id),
    };
    if ((await db.select(db.companyJobDetails).get()).any(
      (d) => !acceptedDetails.contains(d.requestId),
    )) {
      throw StateError('Company fixture has subsequent details edits');
    }
    for (final value in fixture.jobs.values) {
      final job = value as Map<String, dynamic>;
      final sourceId = job['id'] as String;
      final id = fixture.nativeId('company-job', sourceId);
      await commands.createJob(
        CreateJob(
          companyId: owner.identity.companyId,
          shopId: owner.identity.shopId,
          jobId: id,
          requestId: fixture.nativeId('company-create-request', sourceId),
          name: job['title'],
        ),
        ownerSession: owner,
      );
      final row = (await db.select(db.companyJobs).get()).singleWhere(
        (j) => j.jobId == id,
      );
      final digest = hashes.sha256
          .convert(utf8.encode(row.operationBytes))
          .toString();
      final customer = fixture.raw['customers'][job['customer_id']];
      await commands.patchJobDetails(
        PatchJobDetails(
          companyId: owner.identity.companyId,
          shopId: owner.identity.shopId,
          jobId: id,
          requestId: fixture.nativeId('company-details-request', sourceId),
          creationDigest: digest,
          patch: JobDetailsPatch(
            customer: SetField(customer['name'] as String),
            location: SetField(customer['site_label'] as String),
            jobNumber: SetField(sourceId),
            status: SetField(
              const ['completed', 'cancelled'].contains(job['status'])
                  ? CompanyJobStatus.archived
                  : CompanyJobStatus.active,
            ),
            notes: SetField(
              canonicalMockJson({
                'fixture': job,
                'original_fixture_id': sourceId,
                'workflow_projection': 'active or archived only',
              }),
            ),
          ),
          observedHeads: {for (final f in JobDetailField.values) f: <String>[]},
        ),
        ownerSession: owner,
      );
    }
    if ((await views()).length != 7) {
      throw StateError('Company import did not retain exactly seven Jobs');
    }
  }

  Future<void> patchNotes(
    MockShopFixture fixture,
    String sourceId,
    String notes,
    String requestLabel,
  ) async {
    final id = fixture.nativeId('company-job', sourceId);
    final requestId = fixture.nativeId(
      'scenario-details-request',
      requestLabel,
    );
    final stored =
        await (db.select(db.companyJobDetails)..where(
              (row) =>
                  row.companyId.equals(owner.identity.companyId) &
                  row.originGeneration.equals(
                    installation.identity!.generation.value,
                  ) &
                  row.requestId.equals(requestId),
            ))
            .getSingleOrNull();
    var command = stored == null
        ? _notesRequests[requestId]
        : PatchJobDetails.fromOperationBytes(
            Uint8List.fromList(utf8.encode(stored.operationBytes)),
          );
    if (command != null) {
      final priorValue = switch (command.patch.notes) {
        SetField(value: final value) => value,
        _ => throw StateError('Request ID belongs to a different command'),
      };
      if (command.jobId != id ||
          priorValue != notes ||
          command.observedHeads.length != 1 ||
          !command.observedHeads.containsKey(JobDetailField.notes)) {
        throw StateError('Notes request ID reused with different content');
      }
    } else {
      final view = (await views()).singleWhere((j) => j.baseJob.id == id);
      command = PatchJobDetails(
        companyId: owner.identity.companyId,
        shopId: owner.identity.shopId,
        jobId: id,
        requestId: requestId,
        creationDigest: view.creationDigest,
        patch: JobDetailsPatch(notes: SetField(notes)),
        observedHeads: {JobDetailField.notes: view.details.notes.heads},
      );
    }
    _notesRequests[requestId] = command;
    await commands.patchJobDetails(command, ownerSession: owner);
  }

  Future<Map<String, Object?>> publicJobState() async {
    final result = <String, Object?>{};
    final all = await views();
    all.sort((a, b) => a.baseJob.id.compareTo(b.baseJob.id));
    for (final v in all) {
      result[v.baseJob.id] = {
        'name': v.displayName,
        'customer': v.details.customer.value,
        'location': v.details.location.value,
        'job_number': v.details.jobNumber.value,
        'status': v.details.status.value.name,
        'notes': v.details.notes.value,
        'creation_digest': v.creationDigest,
        'notes_heads': v.details.notes.heads,
      };
    }
    return result;
  }
}

final class _MockDiscovery implements NearbyDiscovery {
  final changes = StreamController<List<NearbyPeer>>.broadcast();
  int port = 0;
  @override
  Stream<List<NearbyPeer>> get peers => changes.stream;
  @override
  Future<void> start({
    required String deviceId,
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    this.port = port;
  }

  @override
  Future<void> updateAdvertisement({
    required String name,
    required int port,
    required List<String> ips,
  }) async {
    this.port = port;
  }

  @override
  Future<void> stop() async {}
}

final class _MockConnection {
  _MockConnection(
    this.a,
    this.b,
    this.ad,
    this.bd,
    this.aChannel,
    this.bChannel,
  );
  final NearbyController a, b;
  final _MockDiscovery ad, bd;
  final NearbyJoinChannel aChannel, bChannel;
  bool _closed = false;

  static Future<_MockConnection> create() async {
    final ad = _MockDiscovery();
    final bd = _MockDiscovery();
    NearbyController make(String alias, _MockDiscovery discovery) =>
        NearbyController(
          deviceId: alias,
          deviceName: alias,
          discovery: discovery,
          companyJoin: true,
          bindAddress: InternetAddress.loopbackIPv4,
          localIps: () async => ['127.0.0.1'],
          collectPayload: () async =>
              throw StateError('Mock company sync cannot collect a shop'),
          applyPayload: (_) async =>
              throw StateError('Mock company sync cannot replace a shop'),
        );
    final a = make('mock-company-a', ad);
    final b = make('mock-company-b', bd);
    try {
      await a.start();
      await b.start();
      await b.pair(
        NearbyPeer(
          deviceId: 'mock-company-a',
          name: 'mock-company-a',
          host: '127.0.0.1',
          port: ad.port,
        ),
      );
      if (a.state.verifyCode == null ||
          a.state.verifyCode != b.state.verifyCode) {
        throw StateError('Ephemeral pairing comparison failed');
      }
      await a.confirmCode();
      await b.confirmCode();
      if (a.state.phase != NearbyPhase.paired ||
          b.state.phase != NearbyPhase.paired) {
        throw StateError('Mock controllers did not finish pairing');
      }
      return _MockConnection(
        a,
        b,
        ad,
        bd,
        await NearbyJoinChannel.fromPairedSession(a.pairedJoinSession!),
        await NearbyJoinChannel.fromPairedSession(b.pairedJoinSession!),
      );
    } catch (_) {
      await a.dispose();
      await b.dispose();
      await ad.changes.close();
      await bd.changes.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    aChannel.close();
    bChannel.close();
    await a.dispose();
    await b.dispose();
    await ad.changes.close();
    await bd.changes.close();
  }
}

final class MockCompanySync {
  MockCompanySync._(this._connection, this.a, this.b);
  final _MockConnection _connection;
  final CompanyCreatedJobSync a, b;
  bool _closed = false;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([a.closeAndDrain(), b.closeAndDrain()]);
    await _connection.close();
  }
}

final class MockCompanyPair {
  MockCompanyPair._(this.root, this.a, this.b);
  final Directory root;
  final MockCompanyMember a, b;
  final _openSync = <MockCompanySync>[];
  bool _closed = false;

  static Future<MockCompanyPair> create(MockShopFixture fixture) async {
    final root = await Directory.systemTemp.createTemp('mock-company-jobs-');
    final secret = ephemeralMockPin();
    Future<MockCompanyMember> member(String role) async {
      final path = Directory('${root.path}/$role')..createSync();
      final m = MockCompanyMember._(
        path,
        _MockProtectedStore(),
        'synthetic.mock-shop-$role',
        secret,
      );
      await m._open();
      return m;
    }

    final a = await member('a');
    final b = await member('b');
    final result = MockCompanyPair._(root, a, b);
    try {
      await a.enrollment.create(
        companyName: fixture.shop['name'],
        policy: CompanyContinuityPolicy.localContinuity,
        pin: secret,
        recoveryPassphrase: const Uuid().v4() + const Uuid().v4(),
        recoveryFile: File('${root.path}/authority.wpca'),
      );
      a._owner = await a.enrollment.signIn(secret);
      await a.importJobs(fixture);
      final connection = await _MockConnection.create();
      try {
        final aj = CompanyJoin(enrollment: a.enrollment);
        final bj = CompanyJoin(enrollment: b.enrollment);
        final request = await aj.receiveJoinRequest(
          connection.aChannel,
          await bj.beginJoin(connection.bChannel),
        );
        await bj.acceptProvision(
          await bj.receiveProvision(
            connection.bChannel,
            await aj.approveJoin(
              connection.aChannel,
              request,
              ownerSession: a.owner,
            ),
          ),
        );
      } finally {
        await connection.close();
      }
      b._owner = await b.enrollment.signIn(secret);
      return result;
    } catch (_) {
      await result.close();
      rethrow;
    }
  }

  Future<MockCompanySync> openSync() async {
    final connection = await _MockConnection.create();
    try {
      final aa = CompanyPeerAuthentication(enrollment: a.enrollment);
      final ba = CompanyPeerAuthentication(enrollment: b.enrollment);
      final first = await aa.beginPeerChallenge(
        connection.aChannel,
        (await aa.retainedPeers(session: a.owner)).single,
        session: a.owner,
      );
      final response = await ba.receivePeerChallenge(
        connection.bChannel,
        first,
        session: b.owner,
      );
      final complete = await aa.receivePeerResponse(
        connection.aChannel,
        response,
      );
      final done = await ba.receivePeerCompletion(
        connection.bChannel,
        complete,
      );
      final aPeer = await aa.receivePeerAcknowledgment(
        connection.aChannel,
        done.acknowledgment,
      );
      final aSync = CompanyCreatedJobSync(
        availability: await CompanyJobSyncAvailability.open(
          enrollment: a.enrollment,
          owner: a.owner,
          peer: aPeer,
        ),
        controller: connection.a,
      );
      final bSync = CompanyCreatedJobSync(
        availability: await CompanyJobSyncAvailability.open(
          enrollment: b.enrollment,
          owner: b.owner,
          peer: done.membership,
        ),
        controller: connection.b,
      );
      connection.a.onJoinMessage = (_, wire) => aSync.receive(wire);
      connection.b.onJoinMessage = (_, wire) => bSync.receive(wire);
      final result = MockCompanySync._(connection, aSync, bSync);
      _openSync.add(result);
      return result;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  Future<void> reopen() async {
    for (final sync in _openSync) {
      await sync.close();
    }
    _openSync.clear();
    await a.reopen();
    await b.reopen();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final sync in _openSync) {
      await sync.close();
    }
    await a.enrollment.signOut();
    await b.enrollment.signOut();
    await a.db.close();
    await b.db.close();
    await root.delete(recursive: true);
  }
}
