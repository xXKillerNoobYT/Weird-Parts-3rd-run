part of 'job_line_commands.dart';

/// Only the verifier in this library can construct a session. A valid carrier
/// or a caller-selected author cannot replace the original signed assertion.
sealed class VerifiedCompanyOperation {
  String get operationDomain;
  void validateLiveOwner(OwnerSession? owner);
  void validateOperationSigningContent(
    Uint8List bytes,
    InstallationIdentity identity,
  );
}

sealed class VerifiedCompanyReceiptAdmission {
  String get receiptDomain;
  CompanyCommandFamily get family;
  Future<Uint8List> validateSigningContent(
    AppDatabase db,
    InstallationIdentity identity,
    CompanyCommandIntent pending,
    CompanyTrustAnchor trust,
    Map<String, int> floors,
  );
}

final class VerifiedJobLineSession extends VerifiedCompanyOperation {
  @override
  String get operationDomain => 'wiredpart.job.line.operation@1:';
  VerifiedJobLineSession._(
    this.command,
    Map<String, Object?> proof,
    this._facts,
    this._trust,
    this._floors,
    this._publicKey,
  ) : _proofBytes = _canonical(proof);
  final JobLineCommand command;
  final String _proofBytes;
  final _CompanyFacts _facts;
  final CompanyTrustAnchor _trust;
  final Map<String, int> _floors;
  final SimplePublicKey _publicKey;
  Map<String, Object?> get _proof => _object(jsonDecode(_proofBytes));
  Map<String, Object?> get _assertion => _object(_proof['body']);

  @override
  void validateLiveOwner(OwnerSession? owner) {
    final assertion = _assertion;
    if (assertion['v'] != 2) return;
    if (owner == null) {
      throw const JobLineRefusal('Live administrator session required');
    }
    owner.validateCommand(
      company: _string(assertion, 'company'),
      shop: _string(assertion, 'shop'),
      user: _string(assertion, 'user'),
      device: _string(assertion, 'device'),
      installation: _string(assertion, 'installation'),
      generation: _string(assertion, 'generation'),
      session: _string(assertion, 'session'),
    );
    owner.validateAuthority(_trust, _floors);
  }

  /// The protected signer accepts only a complete operation covered by this
  /// opaque proof. Its signature domain cannot mint a login assertion.
  @override
  void validateOperationSigningContent(
    Uint8List bytes,
    InstallationIdentity identity,
  ) {
    if (bytes.length > _maximumBytes) {
      throw const JobLineRefusal('operation byte limit');
    }
    final text = utf8.decode(bytes);
    final body = _object(jsonDecode(text));
    _keys(body, {
      'v',
      'contract',
      'company',
      'shop',
      'line',
      'request',
      'generation',
      'installation',
      'device',
      'user',
      'parents',
      'baseline',
      'units',
      'command',
      'facts',
    });
    if (_canonical(body) != text ||
        body['v'] != 1 ||
        body['contract'] != 'job.line.patch@1' ||
        _canonical(body['parents']) != _canonical(command.observedHeads) ||
        _canonical(body['units']) != _canonical(command.mutation._units()) ||
        body['baseline'] !=
            _facts.entity(
              'jobLine',
              command.lineId,
              shop: command.shopId,
            )['baseline'] ||
        body['installation'] != identity.id.value ||
        body['generation'] != identity.generation.value ||
        base64Encode(_publicKey.bytes) != base64Encode(identity.publicKey)) {
      throw const JobLineRefusal('signer requires verified original command');
    }
    for (final key in [
      'company',
      'shop',
      'line',
      'request',
      'generation',
      'installation',
      'device',
      'user',
      'command',
      'facts',
    ]) {
      if (body[key] != _assertion[key]) {
        throw const JobLineRefusal('signer cannot substitute author');
      }
    }
  }
}

class _CompanyFacts {
  _CompanyFacts(this.body);
  final Map<String, Object?> body;
  Map<String, Object?> _entry(String key, String id) {
    final list = body[key];
    if (list is! List || list.length > 128) {
      throw const JobLineRefusal('unsupported company facts');
    }
    final entries = list.map(_object).where((v) => v['id'] == id).toList();
    if (entries.length != 1) throw JobLineRefusal('missing or ambiguous $key');
    return entries.single;
  }

  Map<String, Object?> entity(String kind, String id, {String? shop}) {
    final entries = body['entities'];
    if (entries is! List || entries.length > 128) {
      throw const JobLineRefusal('unsupported company entity facts');
    }
    final matches = entries
        .map(_object)
        .where((v) => v['kind'] == kind && v['id'] == id)
        .toList();
    if (matches.length != 1 ||
        (shop != null && matches.single['shop'] != shop)) {
      throw const JobLineRefusal('entity has no signed company/shop binding');
    }
    return matches.single;
  }
}

class _ReceiverAuthority {
  _ReceiverAuthority(this.facts, this.trust, this.floors);
  final _CompanyFacts facts;
  final CompanyTrustAnchor trust;
  final Map<String, int> floors;
}

/// This capability never leaves the command transaction that created it.
/// Public installation APIs cannot manufacture an admitted receipt from rows.
final class VerifiedJobLineReceiptAdmission
    extends VerifiedCompanyReceiptAdmission {
  @override
  String get receiptDomain => 'wiredpart.job.line.receipt@2:';
  @override
  CompanyCommandFamily get family => CompanyCommandFamily.jobLinePatch;
  VerifiedJobLineReceiptAdmission._(
    this._db,
    this._candidate,
    this._operation,
    this._verified,
    this._intent,
  );
  final AppDatabase _db;
  final String _candidate;
  final _Operation _operation;
  final VerifiedJobLineSession _verified;
  final CompanyCommandIntent _intent;

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
        _canonical(trust.encode()) != _canonical(_verified._trust.encode()) ||
        _canonical(floors) != _canonical(_verified._floors)) {
      throw const JobLineRefusal('receipt admission context changed');
    }
    final receipt = await (db.select(
      db.jobLineReceipts,
    )..where((t) => t.receiptKey.equals(pending.receiptKey))).getSingle();
    if (receipt.receiptBytes != _candidate) {
      throw const JobLineRefusal('receipt candidate changed before signing');
    }
    _validateReceiptPayload(
      decodeJobLineReceipt(_candidate, requireSeal: false),
      receipt,
      _operation,
      identity,
      pending.storeGeneration,
      sealed: false,
    );
    if (_operation.commitment != pending.operationCommitment ||
        _operation.commandCommitment != pending.commandCommitment ||
        _operation.company != pending.companyId ||
        _operation.line != pending.lineId ||
        _operation.generation != pending.originGeneration ||
        _operation.id != pending.requestId) {
      throw const JobLineRefusal('receipt intent differs from admission');
    }
    final operation =
        await (db.select(db.jobLineOperations)..where(
              (t) =>
                  t.companyId.equals(pending.companyId) &
                  t.originGeneration.equals(pending.originGeneration) &
                  t.requestId.equals(pending.requestId),
            ))
            .getSingle();
    if (operation.operationBytes != _operation.bytes) {
      throw const JobLineRefusal('receipt operation changed before signing');
    }
    return Uint8List.fromList(utf8.encode(_candidate));
  }
}

class JobLineAuthorization {
  JobLineAuthorization({required this.db, required this.installation});
  final AppDatabase db;
  final InstallationSecurity installation;

  /// The signed facts must already be present in this company's store. Their
  /// exact commitment and root key are read from protected storage, never from
  /// the incoming operation. Enrollment/fact publication are separate work.
  Future<VerifiedJobLineSession> verify(
    JobLineCommand command,
    Uint8List signedAssertion,
  ) async {
    if (signedAssertion.length > _maximumBytes) {
      throw const JobLineRefusal('authorization exceeds byte limit');
    }
    final proof = _object(jsonDecode(utf8.decode(signedAssertion)));
    return _verify(command, proof);
  }

  Future<VerifiedJobLineSession> _verify(
    JobLineCommand command,
    Map<String, Object?> proof,
  ) async {
    _keys(proof, {'body', 'signature'});
    final assertion = _object(proof['body']);
    final v2 = assertion['v'] == 2;
    _keys(assertion, {
      'v',
      'company',
      'shop',
      'line',
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
      if (v2) 'session',
    });
    if (!(assertion['v'] == 1 || v2) ||
        (v2 &&
            (assertion['session'] is! String ||
                !Uuid.isValidUUID(
                  fromString: assertion['session'] as String,
                )))) {
      throw const JobLineRefusal('unsupported authorization version');
    }
    final receiver = await _verifyCurrentReceiver(command);
    final trust = receiver.trust;
    if (assertion['company'] != command.companyId ||
        assertion['shop'] != command.shopId ||
        assertion['line'] != command.lineId ||
        assertion['request'] != command.requestId ||
        assertion['command'] != command.commitment ||
        assertion['authority'] != trust.authorityVersion ||
        assertion['facts'] != trust.factsCommitment) {
      throw const JobLineRefusal('authorization scope or commitment differs');
    }
    final facts = receiver.facts;
    final factsBody = facts.body;
    if ((factsBody['v'] == 2) != v2) {
      throw const JobLineRefusal('authorization version differs from facts');
    }
    final device = facts._entry('devices', _string(assertion, 'device'));
    final user = facts._entry('users', _string(assertion, 'user'));
    final capability = command.mutation is DeleteJobLine
        ? 'deleteJobLine'
        : 'patchJobLine';
    _keys(device, {
      'id',
      'installation',
      'generation',
      'key',
      'grant',
      'version',
      'revoked',
      'shops',
      'capabilities',
    });
    _keys(user, {
      'id',
      'credential',
      'permission',
      'revoked',
      'shops',
      'capabilities',
    });
    final floors = receiver.floors;
    bool allows(Map<String, Object?> value, String key, String item) =>
        value[key] is List && (value[key] as List).contains(item);
    if (device['revoked'] != false ||
        user['revoked'] != false ||
        device['installation'] != assertion['installation'] ||
        device['generation'] != assertion['generation'] ||
        device['grant'] != assertion['grant'] ||
        user['credential'] != assertion['credential'] ||
        user['permission'] != assertion['permission'] ||
        !allows(device, 'shops', command.shopId) ||
        !allows(user, 'shops', command.shopId) ||
        !allows(device, 'capabilities', capability) ||
        !allows(user, 'capabilities', capability)) {
      throw const JobLineRefusal('device/user grant or capability denied');
    }
    final versions = <String, Object?>{
      'authority.${command.companyId}': factsBody['authority'],
      'grant.${device['grant']}': device['version'],
      'credential.${user['id']}': user['credential'],
      'permission.${user['id']}': user['permission'],
    };
    for (final entry in versions.entries) {
      if (entry.value is! int ||
          (entry.value as int) < 1 ||
          (entry.value as int) < (floors[entry.key] ?? 0)) {
        throw const JobLineRefusal(
          'authorization version below protected floor',
        );
      }
    }
    for (final key in [
      'revocation.device.${device['id']}',
      'revocation.grant.${device['grant']}',
      'revocation.user.${user['id']}',
    ]) {
      if ((floors[key] ?? 0) > 0) {
        throw const JobLineRefusal('credential is known revoked');
      }
    }
    for (final key in [
      'user',
      'device',
      'installation',
      'generation',
      'grant',
    ]) {
      _id(_string(assertion, key));
    }
    final public = base64Decode(_string(device, 'key'));
    if (public.length != 32) {
      throw const JobLineRefusal('invalid signing device key');
    }
    final publicKey = SimplePublicKey(public, type: KeyPairType.ed25519);
    await _verifySignature(
      assertion,
      _string(proof, 'signature'),
      publicKey,
      domain: v2 ? 'wiredpart.job.line.authorization@2:' : '',
    );
    return VerifiedJobLineSession._(
      command,
      proof,
      facts,
      trust,
      Map.unmodifiable(floors),
      publicKey,
    );
  }

  Future<_ReceiverAuthority> _verifyCurrentReceiver(
    JobLineCommand? command, {
    String? companyId,
    String? shopId,
  }) async {
    final company = command?.companyId ?? companyId!;
    final shop = command?.shopId ?? shopId!;
    final trust = await installation.readCompanyTrust(db);
    if (trust == null || trust.companyId.value != company) {
      throw const JobLineRefusal('company is not enrolled');
    }
    final factsRow =
        await (db.select(db.companyAuthorityFacts)..where(
              (t) =>
                  t.companyId.equals(company) &
                  t.commitment.equals(trust.factsCommitment),
            ))
            .getSingleOrNull();
    if (factsRow == null) {
      throw const JobLineRefusal('current company facts missing');
    }
    if (utf8.encode(factsRow.signedBytes).length > _maximumBytes) {
      throw const JobLineRefusal('company facts exceed byte limit');
    }
    final signed = _object(jsonDecode(factsRow.signedBytes));
    _keys(signed, {'body', 'signature'});
    final factsBody = _object(signed['body']);
    final v2 = factsBody['v'] == 2;
    _keys(factsBody, {
      'v',
      'company',
      if (v2) 'shop',
      if (v2) 'name',
      'authority',
      'policy',
      if (v2) 'recovery',
      if (v2 && factsBody.containsKey('rotation')) 'rotation',
      'devices',
      'users',
      'entities',
    });
    if (!(factsBody['v'] == 1 || v2) ||
        factsBody['company'] != company ||
        (v2 && factsBody['shop'] != shop) ||
        factsBody['authority'] != trust.authorityVersion ||
        factsBody['policy'] != trust.policy ||
        _digest(factsBody) != trust.factsCommitment) {
      throw const JobLineRefusal('company facts do not match protected pin');
    }
    if (v2) {
      final name = factsBody['name'];
      final recovery = _object(factsBody['recovery']);
      _keys(recovery, {'v', 'key', 'package'});
      if (name is! String ||
          name.trim().isEmpty ||
          name.length > 100 ||
          recovery['v'] != 1 ||
          recovery['package'] is! String ||
          !Uuid.isValidUUID(fromString: recovery['package'] as String) ||
          recovery['key'] is! String ||
          base64Decode(recovery['key'] as String).length != 32) {
        throw const JobLineRefusal('invalid company recovery facts');
      }
    }
    await _verifySignature(
      factsBody,
      _string(signed, 'signature'),
      SimplePublicKey(trust.rootKey, type: KeyPairType.ed25519),
      domain: v2 ? 'wiredpart.company.facts@2:' : '',
    );
    final facts = _CompanyFacts(factsBody);
    final floors = installation.knownSecurityFloors;
    bool allows(Map<String, Object?> value, String key, String item) =>
        value[key] is List && (value[key] as List).contains(item);
    final localIdentity = installation.identity!;
    final receiverDevices = factsBody['devices'];
    if (receiverDevices is! List || receiverDevices.length > 128) {
      throw const JobLineRefusal('unsupported company facts');
    }
    final localGrants = receiverDevices
        .map(_object)
        .where(
          (d) =>
              d['installation'] == localIdentity.id.value &&
              d['generation'] == localIdentity.generation.value &&
              d['key'] == base64Encode(localIdentity.publicKey),
        )
        .toList();
    if (localGrants.length != 1) {
      throw const JobLineRefusal('receiving installation membership denied');
    }
    final receiver = localGrants.single;
    _keys(receiver, {
      'id',
      'installation',
      'generation',
      'key',
      'grant',
      'version',
      'revoked',
      'shops',
      'capabilities',
    });
    final receiverId = _string(receiver, 'id');
    final receiverGrant = _string(receiver, 'grant');
    _id(receiverId);
    _id(receiverGrant);
    if (receiver['revoked'] != false ||
        !allows(receiver, 'shops', shop) ||
        receiver['version'] is! int ||
        (receiver['version'] as int) < 1 ||
        (receiver['version'] as int) < (floors['grant.$receiverGrant'] ?? 1) ||
        (floors['revocation.device.$receiverId'] ?? 0) > 0 ||
        (floors['revocation.grant.$receiverGrant'] ?? 0) > 0) {
      throw const JobLineRefusal('receiving installation membership denied');
    }
    if (factsBody['authority'] is! int ||
        (factsBody['authority'] as int) < 1 ||
        (factsBody['authority'] as int) < (floors['authority.$company'] ?? 0)) {
      throw const JobLineRefusal('authority version below protected floor');
    }
    if (command != null) facts.entity('jobLine', command.lineId, shop: shop);
    return _ReceiverAuthority(facts, trust, Map.unmodifiable(floors));
  }
}

Future<void> _verifySignature(
  Map<String, Object?> body,
  String encoded,
  SimplePublicKey publicKey, {
  String domain = '',
  int maximumBytes = _maximumBytes,
}) async {
  final bytes = base64Decode(encoded);
  if (bytes.length != 64 ||
      base64Encode(bytes) != encoded ||
      !await Ed25519().verify(
        utf8.encode('$domain${_canonical(body, maximumBytes: maximumBytes)}'),
        signature: Signature(bytes, publicKey: publicKey),
      )) {
    throw const JobLineRefusal('signature verification failed');
  }
}

JobLineCommand _commandFromOperation(_Operation operation) {
  final units = operation.units;
  JobLineMutation mutation;
  if (units.containsKey('lifecycle')) {
    mutation = const DeleteJobLine();
  } else {
    JobLineIdentity? identity;
    if (units.containsKey('identity')) {
      final value = _object(units['identity']);
      identity = value['part'] == null
          ? CustomJobLine(_string(value, 'custom'))
          : CatalogJobLine(
              _string(value, 'part'),
              brandVersionId: value['version'] as String?,
            );
    }
    JobLineQuantities? quantities;
    if (units.containsKey('quantities')) {
      final value = _object(units['quantities']);
      quantities = JobLineQuantities(
        needed: (value['needed'] as num).toDouble(),
        shopPull: (value['pull'] as num).toDouble(),
        unit: value['unit'] as String?,
      );
    }
    mutation = JobLinePatch(
      identity: identity,
      quantities: quantities,
      notes: units.containsKey('notes')
          ? SetField(units['notes'] as String?)
          : const Omitted(),
      customNotes: units.containsKey('customNotes')
          ? SetField(units['customNotes'] as String?)
          : const Omitted(),
    );
  }
  return JobLineCommand(
    companyId: operation.company,
    shopId: operation.shop,
    lineId: operation.line,
    requestId: operation.id,
    observedHeads: operation.parents,
    mutation: mutation,
  );
}
