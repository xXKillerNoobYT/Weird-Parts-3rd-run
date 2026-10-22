part of 'job_line_commands.dart';

const kCompanyJobNameLimit = 100;
const kCompanyJobNameByteLimit = 4096;
const kCompanyJobListLimit = 512;

final class CompanyJobCapacityRefusal extends JobLineRefusal {
  const CompanyJobCapacityRefusal()
    : super('This company shop has reached the 512 Job capacity.');
}

final class CreateJob {
  CreateJob({
    required this.companyId,
    required this.shopId,
    required this.jobId,
    required this.requestId,
    required String name,
  }) : name = name.trim() {
    for (final id in [companyId, shopId, jobId, requestId]) {
      _id(id);
    }
    if (this.name.length > kCompanyJobNameByteLimit ||
        utf8.encode(this.name).length > kCompanyJobNameByteLimit) {
      throw const JobLineRefusal(
        'Job name is too large. Shorten the name and retry.',
      );
    }
    if (this.name.isEmpty ||
        this.name.characters.length > kCompanyJobNameLimit) {
      throw const JobLineRefusal('Job name must contain 1 to 100 characters');
    }
  }

  final String companyId;
  final String shopId;
  final String jobId;
  final String requestId;
  final String name;
  Map<String, Object?> _json() => {
    'v': 1,
    'contract': 'job.create@1',
    'company': companyId,
    'shop': shopId,
    'job': jobId,
    'request': requestId,
    'name': name,
  };
  String get commitment => _digest(_json());
}

final class _CreateOperation {
  _CreateOperation(this.body, this.authorization, this.signature);
  final Map<String, Object?> body;
  final Map<String, Object?> authorization;
  final String signature;
  String get commitment => _digest(body);
  String get bytes => _canonical({
    'body': body,
    'authorization': authorization,
    'signature': signature,
  });
  CreateJob get command => CreateJob(
    companyId: _string(body, 'company'),
    shopId: _string(body, 'shop'),
    jobId: _string(body, 'job'),
    requestId: _string(body, 'request'),
    name: _string(body, 'name'),
  );
  Job get projection => Job(
    id: command.jobId,
    name: command.name,
    originDeviceId: _string(body, 'device'),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      body['createdAt'] as int,
      isUtc: true,
    ),
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(
      body['createdAt'] as int,
      isUtc: true,
    ),
    revision: 1,
    status: 'active',
  );

  static _CreateOperation parse(Uint8List bytes) {
    if (bytes.length > _maximumBytes) {
      throw const JobLineRefusal('operation byte limit');
    }
    final text = utf8.decode(bytes);
    final value = _object(jsonDecode(text));
    _keys(value, {'body', 'authorization', 'signature'});
    if (_canonical(value) != text) {
      throw const JobLineRefusal('noncanonical create operation');
    }
    final body = _object(value['body']);
    _keys(body, {
      'v',
      'contract',
      'company',
      'shop',
      'job',
      'request',
      'name',
      'generation',
      'installation',
      'device',
      'user',
      'command',
      'facts',
      'createdAt',
    });
    if (body['v'] != 1 ||
        body['contract'] != 'job.create@1' ||
        body['createdAt'] is! int ||
        (body['createdAt'] as int) < 0 ||
        (body['createdAt'] as int) > 8640000000000000) {
      throw const JobLineRefusal('unsupported create operation');
    }
    for (final field in ['generation', 'installation', 'device', 'user']) {
      _id(_string(body, field));
    }
    final result = _CreateOperation(
      body,
      _object(value['authorization']),
      _string(value, 'signature'),
    );
    if (result.command.commitment != body['command'] ||
        result.command.name != body['name']) {
      throw const JobLineRefusal('create command commitment differs');
    }
    return result;
  }
}

final class VerifiedCreateJobSession extends VerifiedCompanyOperation {
  VerifiedCreateJobSession._(
    this.command,
    this._proofBytes,
    this._trust,
    this._floors,
    this._publicKey,
  );
  final CreateJob command;
  final String _proofBytes;
  final CompanyTrustAnchor _trust;
  final Map<String, int> _floors;
  final SimplePublicKey _publicKey;
  Map<String, Object?> get _proof => _object(jsonDecode(_proofBytes));
  Map<String, Object?> get _assertion => _object(_proof['body']);
  @override
  String get operationDomain => 'wiredpart.job.create.operation@1:';

  @override
  void validateLiveOwner(OwnerSession? owner) {
    if (owner == null) {
      throw const JobLineRefusal('Live administrator session required');
    }
    final a = _assertion;
    owner.validateCommand(
      company: command.companyId,
      shop: command.shopId,
      user: _string(a, 'user'),
      device: _string(a, 'device'),
      installation: _string(a, 'installation'),
      generation: _string(a, 'generation'),
      session: _string(a, 'session'),
    );
    owner.validateAuthority(_trust, _floors);
  }

  @override
  void validateOperationSigningContent(
    Uint8List bytes,
    InstallationIdentity identity,
  ) {
    final body = _object(jsonDecode(utf8.decode(bytes)));
    final parsed = _CreateOperation.parse(
      Uint8List.fromList(
        utf8.encode(
          _canonical({
            'body': body,
            'authorization': _proof,
            'signature': 'candidate',
          }),
        ),
      ),
    );
    if (_canonical(body) != utf8.decode(bytes) ||
        parsed.command.commitment != command.commitment ||
        body['installation'] != identity.id.value ||
        body['generation'] != identity.generation.value ||
        base64Encode(_publicKey.bytes) != base64Encode(identity.publicKey)) {
      throw const JobLineRefusal('signer requires exact Create Job command');
    }
    for (final field in [
      'company',
      'shop',
      'job',
      'request',
      'user',
      'device',
      'installation',
      'generation',
      'command',
      'facts',
    ]) {
      if (body[field] != _assertion[field]) {
        throw const JobLineRefusal('signer cannot substitute create author');
      }
    }
  }
}

class CreateJobAuthorization {
  CreateJobAuthorization({required this.db, required this.installation});
  final AppDatabase db;
  final InstallationSecurity installation;

  Future<VerifiedCreateJobSession> verify(
    CreateJob command,
    Uint8List signedAssertion,
  ) async {
    if (signedAssertion.length > _maximumBytes) {
      throw const JobLineRefusal('authorization byte limit');
    }
    final proof = _object(jsonDecode(utf8.decode(signedAssertion)));
    final a = _object(proof['body']);
    final memberProof = a['v'] == 3;
    _keys(proof, {'body', 'signature', if (memberProof) 'membership'});
    _keys(a, {
      'v',
      'company',
      'shop',
      'job',
      'request',
      'command',
      'user',
      'device',
      'installation',
      'generation',
      'grant',
      'credential',
      'permission',
      'authority',
      'facts',
      'session',
      if (memberProof) 'membership',
    });
    final receiver =
        await JobLineAuthorization(
          db: db,
          installation: installation,
        )._verifyCurrentReceiver(
          null,
          companyId: command.companyId,
          shopId: command.shopId,
        );
    final trust = receiver.trust;
    final facts = receiver.facts;
    if ((!memberProof && a['v'] != 2) ||
        facts.body['v'] != 2 ||
        a['company'] != command.companyId ||
        a['shop'] != command.shopId ||
        a['job'] != command.jobId ||
        a['request'] != command.requestId ||
        a['command'] != command.commitment ||
        a['authority'] != trust.authorityVersion ||
        a['facts'] != trust.factsCommitment) {
      throw const JobLineRefusal(
        'create authorization scope or commitment differs',
      );
    }
    for (final field in [
      'user',
      'device',
      'installation',
      'generation',
      'grant',
      'session',
    ]) {
      _id(_string(a, field));
    }
    final membership = memberProof
        ? await resolveCompanyMembership(
            db: db,
            installation: installation,
            certificateBytes: _string(proof, 'membership'),
          )
        : null;
    final device =
        membership?.device ?? facts._entry('devices', _string(a, 'device'));
    final user = membership?.user ?? facts._entry('users', _string(a, 'user'));
    if (memberProof &&
        (a['membership'] != membership!.proofCommitment ||
            a['device'] != device['id'] ||
            a['user'] != user['id'])) {
      throw const JobLineRefusal('member authorization proof differs');
    }
    bool allows(Map<String, Object?> entry, String key, String value) =>
        entry[key] is List && (entry[key] as List).contains(value);
    if (device['revoked'] != false ||
        user['revoked'] != false ||
        device['installation'] != a['installation'] ||
        device['generation'] != a['generation'] ||
        device['grant'] != a['grant'] ||
        user['credential'] != a['credential'] ||
        user['permission'] != a['permission'] ||
        !allows(device, 'shops', command.shopId) ||
        !allows(user, 'shops', command.shopId) ||
        !allows(device, 'capabilities', 'createJob') ||
        !allows(user, 'capabilities', 'createJob')) {
      throw const JobLineRefusal(
        'Create Job unavailable. Existing company authority needs an explicit capability upgrade.',
      );
    }
    final floors = receiver.floors;
    final versions = {
      'authority.${command.companyId}': facts.body['authority'],
      'grant.${device['grant']}': device['version'],
      'credential.${user['id']}': user['credential'],
      'permission.${user['id']}': user['permission'],
    };
    for (final entry in versions.entries) {
      if (entry.value is! int ||
          (entry.value as int) < 1 ||
          (entry.value as int) < (floors[entry.key] ?? 0)) {
        throw const JobLineRefusal(
          'create authorization below protected floor',
        );
      }
    }
    for (final key in [
      'revocation.device.${device['id']}',
      'revocation.grant.${device['grant']}',
      'revocation.user.${user['id']}',
    ]) {
      if ((floors[key] ?? 0) > 0) {
        throw const JobLineRefusal('create actor is revoked');
      }
    }
    final publicBytes = base64Decode(_string(device, 'key'));
    if (publicBytes.length != 32) {
      throw const JobLineRefusal('invalid device key');
    }
    final publicKey = SimplePublicKey(publicBytes, type: KeyPairType.ed25519);
    await _verifySignature(
      a,
      _string(proof, 'signature'),
      publicKey,
      domain: memberProof
          ? 'wiredpart.job.create.authorization@2:'
          : 'wiredpart.job.create.authorization@1:',
    );
    return VerifiedCreateJobSession._(
      command,
      _canonical(proof),
      trust,
      floors,
      publicKey,
    );
  }
}

final class VerifiedCreateJobReceiptAdmission
    extends VerifiedCompanyReceiptAdmission {
  VerifiedCreateJobReceiptAdmission._(
    this._db,
    this._candidate,
    this._session,
    this._intent,
  );
  final AppDatabase _db;
  final String _candidate;
  final VerifiedCreateJobSession _session;
  final CompanyCommandIntent _intent;
  @override
  String get receiptDomain => 'wiredpart.job.create.receipt@1:';
  @override
  CompanyCommandFamily get family => CompanyCommandFamily.jobCreate;
  @override
  Future<Uint8List> validateSigningContent(
    AppDatabase db,
    InstallationIdentity identity,
    CompanyCommandIntent pending,
    CompanyTrustAnchor trust,
    Map<String, int> floors,
  ) async {
    if (!identical(db, _db) ||
        !db.hasCallerTransaction ||
        pending.afterWitness != null ||
        pending.beforeWitness == null ||
        _canonical(pending.encode()) != _canonical(_intent.encode()) ||
        _canonical(trust.encode()) != _canonical(_session._trust.encode()) ||
        _canonical(floors) != _canonical(_session._floors)) {
      throw const JobLineRefusal('create receipt admission context changed');
    }
    final row = await (db.select(
      db.companyJobs,
    )..where((t) => t.receiptKey.equals(pending.receiptKey))).getSingle();
    if (row.receiptBytes != _candidate) {
      throw const JobLineRefusal('create receipt candidate changed');
    }
    final op = _CreateOperation.parse(
      Uint8List.fromList(utf8.encode(row.operationBytes)),
    );
    if (op.authorization['membership'] != _session._proof['membership'] ||
        _object(op.authorization['body'])['v'] != _session._assertion['v']) {
      throw const JobLineRefusal('saved membership proof differs');
    }
    if (_canonical(op.authorization) != _canonical(_session._proof)) {
      throw const JobLineRefusal('create receipt proof changed');
    }
    _session.validateOperationSigningContent(
      Uint8List.fromList(utf8.encode(_canonical(op.body))),
      identity,
    );
    await _verifySignature(
      op.body,
      op.signature,
      _session._publicKey,
      domain: _session.operationDomain,
    );
    await validateCreateJobCommit(db, pending);
    return Uint8List.fromList(utf8.encode(_candidate));
  }
}

Future<void> validateCreateJobCommit(
  AppDatabase db,
  CompanyCommandIntent intent,
) async {
  final row = await (db.select(
    db.companyJobs,
  )..where((t) => t.receiptKey.equals(intent.receiptKey))).getSingle();
  final op = _CreateOperation.parse(
    Uint8List.fromList(utf8.encode(row.operationBytes)),
  );
  final receipt = decodeJobLineReceipt(row.receiptBytes, requireSeal: false);
  final job = await (db.select(
    db.jobs,
  )..where((t) => t.id.equals(row.jobId))).getSingle();
  final expectedAudit = _canonical({
    'operation': op.commitment,
    'originalUser': op.body['user'],
    'originalDevice': op.body['device'],
    'status': 'applied',
    'receipt': row.receiptKey,
    'outgoing': true,
  });
  final expectedKey = _digest({
    'company': row.companyId,
    'origin': row.originGeneration,
    'request': row.requestId,
    'receiver': receipt['receiver'],
    'store': intent.storeGeneration,
  });
  if (intent.family != CompanyCommandFamily.jobCreate ||
      row.companyId != intent.companyId ||
      row.jobId != intent.lineId ||
      row.originGeneration != intent.originGeneration ||
      row.requestId != intent.requestId ||
      row.operationCommitment != intent.operationCommitment ||
      row.commandCommitment != intent.commandCommitment ||
      op.commitment != row.operationCommitment ||
      op.command.commitment != row.commandCommitment ||
      op.command.companyId != row.companyId ||
      op.command.shopId != row.shopId ||
      op.command.jobId != row.jobId ||
      op.command.requestId != row.requestId ||
      op.body['generation'] != row.originGeneration ||
      row.projectionBytes != _canonical(job.toJson()) ||
      row.projectionBytes != _canonical(op.projection.toJson()) ||
      !row.outgoing ||
      receipt['key'] != expectedKey ||
      receipt['key'] != row.receiptKey ||
      receipt['receiver'] != op.body['installation'] ||
      receipt['parent'] != null ||
      receipt['status'] != 'applied' ||
      receipt['operation'] != op.commitment ||
      receipt['command'] != row.commandCommitment ||
      receipt['store'] != intent.storeGeneration ||
      receipt['bytes'] != base64Encode(utf8.encode(op.bytes)) ||
      row.auditBytes != expectedAudit) {
    throw const JobLineRefusal('create commit evidence differs');
  }
  final proof = _object(op.authorization['body']);
  final a = _object(op.authorization);
  _keys(a, {'body', 'signature', if (proof['v'] == 3) 'membership'});
  for (final field in [
    'company',
    'shop',
    'job',
    'request',
    'generation',
    'installation',
    'device',
    'user',
    'command',
    'facts',
  ]) {
    if (op.body[field] != proof[field]) {
      throw const JobLineRefusal('create attribution differs');
    }
  }
}

class CompanyJobCommands {
  CompanyJobCommands({
    required this.enrollment,
    this.beforeCommit,
    this.afterCommit,
  });
  final CompanyEnrollment enrollment;
  final Future<void> Function()? beforeCommit;
  final Future<void> Function()? afterCommit;
  AppDatabase get _db => enrollment.db;
  InstallationSecurity get _installation => enrollment.installation;

  Future<JobLineCommandReceipt> createJob(
    CreateJob command, {
    required OwnerSession ownerSession,
  }) async {
    if (_db.hasCallerTransaction) {
      throw const JobLineRefusal('command must own its top-level transaction');
    }
    return ownerSession.runLocalCommand(() async {
      var session = await enrollment.issueCreateJobAssertion(command);
      session.validateLiveOwner(ownerSession);
      CompanyCommandIntent? intent;
      JobLineCommandReceipt result;
      try {
        result = await _db.transaction(() async {
          await _db.customStatement(
            'UPDATE app_settings SET value = value WHERE key = ?',
            [kInstallationBindingKey],
          );
          session = await enrollment.issueCreateJobAssertion(command);
          session.validateLiveOwner(ownerSession);
          final identity = _installation.identity!;
          final generation = _installation.receivingStoreGeneration!.value;
          final existing =
              await (_db.select(_db.companyJobs)..where(
                    (t) =>
                        t.companyId.equals(command.companyId) &
                        t.originGeneration.equals(identity.generation.value) &
                        t.requestId.equals(command.requestId),
                  ))
                  .getSingleOrNull();
          if (existing != null) {
            final receipt = await _verifyRetry(existing, session);
            await beforeCommit?.call();
            final fresh = await enrollment.issueCreateJobAssertion(command);
            fresh.validateLiveOwner(ownerSession);
            await _verifyRetry(existing, fresh);
            return receipt;
          }
          if (await (_db.select(_db.jobs)
                        ..where((t) => t.id.equals(command.jobId)))
                      .getSingleOrNull() !=
                  null ||
              await (_db.select(_db.companyJobs)
                        ..where((t) => t.jobId.equals(command.jobId)))
                      .getSingleOrNull() !=
                  null) {
            throw const JobLineRefusal('Job ID already exists');
          }
          final count = await _db
              .customSelect(
                'SELECT COUNT(*) AS total FROM company_jobs WHERE company_id = ? AND shop_id = ?',
                variables: [
                  Variable(command.companyId),
                  Variable(command.shopId),
                ],
              )
              .getSingle();
          if (count.read<int>('total') >= kCompanyJobListLimit) {
            throw const CompanyJobCapacityRefusal();
          }
          final body = <String, Object?>{
            ...command._json(),
            'generation': identity.generation.value,
            'installation': identity.id.value,
            'device': session._assertion['device'],
            'user': session._assertion['user'],
            'command': command.commitment,
            'facts': session._trust.factsCommitment,
            'createdAt':
                (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000) * 1000,
          };
          final signature = await _installation.signCompanyOperation(
            _db,
            session,
            Uint8List.fromList(utf8.encode(_canonical(body))),
            ownerSession: ownerSession,
          );
          final operation = _CreateOperation(
            body,
            session._proof,
            base64Encode(signature.bytes),
          );
          final receiptKey = _digest({
            'company': command.companyId,
            'origin': identity.generation.value,
            'request': command.requestId,
            'receiver': identity.id.value,
            'store': generation,
          });
          intent = CompanyCommandIntent(
            family: CompanyCommandFamily.jobCreate,
            receiptKey: receiptKey,
            operationCommitment: operation.commitment,
            commandCommitment: command.commitment,
            storeGeneration: generation,
            companyId: command.companyId,
            lineId: command.jobId,
            originGeneration: identity.generation.value,
            requestId: command.requestId,
          );
          intent = await _installation.beginCompanyCommand(
            _db,
            intent!,
            expectedTrust: session._trust,
            expectedFloors: session._floors,
          );
          var receiptBytes = _canonicalReceipt({
            'v': 2,
            'key': receiptKey,
            'parent': null,
            'operation': operation.commitment,
            'command': command.commitment,
            'status': 'applied',
            'bytes': base64Encode(utf8.encode(operation.bytes)),
            'receiver': identity.id.value,
            'store': generation,
          });
          await _db
              .into(_db.jobs)
              .insert(operation.projection.toCompanion(false));
          await _db
              .into(_db.companyJobs)
              .insert(
                CompanyJobsCompanion.insert(
                  jobId: command.jobId,
                  companyId: command.companyId,
                  shopId: command.shopId,
                  originGeneration: identity.generation.value,
                  requestId: command.requestId,
                  operationCommitment: operation.commitment,
                  commandCommitment: command.commitment,
                  operationBytes: operation.bytes,
                  projectionBytes: _canonical(operation.projection.toJson()),
                  receiptKey: receiptKey,
                  receiptBytes: receiptBytes,
                  outgoing: true,
                  auditBytes: _canonical({
                    'operation': operation.commitment,
                    'originalUser': body['user'],
                    'originalDevice': body['device'],
                    'status': 'applied',
                    'receipt': receiptKey,
                    'outgoing': true,
                  }),
                ),
              );
          final seal = await _installation.signCompanyReceipt(
            _db,
            VerifiedCreateJobReceiptAdmission._(
              _db,
              receiptBytes,
              session,
              intent!,
            ),
          );
          receiptBytes = _canonicalReceipt({
            ...decodeJobLineReceipt(receiptBytes, requireSeal: false),
            'seal': base64Encode(seal.bytes),
          });
          await (_db.update(_db.companyJobs)
                ..where((t) => t.jobId.equals(command.jobId)))
              .write(CompanyJobsCompanion(receiptBytes: Value(receiptBytes)));
          intent = await _installation.sealCompanyCommand(_db, intent!);
          await beforeCommit?.call();
          await _installation.validateHeldCompanyCommand(
            _db,
            intent!,
            expectedTrust: session._trust,
            expectedFloors: session._floors,
          );
          session.validateLiveOwner(ownerSession);
          return JobLineCommandReceipt._decode(receiptBytes);
        });
      } catch (_) {
        if (intent != null) await _installation.reconcile(_db);
        rethrow;
      }
      if (intent != null) {
        await afterCommit?.call();
        await _installation.completeCompanyCommand(_db, intent!);
      }
      return result;
    });
  }

  Future<List<Job>> listJobs({required OwnerSession ownerSession}) async {
    if (_db.hasCallerTransaction) {
      throw const JobLineRefusal('list must own its read transaction');
    }
    return ownerSession.runLocalCommand(() async {
      final scope = ownerSession.identity;
      final probe = CreateJob(
        companyId: scope.companyId,
        shopId: scope.shopId,
        jobId: const Uuid().v4(),
        requestId: const Uuid().v4(),
        name: 'Permission check',
      );
      final verified = await enrollment.issueCreateJobAssertion(probe);
      verified.validateLiveOwner(ownerSession);
      final jobs = await _db.transaction(() async {
        final rows =
            await (_db.select(_db.companyJobs)
                  ..where(
                    (t) =>
                        t.companyId.equals(scope.companyId) &
                        t.shopId.equals(scope.shopId),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.jobId)])
                  ..limit(kCompanyJobListLimit + 1))
                .get();
        if (rows.length > kCompanyJobListLimit) {
          throw const JobLineRefusal('company job list capacity reached');
        }
        final result = <Job>[];
        for (final row in rows) {
          if (row.outgoing) {
            await _verifyRecord(row);
          } else {
            await verifyIncomingRecord(row);
          }
          result.add(
            await (_db.select(
              _db.jobs,
            )..where((t) => t.id.equals(row.jobId))).getSingle(),
          );
        }
        return result;
      });
      final fresh = await enrollment.issueCreateJobAssertion(probe);
      fresh.validateLiveOwner(ownerSession);
      return jobs;
    });
  }

  Future<JobLineCommandReceipt> _verifyRetry(
    CompanyJob row,
    VerifiedCreateJobSession session,
  ) async {
    final current = await (_db.select(
      _db.companyJobs,
    )..where((t) => t.jobId.equals(row.jobId))).getSingle();
    if (current != row) {
      throw const JobLineRefusal('saved create result changed');
    }
    final op = _CreateOperation.parse(
      Uint8List.fromList(utf8.encode(row.operationBytes)),
    );
    if (op.authorization['membership'] != session._proof['membership'] ||
        _object(op.authorization['body'])['v'] != session._assertion['v']) {
      throw const JobLineRefusal('saved membership proof differs');
    }
    session.validateOperationSigningContent(
      Uint8List.fromList(utf8.encode(_canonical(op.body))),
      _installation.identity!,
    );
    await _verifySignature(
      op.body,
      op.signature,
      session._publicKey,
      domain: session.operationDomain,
    );
    await _verifySignature(
      _object(op.authorization['body']),
      _string(op.authorization, 'signature'),
      session._publicKey,
      domain: session._assertion['v'] == 3
          ? 'wiredpart.job.create.authorization@2:'
          : 'wiredpart.job.create.authorization@1:',
    );
    return _verifyRecord(row);
  }

  Future<JobLineCommandReceipt> _verifyRecord(CompanyJob row) async {
    final intent = CompanyCommandIntent(
      family: CompanyCommandFamily.jobCreate,
      receiptKey: row.receiptKey,
      operationCommitment: row.operationCommitment,
      commandCommitment: row.commandCommitment,
      storeGeneration: _installation.receivingStoreGeneration!.value,
      companyId: row.companyId,
      lineId: row.jobId,
      originGeneration: row.originGeneration,
      requestId: row.requestId,
    );
    await validateCreateJobCommit(_db, intent);
    await JobLineCommandReceipt.verifyAdmissionSeal(
      row.receiptBytes,
      _installation.identity!,
      intent.storeGeneration,
      expectedFamily: CompanyCommandFamily.jobCreate,
    );
    return JobLineCommandReceipt._decode(row.receiptBytes);
  }
}
