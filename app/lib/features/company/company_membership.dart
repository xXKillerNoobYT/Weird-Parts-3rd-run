part of '../installation/installation_security.dart';

final class ResolvedCompanyMembership {
  ResolvedCompanyMembership._(
    this._user,
    this._device,
    this.proofCommitment,
    this.certificateBytes,
  );
  final String _user;
  final String _device;
  final String proofCommitment;
  final String? certificateBytes;
  Map<String, Object?> get user =>
      Map<String, Object?>.from(jsonDecode(_user) as Map);
  Map<String, Object?> get device =>
      Map<String, Object?>.from(jsonDecode(_device) as Map);
}

void _joinVersion(Object? value) {
  if (value is! int || value < 1 || value > 9007199254740991) {
    throw const CompanyBootstrapRefusal('Unsupported Join version');
  }
}

void _joinHash(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const CompanyBootstrapRefusal('Invalid Join commitment');
  }
}

Future<void> _joinVerify(
  Map<String, Object?> body,
  Object? signature,
  Object? key,
  String domain,
) async {
  if (signature is! String ||
      signature.length != 88 ||
      key is! String ||
      key.length != 44) {
    throw const CompanyBootstrapRefusal('Invalid Join signature');
  }
  final public = base64Decode(key);
  final bytes = base64Decode(signature);
  if (public.length != 32 ||
      bytes.length != 64 ||
      !await Ed25519().verify(
        utf8.encode('$domain${_securityCanonical(body)}'),
        signature: Signature(
          bytes,
          publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
        ),
      )) {
    throw const CompanyBootstrapRefusal('Join signature refused');
  }
}

void _memberFloors(
  Map<String, Object?> user,
  Map<String, Object?> device,
  CompanyTrustAnchor trust,
  Map<String, int> floors,
) {
  for (final entry in {
    'authority.${trust.companyId.value}': trust.authorityVersion,
    'grant.${device['grant']}': device['version'],
    'credential.${user['id']}': user['credential'],
    'permission.${user['id']}': user['permission'],
  }.entries) {
    _joinVersion(entry.value);
    if ((entry.value as int) < (floors[entry.key] ?? 0)) {
      throw const CompanyBootstrapRefusal(
        'Membership is below a protected floor',
      );
    }
  }
  if (user['revoked'] != false ||
      device['revoked'] != false ||
      (floors['revocation.user.${user['id']}'] ?? 0) > 0 ||
      (floors['revocation.device.${device['id']}'] ?? 0) > 0 ||
      (floors['revocation.grant.${device['grant']}'] ?? 0) > 0) {
    throw const CompanyBootstrapRefusal('Membership is known revoked');
  }
}

Future<Map<String, dynamic>> _membershipAuthority(
  AppDatabase db,
  CompanyTrustAnchor trust,
) async {
  final rows = await (db.select(
    db.companyAuthorityFacts,
  )..where((t) => t.companyId.equals(trust.companyId.value))).get();
  final current = rows
      .where((r) => r.commitment == trust.factsCommitment)
      .single;
  return _verifyFactLineage(
    current: current.signedBytes,
    currentRoot: trust.rootKey,
    lineage: rows.where((r) => r != current).map((r) => r.signedBytes).toList(),
  );
}

Future<ResolvedCompanyMembership> _resolveMemberCertificate(
  String bytes,
  Map<String, dynamic> authority,
  CompanyTrustAnchor trust,
  Map<String, int> floors,
) async {
  if (bytes.length > 4096 || utf8.encode(bytes).length > 4096) {
    throw const CompanyBootstrapRefusal(
      'Membership certificate capacity reached',
    );
  }
  final signed = _joinObject(jsonDecode(bytes), {'body', 'signature'});
  if (_securityCanonical(signed) != bytes) {
    throw const CompanyBootstrapRefusal('Noncanonical membership certificate');
  }
  final body = _joinObject(signed['body'], {
    'v',
    'kind',
    'depth',
    'parent',
    'company',
    'shop',
    'authority',
    'facts',
    'issuer',
    'recipient',
    'request',
    'requestCommitment',
    'sequence',
    'previous',
    'delegable',
  });
  if (body['v'] != 1 ||
      body['kind'] != 'company.device.enroll@1' ||
      body['depth'] != 1 ||
      body['delegable'] != false ||
      body['parent'] != trust.factsCommitment ||
      body['facts'] != trust.factsCommitment ||
      body['authority'] != trust.authorityVersion ||
      body['company'] != trust.companyId.value ||
      body['shop'] != authority['shop'] ||
      trust.policy != 'localContinuity') {
    throw const CompanyBootstrapRefusal(
      'Membership authority or scope differs',
    );
  }
  _joinId(body, 'request');
  _joinHash(body['requestCommitment']);
  _joinVersion(body['sequence']);
  if (body['previous'] != null) _joinHash(body['previous']);
  final issuer = _joinObject(body['issuer'], {
    'kind',
    'device',
    'grant',
    'version',
    'installation',
    'generation',
    'key',
  });
  final rootDevice = Map<String, Object?>.from(
    (authority['devices'] as List).single as Map,
  );
  final user = Map<String, Object?>.from(
    (authority['users'] as List).single as Map,
  );
  if (issuer['kind'] != 'rootFacts@2' || issuer['device'] != rootDevice['id']) {
    throw const CompanyBootstrapRefusal('Unsupported enrollment issuer');
  }
  for (final field in [
    'grant',
    'version',
    'installation',
    'generation',
    'key',
  ]) {
    if (issuer[field] != rootDevice[field]) {
      throw const CompanyBootstrapRefusal('Enrollment issuer binding differs');
    }
  }
  _memberFloors(user, rootDevice, trust, floors);
  bool permits(Map<String, Object?> entry, String cap) =>
      entry['capabilities'] is List &&
      (entry['capabilities'] as List).contains(cap);
  if (!permits(user, 'enrollDevice') || !permits(rootDevice, 'enrollDevice')) {
    throw const CompanyBootstrapRefusal('Enrollment permission denied');
  }
  final recipient = _joinObject(body['recipient'], {
    'device',
    'grant',
    'version',
    'installation',
    'generation',
    'key',
    'user',
    'credential',
    'permission',
    'shops',
    'capabilities',
  });
  for (final field in [
    'device',
    'grant',
    'installation',
    'generation',
    'user',
  ]) {
    _joinId(recipient, field);
  }
  final key = _joinString(recipient, 'key', maximum: 44);
  if (base64Decode(key).length != 32 ||
      recipient['version'] != 1 ||
      recipient['user'] != user['id'] ||
      recipient['credential'] != user['credential'] ||
      recipient['permission'] != user['permission'] ||
      _securityCanonical(recipient['shops']) !=
          _securityCanonical([authority['shop']])) {
    throw const CompanyBootstrapRefusal(
      'Membership user or recipient binding differs',
    );
  }
  final capabilities = recipient['capabilities'];
  if (capabilities is! List ||
      capabilities.length > 4 ||
      capabilities.toSet().length != capabilities.length ||
      capabilities.any(
        (c) =>
            ![
              'createJob',
              'renameJob',
              'editJobDetails',
              'manageJobLifecycle',
            ].contains(c) ||
            !permits(user, c as String) ||
            !permits(rootDevice, c),
      )) {
    throw const CompanyBootstrapRefusal(
      'Membership capabilities exceed issuer',
    );
  }
  final device = <String, Object?>{
    'id': recipient['device'],
    'grant': recipient['grant'],
    'version': recipient['version'],
    'installation': recipient['installation'],
    'generation': recipient['generation'],
    'key': key,
    'revoked': false,
    'shops': recipient['shops'],
    'capabilities': capabilities,
  };
  _memberFloors(user, device, trust, floors);
  await _joinVerify(
    body,
    signed['signature'],
    rootDevice['key'],
    'wiredpart.company.device.enroll@1:',
  );
  return ResolvedCompanyMembership._(
    _securityCanonical(user),
    _securityCanonical(device),
    _joinDigest(signed),
    bytes,
  );
}

Future<ResolvedCompanyMembership> resolveCompanyMembership({
  required AppDatabase db,
  required InstallationSecurity installation,
  String? certificateBytes,
}) async {
  final trust = await installation.readCompanyTrust(db);
  if (trust == null) {
    throw const CompanyBootstrapRefusal('Company trust unavailable');
  }
  final authority = await _membershipAuthority(db, trust);
  if (certificateBytes == null) {
    final custody = await CompanyEnrollment(
      installation: installation,
      db: db,
    )._readCustody();
    if (custody?.values['v'] == 2) {
      final certificate =
          await (db.select(db.companyMembershipCertificates)..where(
                (t) => t.proofCommitment.equals(
                  custody!.values['certificate'] as String,
                ),
              ))
              .getSingle();
      certificateBytes = certificate.proofBytes;
    }
  }
  if (certificateBytes != null) {
    return _resolveMemberCertificate(
      certificateBytes,
      authority,
      trust,
      installation.knownSecurityFloors,
    );
  }
  final user = Map<String, Object?>.from(
    (authority['users'] as List).single as Map,
  );
  final device = Map<String, Object?>.from(
    (authority['devices'] as List).single as Map,
  );
  final identity = installation.identity!;
  if (device['installation'] != identity.id.value ||
      device['generation'] != identity.generation.value ||
      device['key'] != base64Encode(identity.publicKey)) {
    throw const CompanyBootstrapRefusal('Local membership is absent');
  }
  _memberFloors(user, device, trust, installation.knownSecurityFloors);
  return ResolvedCompanyMembership._(
    _securityCanonical(user),
    _securityCanonical(device),
    trust.factsCommitment,
    null,
  );
}
