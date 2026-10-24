part of '../installation/installation_security.dart';

const _userStateDomain = 'wiredpart.company.user.state@1:';
const _userStateReceiptDomain = 'wiredpart.company.user.state.receipt@1:';

enum CompanyUserStateStatus { active, awaitingCredential, disabled }

enum CompanyUserStateTransition { duplicate, replacement, disabled }

List<Object?> _stateTuple(Object? value, int length) {
  if (value is! List || value.length != length) {
    throw const CompanyBootstrapRefusal('Invalid user state tuple');
  }
  return List<Object?>.from(value);
}

void _stateId(Object? value) => _joinId({'id': value}, 'id');

/// Verified public data only. It does not grant a session or authorize a write.
final class CompanyUserStateCertificate {
  CompanyUserStateCertificate._(this._bytes, this.originalCertificateBytes);
  final String _bytes;
  final String originalCertificateBytes;
  String get certificateBytes => _bytes;
  List<Object?> get _packed => List<Object?>.from(jsonDecode(_bytes) as List);
  List<Object?> get _body => List<Object?>.from(_packed[0] as List);
  String get userId => _body[5] as String;
  int get sequence => _body[8] as int;
  int get credentialVersion => _body[9] as int;
  bool get disabled => _body[12] == 1;
  String get requestId => _body[13] as String;
  String get lastPinResetRequest => _body[14] as String;
  String get previousPublicHead => _body[15] as String;
  String get publicHead => _joinDigest(jsonDecode(_bytes));

  static Future<CompanyUserStateCertificate> verify(
    String bytes, {
    required AppDatabase db,
    required CompanyTrustAnchor trust,
    required Map<String, int> floors,
  }) async {
    try {
      final currentFloors = Map<String, int>.unmodifiable(floors);
      if (utf8.encode(bytes).length > 1024) {
        throw const CompanyBootstrapRefusal('User state certificate full');
      }
      final packed = _stateTuple(_decodeUserJson(bytes), 2);
      final body = _stateTuple(packed[0], 16);
      final origin = _stateTuple(body[7], 6);
      if (_securityCanonical(packed) != bytes ||
          body[0] is! int ||
          body[0] != 2 ||
          body[1] != trust.companyId.value ||
          body[3] != trust.authorityVersion ||
          body[4] != trust.factsCommitment ||
          body[10] is! int ||
          body[10] != 1 ||
          _securityCanonical(body[11]) != '["createJob"]' ||
          body[12] is! int ||
          (body[12] != 0 && body[12] != 1)) {
        throw const CompanyBootstrapRefusal('User state scope differs');
      }
      for (final index in [1, 2, 5, 13, 14]) {
        _stateId(body[index]);
      }
      for (final index in [0, 1, 2]) {
        _stateId(origin[index]);
      }
      for (final value in [body[3], origin[3], body[8], body[9]]) {
        _joinVersion(value);
      }
      _joinHash(body[4]);
      _joinHash(origin[4]);
      _joinHash(body[15]);
      _userBase64(origin[5], 64);
      _userBase64(packed[1], 64);
      _validateUserName(body[6] as String);
      if ((body[9] as int) < 2 ||
          (body[12] == 0 && (body[9] as int) >= 9007199254740991) ||
          (body[12] == 0 && body[8] != body[9]) ||
          (body[12] == 1 && body[8] != (body[9] as int) + 1) ||
          body[13] == origin[2] ||
          body[14] == origin[2] ||
          (body[12] == 0 && body[13] != body[14]) ||
          (body[12] == 1 && body[13] == body[14])) {
        throw const CompanyBootstrapRefusal('User state epoch differs');
      }
      final original = _securityCanonical({
        'body': {
          'v': 1,
          'kind': 'company.user.authority@1',
          'company': body[1],
          'shop': body[2],
          'authority': origin[3],
          'facts': origin[4],
          'user': body[5],
          'name': body[6],
          'credential': 1,
          'permission': 1,
          'capabilities': ['createJob'],
          'request': origin[2],
          'issuer': origin[0],
          'device': origin[1],
        },
        'signature': origin[5],
      });
      // Creation provenance is historical; current credential floors are checked
      // against the new signed epoch below, never against this epoch-one proof.
      final originFloors = Map<String, int>.from(currentFloors)
        ..remove('credential.${body[5]}')
        ..remove('permission.${body[5]}');
      final creation = await _resolveUserAuthority(
        db,
        trust,
        originFloors,
        original,
      );
      if (!await _joinProofVerifier.verify(
        domain: _userStateDomain,
        canonicalBody: () => _securityCanonical(body),
        publicKeyText: base64Encode(trust.rootKey),
        signatureText: packed[1] as String,
      )) {
        throw const CompanyBootstrapRefusal('User state signature refused');
      }
      final authority = await _membershipAuthority(db, trust);
      _memberFloors(
        {...creation.user, 'credential': body[9]},
        Map<String, Object?>.from((authority['devices'] as List).single as Map),
        trust,
        currentFloors,
      );
      return CompanyUserStateCertificate._(bytes, original);
    } catch (_) {
      throw const CompanyBootstrapRefusal('User state certificate refused');
    }
  }

  CompanyUserStateTransition validateSuccessor(
    CompanyUserStateCertificate prior,
  ) {
    if (_bytes == prior._bytes) return CompanyUserStateTransition.duplicate;
    if (prior.disabled ||
        originalCertificateBytes != prior.originalCertificateBytes ||
        sequence != prior.sequence + 1 ||
        previousPublicHead != prior.publicHead ||
        requestId == prior.requestId) {
      throw const CompanyBootstrapRefusal('User state successor refused');
    }
    if (disabled) {
      if (credentialVersion != prior.credentialVersion ||
          lastPinResetRequest != prior.lastPinResetRequest) {
        throw const CompanyBootstrapRefusal('Terminal user state differs');
      }
      return CompanyUserStateTransition.disabled;
    }
    if (credentialVersion != prior.credentialVersion + 1 ||
        lastPinResetRequest != requestId) {
      throw const CompanyBootstrapRefusal('User credential successor refused');
    }
    return CompanyUserStateTransition.replacement;
  }
}

/// An unwired protected codec. Persistence, journal recovery and auth admission
/// remain separate; decoding this value does not apply a credential transition.
final class CompanyUserStateRecord {
  CompanyUserStateRecord._(this._text, this.certificate, this.status);
  final String _text;
  final CompanyUserStateCertificate certificate;
  final CompanyUserStateStatus status;
  int get attemptsRemaining => (jsonDecode(_text) as Map)['a'] as int;
  Uint8List encode() => Uint8List.fromList(utf8.encode(_text));

  CompanyUserStateTransition validateSuccessor(CompanyUserStateRecord prior) {
    final transition = certificate.validateSuccessor(prior.certificate);
    final current = jsonDecode(_text) as Map;
    final previous = jsonDecode(prior._text) as Map;
    if (_securityCanonical(current['b']) != _securityCanonical(previous['b']) ||
        (transition == CompanyUserStateTransition.replacement &&
            attemptsRemaining != _companyAttempts) ||
        (transition == CompanyUserStateTransition.disabled &&
            attemptsRemaining != prior.attemptsRemaining) ||
        (transition == CompanyUserStateTransition.duplicate &&
            (attemptsRemaining > prior.attemptsRemaining ||
                (previous['p'] != null &&
                    _securityCanonical(current['p']) !=
                        _securityCanonical(previous['p'])) ||
                (previous['o'] != null &&
                    _securityCanonical(current['o']) !=
                        _securityCanonical(previous['o']))))) {
      throw const CompanyBootstrapRefusal('Protected user successor refused');
    }
    return transition;
  }

  static Future<CompanyUserStateRecord> decode(
    Uint8List bytes, {
    required AppDatabase db,
    required InstallationSecurity installation,
  }) async {
    try {
      if (bytes.length > kInstallationStateLimit) {
        throw const CompanyBootstrapRefusal('Protected user state full');
      }
      final text = _decodeUserUtf8(bytes);
      final value = _joinObject(_decodeUserJson(text), {
        'v',
        'c',
        'b',
        'p',
        'a',
        'o',
        'r',
        'j',
      });
      if (_securityCanonical(value) != text ||
          value['v'] is! int ||
          value['v'] != 3 ||
          value['a'] is! int ||
          (value['a'] as int) < 0 ||
          (value['a'] as int) > _companyAttempts ||
          installation.readiness != InstallationReadiness.ready) {
        throw const CompanyBootstrapRefusal('Protected user state differs');
      }
      final binding = _stateTuple(value['b'], 4);
      if (_securityCanonical(binding) !=
          _securityCanonical([
            installation.identity!.id.value,
            installation.identity!.generation.value,
            base64Encode(installation.identity!.publicKey),
            installation.receivingStoreGeneration!.value,
          ])) {
        throw const CompanyBootstrapRefusal('User state installation differs');
      }
      final trust = await installation.readCompanyTrust(db);
      if (trust == null) {
        throw const CompanyBootstrapRefusal('Company trust missing');
      }
      final certificate = await CompanyUserStateCertificate.verify(
        _securityCanonical(value['c']),
        db: db,
        trust: trust,
        floors: installation.knownSecurityFloors,
      );
      final credential = value['p'];
      if (credential != null) {
        final pin = _stateTuple(credential, 3);
        if (pin[0] is! int || pin[0] != 1 || certificate.disabled) {
          throw const CompanyBootstrapRefusal('User secret profile differs');
        }
        _userBase64(pin[1], 16);
        _userBase64(pin[2], 32);
      }
      final outgoing = value['o'];
      if (outgoing != null) {
        final target = _stateTuple(outgoing, 8);
        if (target[0] is! int ||
            (target[0] != 0 && target[0] != 1) ||
            target[1] != certificate.requestId) {
          throw const CompanyBootstrapRefusal('User state delivery differs');
        }
        for (final index in [1, 2, 3, 4, 6, 7]) {
          _stateId(target[index]);
        }
        _userBase64(target[5], 32);
      }
      if (value['r'] != null) {
        if (outgoing == null) {
          throw const CompanyBootstrapRefusal('User receipt target missing');
        }
        _userBase64(value['r'], 64);
        final local = CompanyEnrollment(installation: installation, db: db)
            ._userPeerBinding(
              await resolveCompanyMembership(
                db: db,
                installation: installation,
              ),
              installation.receivingStoreGeneration!.value,
            );
        final target = outgoing as List;
        final source = target[0] == 0 ? local : target.skip(2).toList();
        final recipient = target[0] == 0 ? target.skip(2).toList() : local;
        await _joinVerify(
          {
            'v': 1,
            'kind': 'company.user.state.receipt@1',
            'certificate': certificate.publicHead,
            'request': certificate.requestId,
            'source': source,
            'recipient': recipient,
          },
          value['r'],
          recipient[3],
          _userStateReceiptDomain,
        );
      }
      if (value['j'] != null) {
        final projection = _stateTuple(value['j'], 2);
        _joinHash(projection[0]);
        _joinVersion(projection[1]);
        if ((projection[1] as int) >= certificate.sequence ||
            (projection[1] == certificate.sequence - 1 &&
                projection[0] != certificate.previousPublicHead)) {
          throw const CompanyBootstrapRefusal('Projection predecessor differs');
        }
      }
      return CompanyUserStateRecord._(
        text,
        certificate,
        certificate.disabled
            ? CompanyUserStateStatus.disabled
            : credential == null
            ? CompanyUserStateStatus.awaitingCredential
            : CompanyUserStateStatus.active,
      );
    } catch (_) {
      throw const CompanyBootstrapRefusal('Protected user state refused');
    }
  }
}
