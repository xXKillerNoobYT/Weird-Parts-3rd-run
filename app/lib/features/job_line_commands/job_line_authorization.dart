part of 'job_line_commands.dart';

/// Only the verifier in this library can construct a session. A valid carrier
/// or a caller-selected author cannot replace the original signed assertion.
final class VerifiedJobLineSession {
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

  /// The protected signer accepts only a complete operation covered by this
  /// opaque proof. Its signature domain cannot mint a login assertion.
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
    });
    if (assertion['v'] != 1) {
      throw const JobLineRefusal('unsupported authorization version');
    }
    final trust = await installation.readCompanyTrust(db);
    if (trust == null || trust.companyId.value != command.companyId) {
      throw const JobLineRefusal('company is not enrolled');
    }
    if (assertion['company'] != command.companyId ||
        assertion['shop'] != command.shopId ||
        assertion['line'] != command.lineId ||
        assertion['request'] != command.requestId ||
        assertion['command'] != command.commitment ||
        assertion['authority'] != trust.authorityVersion ||
        assertion['facts'] != trust.factsCommitment) {
      throw const JobLineRefusal('authorization scope or commitment differs');
    }
    final factsRow =
        await (db.select(db.companyAuthorityFacts)..where(
              (t) =>
                  t.companyId.equals(command.companyId) &
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
    _keys(factsBody, {
      'v',
      'company',
      'authority',
      'policy',
      'devices',
      'users',
      'entities',
    });
    if (factsBody['v'] != 1 ||
        factsBody['company'] != command.companyId ||
        factsBody['authority'] != trust.authorityVersion ||
        factsBody['policy'] != trust.policy ||
        _digest(factsBody) != trust.factsCommitment) {
      throw const JobLineRefusal('company facts do not match protected pin');
    }
    await _verifySignature(
      factsBody,
      _string(signed, 'signature'),
      SimplePublicKey(trust.rootKey, type: KeyPairType.ed25519),
    );
    final facts = _CompanyFacts(factsBody);
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
    final floors = installation.knownSecurityFloors;
    bool allows(Map<String, Object?> value, String key, String item) =>
        value[key] is List && (value[key] as List).contains(item);
    final localIdentity = installation.identity!;
    final localGrants = (factsBody['devices'] as List)
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
        !allows(receiver, 'shops', command.shopId) ||
        receiver['version'] is! int ||
        (receiver['version'] as int) < 1 ||
        (receiver['version'] as int) < (floors['grant.$receiverGrant'] ?? 1) ||
        (floors['revocation.device.$receiverId'] ?? 0) > 0 ||
        (floors['revocation.grant.$receiverGrant'] ?? 0) > 0) {
      throw const JobLineRefusal('receiving installation membership denied');
    }
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
    await _verifySignature(assertion, _string(proof, 'signature'), publicKey);
    facts.entity('jobLine', command.lineId, shop: command.shopId);
    return VerifiedJobLineSession._(
      command,
      proof,
      facts,
      trust,
      Map.unmodifiable(floors),
      publicKey,
    );
  }
}

Future<void> _verifySignature(
  Map<String, Object?> body,
  String encoded,
  SimplePublicKey publicKey, {
  String domain = '',
}) async {
  final bytes = base64Decode(encoded);
  if (bytes.length != 64 ||
      !await Ed25519().verify(
        utf8.encode('$domain${_canonical(body)}'),
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
