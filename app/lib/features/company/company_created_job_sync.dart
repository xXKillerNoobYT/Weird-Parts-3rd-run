part of '../installation/installation_security.dart';

final class CompanyJobSyncAvailability implements NearbyCompanyDisclosure {
  CompanyJobSyncAvailability._(this.enrollment, this.owner, this.peer);
  final CompanyEnrollment enrollment;
  final OwnerSession owner;
  final VerifiedPeerMembership peer;
  bool _open = true;

  static Future<CompanyJobSyncAvailability> open({
    required CompanyEnrollment enrollment,
    required OwnerSession owner,
    required VerifiedPeerMembership peer,
  }) async {
    final result = CompanyJobSyncAvailability._(enrollment, owner, peer);
    await result.requireCurrent();
    return result;
  }

  void close() => _open = false;
  @override
  void requireLive() {
    if (!_open ||
        !identical(enrollment.currentSession, owner) ||
        !identical(peer._held.owner, owner) ||
        !identical(peer._owner.enrollment, enrollment)) {
      throw const CompanyBootstrapRefusal('Manual Job sync is unavailable');
    }
    if (!identical(peer._owner._exchange, peer._held)) {
      throw const CompanyBootstrapRefusal('Retained peer context changed');
    }
    peer._held.channel._requireLive();
  }

  @override
  Future<void> requireCurrent() async {
    requireLive();
    await peer.requireJobSyncPermission();
    requireLive();
  }
}

const _syncKind = 'created-jobs';
const _syncProtocol = 'company.job.create.sync@1';
const _syncAckDomain = 'wiredpart.company.job.create.ack@1:';
const kCreatedJobSyncChunkBytes = 24 * 1024;

final class CreatedJobTransferBuffer {
  CreatedJobTransferBuffer({required this.length, required this.digest}) {
    if (length < 1 || length > 65536) {
      throw const CompanyBootstrapRefusal('Job reassembly byte limit');
    }
    _joinHash(digest);
  }
  final int length;
  final String digest;
  final List<int> _bytes = [];
  int get receivedBytes => _bytes.length;
  bool get complete => receivedBytes == length;
  Uint8List get bytes {
    if (!complete || _syncBytesDigest(_bytes) != digest) {
      throw const CompanyBootstrapRefusal('Job reassembly is incomplete');
    }
    return Uint8List.fromList(_bytes);
  }

  void append(Object? offset, Object? encoded) {
    if (offset != receivedBytes ||
        complete ||
        encoded is! String ||
        encoded.isEmpty ||
        encoded.length > 32768) {
      throw const CompanyBootstrapRefusal(
        'Job chunk gap, overlap or byte limit',
      );
    }
    final chunk = base64Decode(encoded);
    if (chunk.isEmpty ||
        chunk.length > kCreatedJobSyncChunkBytes ||
        base64Encode(chunk) != encoded ||
        receivedBytes + chunk.length > length) {
      throw const CompanyBootstrapRefusal(
        'Invalid Job chunk or reassembly overflow',
      );
    }
    _bytes.addAll(chunk);
    if (complete && _syncBytesDigest(_bytes) != digest) {
      throw const CompanyBootstrapRefusal('Job digest differs');
    }
  }
}

String _syncDigest(Object? value) => _joinDigest(value);
String _syncBytesDigest(List<int> bytes) =>
    hashes.sha256.convert(bytes).toString();
String _descriptorKey(Map<String, Object?> descriptor) =>
    '${descriptor['origin']}/${descriptor['request']}';

Map<String, Object?> _jobDescriptor(CompanyJob row) {
  final body = (jsonDecode(row.operationBytes) as Map)['body'] as Map;
  return {
    'origin': row.originGeneration,
    'request': row.requestId,
    'job': row.jobId,
    'author': body['device'],
    'installation': body['installation'],
    'operation': row.operationCommitment,
    'command': row.commandCommitment,
    'digest': _syncBytesDigest(utf8.encode(row.operationBytes)),
    'length': utf8.encode(row.operationBytes).length,
  };
}

Map<String, Object?> _parseDescriptor(Object? value) {
  final result = _joinObject(value, {
    'origin',
    'request',
    'job',
    'author',
    'installation',
    'operation',
    'command',
    'digest',
    'length',
  });
  for (final key in ['origin', 'request', 'job', 'author', 'installation']) {
    _joinId(result, key);
  }
  for (final key in ['operation', 'command', 'digest']) {
    _joinHash(result[key]);
  }
  if (result['length'] is! int ||
      (result['length'] as int) < 1 ||
      (result['length'] as int) > 65536 ||
      utf8.encode(_securityCanonical(result)).length > 1024) {
    throw const CompanyBootstrapRefusal('Job descriptor capacity exceeded');
  }
  return result;
}

final class CreatedJobHoldingsInventory {
  CreatedJobHoldingsInventory.local(List<CompanyJob> records) {
    descriptors = records.map(_jobDescriptor).map(_parseDescriptor).toList()
      ..sort((a, b) => _descriptorKey(a).compareTo(_descriptorKey(b)));
    if (descriptors.length > 512) {
      throw const CompanyBootstrapRefusal('Job inventory capacity exceeded');
    }
    count = descriptors.length;
    digest = _syncDigest(descriptors);
    _validateComplete();
  }
  CreatedJobHoldingsInventory.remote(Object? raw) {
    final meta = _joinObject(raw, {'count', 'pages', 'digest'});
    if (meta['count'] is! int ||
        (meta['count'] as int) < 0 ||
        (meta['count'] as int) > 512 ||
        meta['pages'] != ((meta['count'] as int) + 31) ~/ 32) {
      throw const CompanyBootstrapRefusal('Invalid inventory framing');
    }
    _joinHash(meta['digest']);
    count = meta['count'] as int;
    digest = meta['digest'] as String;
    descriptors = [];
    if (count == 0) _validateComplete();
  }
  late List<Map<String, Object?>> descriptors;
  late int count;
  late String digest;
  int _receivedPages = 0;
  int _aggregateBytes = 0;
  bool _validated = false;
  final List<String?> _peerAckStores = [];
  String? peerAckStore(String key) {
    final index = descriptors.indexWhere((d) => _descriptorKey(d) == key);
    return index < 0 || index >= _peerAckStores.length
        ? null
        : _peerAckStores[index];
  }

  int get pages => (count + 31) ~/ 32;
  bool get complete => _validated;
  Map<String, Object?> get meta => {
    'count': count,
    'pages': pages,
    'digest': digest,
  };
  List<Map<String, Object?>> page(int ordinal) {
    if (ordinal < 0 || ordinal >= pages || !complete) {
      throw const CompanyBootstrapRefusal('Invalid inventory page');
    }
    return descriptors.skip(ordinal * 32).take(32).toList();
  }

  void acceptPage(Object? raw) {
    final page = _joinObject(raw, {
      'ordinal',
      'digest',
      'items',
      'confirmedStores',
    });
    if (page['ordinal'] != _receivedPages ||
        page['digest'] != digest ||
        _receivedPages >= pages ||
        page['items'] is! List) {
      throw const CompanyBootstrapRefusal(
        'Duplicate or conflicting inventory page',
      );
    }
    final items = page['items'] as List;
    final stores = page['confirmedStores'];
    if (stores is! List ||
        stores.length != items.length ||
        stores.any(
          (s) =>
              s != null && (s is! String || !Uuid.isValidUUID(fromString: s)),
        )) {
      throw const CompanyBootstrapRefusal(
        'Invalid bounded ACK checkpoint page',
      );
    }
    final bytes = utf8.encode(_securityCanonical(page)).length;
    _aggregateBytes += bytes;
    if (items.length !=
            (count - descriptors.length > 32
                ? 32
                : count - descriptors.length) ||
        bytes > 33 * 1024 ||
        _aggregateBytes > 528 * 1024) {
      throw const CompanyBootstrapRefusal(
        'Inventory aggregate capacity exceeded',
      );
    }
    descriptors.addAll(items.map(_parseDescriptor));
    _peerAckStores.addAll(stores.cast<String?>());
    _receivedPages++;
    if (_receivedPages == pages) _validateComplete();
  }

  void _validateComplete() {
    final keys = descriptors.map(_descriptorKey).toList();
    final sorted = [...keys]..sort();
    if (descriptors.length != count ||
        keys.toSet().length != count ||
        descriptors.map((d) => d['job']).toSet().length != count ||
        _securityCanonical(keys) != _securityCanonical(sorted) ||
        _syncDigest(descriptors) != digest) {
      throw const CompanyBootstrapRefusal(
        'Inventory identity or digest differs',
      );
    }
    _validated = true;
  }

  Map<String, Map<String, Object?>> get byKey => {
    for (final d in descriptors) _descriptorKey(d): d,
  };
}

enum CreatedJobSyncStage {
  preflight,
  channel,
  channelOpen,
  replySeal,
  localInventory,
  startRequest,
  holdings,
  transfer,
  confirmation,
}

enum CreatedJobSyncReason {
  unavailable,
  verificationChanged,
  moreJobsPending,
  unconfirmedSnapshot,
  unsupportedAuthor,
  timeout,
  transportRejected,
  transportUnavailable,
  refused,
  unexpected,
}

final class CreatedJobSyncFailure {
  const CreatedJobSyncFailure(this.stage, this.reason);

  factory CreatedJobSyncFailure.fromError(
    Object error,
    CreatedJobSyncStage stage,
  ) {
    final reason = switch (error) {
      CompanyBootstrapRefusal(:final message) => switch (message) {
        'Manual Job sync is unavailable' ||
        'Enable manual Job sync first' ||
        'Join is closed' ||
        'Join connection changed' => CreatedJobSyncReason.unavailable,
        'Retained peer context changed' =>
          CreatedJobSyncReason.verificationChanged,
        'More Jobs pending' ||
        'More Jobs pending; pair again' ||
        'Job sync channel budget exhausted' ||
        'Job sync frame ceiling reached' =>
          CreatedJobSyncReason.moreJobsPending,
        'Peer claimed an unconfirmed Job snapshot' =>
          CreatedJobSyncReason.unconfirmedSnapshot,
        _ => CreatedJobSyncReason.refused,
      },
      TimeoutException() => CreatedJobSyncReason.timeout,
      NearbyException() => CreatedJobSyncReason.transportRejected,
      SocketException() => CreatedJobSyncReason.transportUnavailable,
      _ => CreatedJobSyncReason.unexpected,
    };
    return CreatedJobSyncFailure(stage, reason);
  }

  final CreatedJobSyncStage stage;
  final CreatedJobSyncReason reason;
  String get message => 'Stage ${stage.name}. Reason ${reason.name}.';
}

enum CreatedJobSyncDiagnosticKind { started, receiverEntered, terminal }

final class CreatedJobSyncDiagnostic {
  const CreatedJobSyncDiagnostic.started({this.receiverCallbackReached = false})
    : kind = CreatedJobSyncDiagnosticKind.started,
      result = null;
  const CreatedJobSyncDiagnostic.receiverEntered()
    : kind = CreatedJobSyncDiagnosticKind.receiverEntered,
      receiverCallbackReached = true,
      result = null;
  const CreatedJobSyncDiagnostic.terminal(
    CreatedJobSyncResult this.result, {
    this.receiverCallbackReached = false,
  }) : kind = CreatedJobSyncDiagnosticKind.terminal;

  final CreatedJobSyncDiagnosticKind kind;
  final bool receiverCallbackReached;
  final CreatedJobSyncResult? result;

  void notify(void Function(CreatedJobSyncDiagnostic)? observer) {
    try {
      observer?.call(this);
    } catch (_) {
      // Observing a result must not change admission or drain behavior.
    }
  }
}

final class CreatedJobSyncResult {
  const CreatedJobSyncResult(
    this.sent,
    this.received,
    this.complete,
    this.unsupported, {
    this.failure,
  });
  final int sent;
  final int received;
  final bool complete;
  final int unsupported;
  final CreatedJobSyncFailure? failure;
  String get message => complete
      ? 'Job snapshot synced. Sent $sent, received $received.'
      : 'Job sync incomplete. Confirmed sent $sent, received $received. Pair again and retry Sync Now.${unsupported > 0 ? ' Unsupported author scope remains pending.' : ''}${failure == null ? '' : ' ${failure!.message}'}';
}

final class CompanyCreatedJobSync {
  static Future<Map<String, int>> confirmedPeerCounts(
    CompanyEnrollment enrollment,
    OwnerSession owner,
  ) async {
    final records = await CompanyJobCommands(enrollment: enrollment)
        .syncHoldings(ownerSession: owner);
    final peers = await CompanyPeerAuthentication(enrollment: enrollment)
        .retainedPeers(session: owner);
    final members = {for (final p in peers) p.deviceId: p._membership};
    final descriptors = {
      for (final r in records)
        _descriptorKey(_jobDescriptor(r)): _jobDescriptor(r),
    };
    final rows =
        await (enrollment.db.select(enrollment.db.companyJobPeerAcks)
              ..where((t) => t.companyId.equals(owner.identity.companyId))
              ..limit(65537))
            .get();
    if (rows.length > 65536) {
      throw const CompanyBootstrapRefusal('Job ACK history capacity exceeded');
    }
    final counts = <String, int>{};
    for (final row in rows) {
      final member = members[row.peerDeviceId];
      final descriptor =
          descriptors['${row.originGeneration}/${row.requestId}'];
      if (member == null || descriptor == null) continue;
      if (row.operationDigest != descriptor['digest'] ||
          utf8.encode(row.ackBytes).length > 4096) {
        throw const CompanyBootstrapRefusal('Saved Job ACK differs');
      }
      final signed = _joinObject(jsonDecode(row.ackBytes), {
        'body',
        'signature',
      });
      final body = _joinObject(signed['body'], {
        'v',
        'kind',
        'descriptor',
        'receiver',
        'generation',
        'store',
        'receipt',
      });
      _joinId(body, 'store');
      _joinHash(body['receipt']);
      if (body['v'] != 1 ||
          body['kind'] != 'company.job.create.ack@1' ||
          body['receiver'] != member.device['installation'] ||
          body['generation'] != member.device['generation'] ||
          _securityCanonical(body['descriptor']) !=
              _securityCanonical(descriptor)) {
        throw const CompanyBootstrapRefusal('Saved Job ACK binding differs');
      }
      await _joinVerify(
        body,
        signed['signature'],
        member.device['key'],
        _syncAckDomain,
      );
      counts.update(
        descriptor['job'] as String,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
    await CompanyJobCommands(enrollment: enrollment)
        .requireSyncPermission(owner);
    return counts;
  }

  CompanyCreatedJobSync({
    required this.availability,
    required this.controller,
    this.onStatus,
    this.onDiagnostic,
    this.chunkBytes = kCreatedJobSyncChunkBytes,
  }) {
    if (chunkBytes < 1 || chunkBytes > kCreatedJobSyncChunkBytes) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes');
    }
    controller.companySyncDisclosure = availability;
  }
  final CompanyJobSyncAvailability availability;
  final NearbyController controller;
  final void Function(String)? onStatus;
  final void Function(CreatedJobSyncDiagnostic)? onDiagnostic;
  final int chunkBytes;
  Object? lastFailure;

  void _status(String message) {
    try {
      onStatus?.call(message);
    } catch (_) {
      // Status observers cannot change the sync result.
    }
  }

  void _terminal(CreatedJobSyncResult result, {bool receiving = false}) {
    if (!receiving || !_busy) _status(result.message);
    CreatedJobSyncDiagnostic.terminal(
      result,
      receiverCallbackReached: receiving,
    ).notify(onDiagnostic);
  }

  bool get isLive {
    if (_closed) return false;
    try {
      availability.requireLive();
      return true;
    } catch (_) {
      return false;
    }
  }

  CompanyJobCommands get _commands =>
      CompanyJobCommands(enrollment: availability.enrollment);
  AppDatabase get _db => availability.enrollment.db;
  InstallationSecurity get _installation =>
      availability.enrollment.installation;
  Future<NearbyJoinChannel>? _channelPending;
  CreatedJobHoldingsInventory? _local;
  CreatedJobHoldingsInventory? _remote;
  String? _run;
  bool _busy = false;
  bool _closed = false;
  Future<CreatedJobSyncResult>? _initiating;
  int _remoteRemaining = 128;
  String? _remoteStore;
  Map<String, String> _cachedAckStores = {};
  int _sentFrames = 0;
  int _receivedFrames = 0;
  int _sentJobs = 0;
  int _receivedJobs = 0;
  Map<String, Object?>? _incomingDescriptor;
  CreatedJobTransferBuffer? _incoming;
  Future<void> _receiving = Future<void>.value();
  bool _receivePending = false;
  final Set<String> _served = {};
  final Set<String> _confirmed = {};

  void close() {
    _closed = true;
    if (identical(controller.companySyncDisclosure, availability)) {
      controller.companySyncDisclosure = null;
    }
    availability.close();
    _incoming = null;
    _run = null;
  }

  Future<void> closeAndDrain() async {
    close();
    await Future.wait<void>([
      _receiving,
      if (_initiating case final pending?) pending.then<void>((_) {}),
    ]);
  }

  Future<NearbyJoinChannel> _getChannel() => _channelPending ??= (() async {
    await availability.requireCurrent();
    final source = availability.peer._held.channel;
    Future<SecretKey> derive(SecretKey key, String direction) =>
        Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
          secretKey: key,
          nonce: utf8.encode(source._keys.id),
          info: utf8.encode(
            'wiredpart-v2/company-job-create-sync@1/$direction',
          ),
        );
    final channel = NearbyJoinChannel._(
      source._pair,
      source._keys,
      await derive(source._send, source._keys.sendDirection),
      await derive(source._receive, source._keys.receiveDirection),
    );
    await availability.requireCurrent();
    return channel;
  })();

  bool _canExchange(int requests) {
    final pair = availability.peer._held.channel._pair;
    return _sentFrames + requests <= 112 &&
        _receivedFrames + requests <= 112 &&
        pair.remainingReceivedNonces >= requests + 4 &&
        _remoteRemaining >= requests + 4 &&
        pair.timeUntilExpiry > Duration(seconds: requests * 20);
  }

  Future<Map<String, Object?>> _seal(
    String request,
    Map<String, Object?> body,
  ) async {
    await availability.requireCurrent();
    final channel = await _getChannel();
    if (_sentFrames >= 112 || channel._pair.remainingReceivedNonces < 2) {
      throw const CompanyBootstrapRefusal('Job sync channel budget exhausted');
    }
    final wire = await _sealJoin(
      channel,
      _syncKind,
      request,
      availability.peer._held.peer._membership.device['key'] as String,
      {
        'v': 1,
        'protocol': _syncProtocol,
        'remaining': channel._pair.remainingReceivedNonces,
        ...body,
      },
    );
    await availability.requireCurrent();
    _sentFrames++;
    return wire;
  }

  Future<Map<String, Object?>> _open(Map<String, Object?> wire) async {
    await availability.requireCurrent();
    if (_receivedFrames >= 112) {
      throw const CompanyBootstrapRefusal('Job sync frame ceiling reached');
    }
    final channel = await _getChannel();
    final body = await _openJoin(
      channel,
      _syncKind,
      wire,
      recipient: base64Encode(_installation.identity!.publicKey),
    );
    _receivedFrames++;
    _joinObject(body, {'v', 'protocol', 'remaining', 'action', 'run', 'data'});
    if (body['v'] != 1 ||
        body['protocol'] != _syncProtocol ||
        body['remaining'] is! int ||
        (body['remaining'] as int) < 0 ||
        (body['remaining'] as int) > 128) {
      throw const CompanyBootstrapRefusal('Unsupported Job sync protocol');
    }
    _joinId(body, 'run');
    _remoteRemaining = body['remaining'] as int;
    await availability.requireCurrent();
    return body;
  }

  Future<Map<String, Object?>> _rpc(
    String action,
    Map<String, Object?> data,
  ) async {
    if (!_canExchange(1)) {
      throw const CompanyBootstrapRefusal('More Jobs pending; pair again');
    }
    final request = const Uuid().v4();
    final wire = await _seal(request, {
      'action': action,
      'run': _run,
      'data': data,
    });
    final response = await controller.exchangeCompanyMessage(
      wire,
      disclosure: availability,
    );
    final body = await _open(response);
    if (response['request'] != request ||
        body['action'] != '$action.reply' ||
        body['run'] != _run) {
      throw const CompanyBootstrapRefusal('Job sync response differs');
    }
    return Map<String, Object?>.from(body['data'] as Map);
  }

  Future<void> _freeze() async {
    final records = await _commands.syncHoldings(
      ownerSession: availability.owner,
    );
    _local = CreatedJobHoldingsInventory.local(records);
    _cachedAckStores = await _readAckCache(records);
    _incoming = null;
    _incomingDescriptor = null;
  }

  Map<String, Object?> _summary() => {
    'inventory': _local!.meta,
    'store': _installation.receivingStoreGeneration!.value,
  };

  void _readSummary(Map<String, Object?> data) {
    _joinObject(data, {'inventory', 'store'});
    _remoteStore = _joinId(data, 'store');
    _remote = CreatedJobHoldingsInventory.remote(data['inventory']);
  }

  Map<String, Object?> _holdingsPage(int ordinal) {
    final items = _local!.page(ordinal);
    final result = <String, Object?>{
      'ordinal': ordinal,
      'digest': _local!.digest,
      'items': items,
      'confirmedStores': [
        for (final d in items) _cachedAckStores[_descriptorKey(d)],
      ],
    };
    if (utf8.encode(_securityCanonical(result)).length > 33 * 1024) {
      throw const CompanyBootstrapRefusal('Job holdings page byte limit');
    }
    return result;
  }

  Future<Map<String, String>> _readAckCache(List<CompanyJob> records) async {
    final expected = {
      for (final row in records)
        _descriptorKey(_jobDescriptor(row)): _jobDescriptor(row),
    };
    final rows =
        await (_db.select(_db.companyJobPeerAcks)
              ..where(
                (t) =>
                    t.companyId.equals(availability.owner.identity.companyId) &
                    t.peerDeviceId.equals(availability.peer.deviceId),
              )
              ..limit(513))
            .get();
    if (rows.length > 512) {
      throw const CompanyBootstrapRefusal('Peer ACK capacity exceeded');
    }
    final result = <String, String>{};
    for (final row in rows) {
      final key = '${row.originGeneration}/${row.requestId}';
      final descriptor = expected[key];
      if (descriptor == null || row.operationDigest != descriptor['digest']) {
        throw const CompanyBootstrapRefusal(
          'Saved ACK has no matching scoped Job',
        );
      }
      final body = await _validatePeerAck(descriptor, jsonDecode(row.ackBytes));
      result[key] = body['store'] as String;
    }
    return result;
  }

  Future<CompanyJob> _record(Map<String, Object?> descriptor) async {
    final row = await _commands.verifySyncRecord(
      descriptor['job'] as String,
      availability.owner,
    );
    if (_securityCanonical(_jobDescriptor(row)) !=
        _securityCanonical(descriptor)) {
      throw const CompanyBootstrapRefusal('Job changed after inventory');
    }
    return row;
  }

  Future<Map<String, Object?>> _ack(Map<String, Object?> descriptor) async {
    final row = await _record(descriptor);
    await availability.requireCurrent();
    final identity = _installation.identity!;
    final signed = await _signJoin(_installation, {
      'v': 1,
      'kind': 'company.job.create.ack@1',
      'descriptor': descriptor,
      'receiver': identity.id.value,
      'generation': identity.generation.value,
      'store': _installation.receivingStoreGeneration!.value,
      'receipt': _syncBytesDigest(utf8.encode(row.receiptBytes)),
    }, _syncAckDomain);
    if (utf8.encode(_securityCanonical(signed)).length > 4096) {
      throw const CompanyBootstrapRefusal('Job ACK capacity exceeded');
    }
    await availability.requireCurrent();
    return signed;
  }

  Future<Map<String, Object?>> _validatePeerAck(
    Map<String, Object?> descriptor,
    Object? raw,
  ) async {
    final signed = _joinObject(raw, {'body', 'signature'});
    if (utf8.encode(_securityCanonical(signed)).length > 4096) {
      throw const CompanyBootstrapRefusal('Job ACK capacity exceeded');
    }
    final body = _joinObject(signed['body'], {
      'v',
      'kind',
      'descriptor',
      'receiver',
      'generation',
      'store',
      'receipt',
    });
    final member = availability.peer._held.peer._membership;
    _joinId(body, 'store');
    _joinHash(body['receipt']);
    if (body['v'] != 1 ||
        body['kind'] != 'company.job.create.ack@1' ||
        body['receiver'] != member.device['installation'] ||
        body['generation'] != member.device['generation'] ||
        _securityCanonical(body['descriptor']) !=
            _securityCanonical(descriptor)) {
      throw const CompanyBootstrapRefusal('Job ACK binding differs');
    }
    await _joinVerify(
      body,
      signed['signature'],
      member.device['key'],
      _syncAckDomain,
    );
    return body;
  }

  Future<void> _saveAck(Map<String, Object?> descriptor, Object? raw) async {
    final body = await _validatePeerAck(descriptor, raw);
    if (body['store'] != _remoteStore) {
      throw const CompanyBootstrapRefusal(
        'ACK receiver store differs from live snapshot',
      );
    }
    final signed = _joinObject(raw, {'body', 'signature'});
    await _record(descriptor);
    await availability.requireCurrent();
    final next = CompanyJobPeerAck(
      companyId: availability.owner.identity.companyId,
      originGeneration: descriptor['origin'] as String,
      requestId: descriptor['request'] as String,
      peerDeviceId: availability.peer.deviceId,
      operationDigest: descriptor['digest'] as String,
      ackBytes: _securityCanonical(signed),
    );
    await _db.transaction(() async {
      await _db.customStatement(
        'UPDATE app_settings SET value = value WHERE key = ?',
        [kInstallationBindingKey],
      );
      await availability.requireCurrent();
      final prior =
          await (_db.select(_db.companyJobPeerAcks)..where(
                (t) =>
                    t.companyId.equals(next.companyId) &
                    t.originGeneration.equals(next.originGeneration) &
                    t.requestId.equals(next.requestId) &
                    t.peerDeviceId.equals(next.peerDeviceId),
              ))
              .getSingleOrNull();
      if (prior != next) {
        await _db
            .into(_db.companyJobPeerAcks)
            .insertOnConflictUpdate(next.toCompanion(false));
      }
      availability.requireLive();
    });
    _cachedAckStores[_descriptorKey(descriptor)] = body['store'] as String;
  }

  bool _authoredHere(Map<String, Object?> descriptor) =>
      descriptor['author'] == availability.owner.identity.deviceId &&
      descriptor['installation'] == _installation.identity!.id.value &&
      descriptor['origin'] == _installation.identity!.generation.value;

  void _requireInventories() {
    if (_local?.complete != true || _remote?.complete != true) {
      throw const CompanyBootstrapRefusal(
        'Complete both holdings inventories first',
      );
    }
    final ours = _local!.byKey;
    for (final entry in _remote!.byKey.entries) {
      if (ours[entry.key] case final descriptor?) {
        if (_securityCanonical(descriptor) != _securityCanonical(entry.value)) {
          throw const CompanyBootstrapRefusal(
            'Job inventory identity collision',
          );
        }
      }
    }
  }

  Future<bool> _snapshotConfirmed() async {
    _requireInventories();
    final records = await _commands.syncHoldings(
      ownerSession: availability.owner,
    );
    final actual = {
      for (final row in records)
        _descriptorKey(_jobDescriptor(row)): _jobDescriptor(row),
    };
    final expected = {..._local!.byKey, ..._remote!.byKey};
    for (final entry in expected.entries) {
      if (_securityCanonical(actual[entry.key]) !=
          _securityCanonical(entry.value)) {
        return false;
      }
    }
    final verifiedAckStores = await _readAckCache(records);
    for (final descriptor in expected.values) {
      if (verifiedAckStores[_descriptorKey(descriptor)] != _remoteStore) {
        return false;
      }
    }
    await availability.requireCurrent();
    return true;
  }

  Future<Map<String, Object?>> receive(Map<String, Object?> wire) {
    if (_closed || _receivePending) {
      return Future.error(
        const CompanyBootstrapRefusal(
          'Job sync is closed or receiving a request',
        ),
      );
    }
    _receivePending = true;
    final result = _receiving.then((_) async {
      var stage = CreatedJobSyncStage.channelOpen;
      String? receivingRun;
      try {
        return await _receive(wire, (value) => stage = value, () {
          if (!_busy) receivingRun = _run;
        });
      } catch (error) {
        lastFailure = error;
        final ownCounts =
            receivingRun != null && receivingRun == _run && !_busy;
        _terminal(
          CreatedJobSyncResult(
            ownCounts ? _sentJobs : 0,
            ownCounts ? _receivedJobs : 0,
            false,
            0,
            failure: CreatedJobSyncFailure.fromError(error, stage),
          ),
          receiving: true,
        );
        rethrow;
      } finally {
        _receivePending = false;
      }
    });
    _receiving = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Map<String, Object?>> _receive(
    Map<String, Object?> wire,
    void Function(CreatedJobSyncStage) atStage,
    void Function() receiverInitialized,
  ) async {
    final body = await _open(wire);
    final action = body['action'];
    final data = Map<String, Object?>.from(body['data'] as Map);
    Map<String, Object?> result;
    if (action == 'start') {
      atStage(CreatedJobSyncStage.startRequest);
      if (_busy) {
        throw const CompanyBootstrapRefusal('A Job sync is already running');
      }
      const CreatedJobSyncDiagnostic.started(receiverCallbackReached: true)
          .notify(onDiagnostic);
      atStage(CreatedJobSyncStage.localInventory);
      await _freeze();
      _run = body['run'] as String;
      _readSummary(data);
      _sentJobs = 0;
      _receivedJobs = 0;
      _served.clear();
      _confirmed.clear();
      receiverInitialized();
      _status('Exchanging Job holdings with the verified peer.');
      result = _summary();
    } else {
      if (_run == null || body['run'] != _run) {
        throw const CompanyBootstrapRefusal('Job sync run differs');
      }
      receiverInitialized();
      if (action == 'holdings') {
        atStage(CreatedJobSyncStage.holdings);
        _remote!.acceptPage(data);
        result = {};
      } else if (action == 'page') {
        atStage(CreatedJobSyncStage.holdings);
        _joinObject(data, {'ordinal'});
        final ordinal = data['ordinal'];
        if (ordinal is! int) {
          throw const CompanyBootstrapRefusal('Invalid page ordinal');
        }
        result = _holdingsPage(ordinal);
      } else {
        atStage(
          action == 'finish'
              ? CreatedJobSyncStage.confirmation
              : CreatedJobSyncStage.transfer,
        );
        _requireInventories();
        result = await _transfer(action, data);
      }
    }
    atStage(CreatedJobSyncStage.replySeal);
    final reply = await _seal(wire['request'] as String, {
      'action': '$action.reply',
      'run': _run,
      'data': result,
    });
    availability.requireLive();
    if (action == 'finish') {
      final complete = data['complete'] as bool;
      final unsupported = data['unsupported'] as int;
      _terminal(
        CreatedJobSyncResult(
          _sentJobs,
          _receivedJobs,
          complete,
          unsupported,
          failure: complete
              ? null
              : CreatedJobSyncFailure(
                  CreatedJobSyncStage.confirmation,
                  unsupported > 0
                      ? CreatedJobSyncReason.unsupportedAuthor
                      : CreatedJobSyncReason.unconfirmedSnapshot,
                ),
        ),
        receiving: true,
      );
    }
    return reply;
  }

  Future<Map<String, Object?>> _transfer(
    Object? action,
    Map<String, Object?> data,
  ) async {
    if (action == 'finish') {
      _joinObject(data, {'complete', 'unsupported'});
      if (data['complete'] is! bool ||
          data['unsupported'] is! int ||
          (data['unsupported'] as int) < 0 ||
          (data['unsupported'] as int) > 1024) {
        throw const CompanyBootstrapRefusal('Invalid completion');
      }
      final confirmed = await _snapshotConfirmed();
      if (data['complete'] == true &&
          (!confirmed || data['unsupported'] != 0)) {
        throw const CompanyBootstrapRefusal(
          'Peer claimed an unconfirmed Job snapshot',
        );
      }
      return {};
    }
    final descriptor = _parseDescriptor(data['descriptor']);
    final key = _descriptorKey(descriptor);
    if (action == 'put') {
      _joinObject(data, {'descriptor', 'offset', 'bytes'});
      final remote = _remote!.byKey[key];
      final member = availability.peer._held.peer._membership;
      if (_securityCanonical(remote) != _securityCanonical(descriptor) ||
          descriptor['author'] != member.device['id'] ||
          descriptor['installation'] != member.device['installation'] ||
          descriptor['origin'] != member.device['generation']) {
        throw const CompanyBootstrapRefusal(
          'Job payload author is not sending peer',
        );
      }
      if (_incomingDescriptor == null) {
        if (data['offset'] != 0) {
          throw const CompanyBootstrapRefusal('Job chunk gap');
        }
        _incomingDescriptor = descriptor;
        _incoming = CreatedJobTransferBuffer(
          length: descriptor['length'] as int,
          digest: descriptor['digest'] as String,
        );
      }
      if (_securityCanonical(_incomingDescriptor) !=
              _securityCanonical(descriptor) ||
          data['offset'] != _incoming!.receivedBytes) {
        throw const CompanyBootstrapRefusal(
          'Job chunk overlap or identity changed',
        );
      }
      _incoming!.append(data['offset'], data['bytes']);
      if (_incoming!.complete) {
        await _commands.applyIncomingCreate(
          _incoming!.bytes,
          ownerSession: availability.owner,
          availability: availability,
        );
        _incoming = null;
        _incomingDescriptor = null;
        final ack = await _ack(descriptor);
        _receivedJobs++;
        return {'ack': ack};
      }
      return {};
    }
    if (_securityCanonical(_local!.byKey[key] ?? _remote!.byKey[key]) !=
        _securityCanonical(descriptor)) {
      throw const CompanyBootstrapRefusal('Job is outside frozen holdings');
    }
    if (action == 'get') {
      _joinObject(data, {'descriptor', 'offset', 'limit'});
      if (!_authoredHere(descriptor)) {
        throw const CompanyBootstrapRefusal('Job relay is not supported');
      }
      final row = await _record(descriptor);
      _served.add(key);
      final bytes = utf8.encode(row.operationBytes);
      final offset = data['offset'];
      final limit = data['limit'];
      if (offset is! int ||
          offset < 0 ||
          offset >= bytes.length ||
          limit is! int ||
          limit < 1 ||
          limit > kCreatedJobSyncChunkBytes) {
        throw const CompanyBootstrapRefusal('Invalid Job chunk range');
      }
      final end = offset + limit > bytes.length ? bytes.length : offset + limit;
      return {
        'offset': offset,
        'bytes': base64Encode(bytes.sublist(offset, end)),
      };
    }
    if (action == 'ackBoth') {
      _joinObject(data, {'descriptor', 'ack'});
      await _saveAck(descriptor, data['ack']);
      if (_served.contains(key) && _confirmed.add(key)) _sentJobs++;
      return {'ack': await _ack(descriptor)};
    }
    throw const CompanyBootstrapRefusal('Unsupported Job sync action');
  }

  Future<CreatedJobSyncResult> syncNow() {
    if (_closed || _busy) {
      throw const CompanyBootstrapRefusal('A Job sync is already running');
    }
    return _initiating = _syncNow();
  }

  Future<CreatedJobSyncResult> _syncNow() async {
    _busy = true;
    _sentJobs = 0;
    _receivedJobs = 0;
    var unsupported = 0;
    var complete = false;
    var stage = CreatedJobSyncStage.preflight;
    CreatedJobSyncFailure? failure;
    const CreatedJobSyncDiagnostic.started().notify(onDiagnostic);
    try {
      lastFailure = null;
      _status('Checking Job sync permissions.');
      await availability.requireCurrent();
      stage = CreatedJobSyncStage.channelOpen;
      await _getChannel();
      stage = CreatedJobSyncStage.localInventory;
      await _freeze();
      _status('Comparing verified Job holdings.');
      _run = const Uuid().v4();
      stage = CreatedJobSyncStage.startRequest;
      _readSummary(await _rpc('start', _summary()));
      stage = CreatedJobSyncStage.holdings;
      for (var i = 0; i < _local!.pages; i++) {
        await _rpc('holdings', _holdingsPage(i));
      }
      for (var i = 0; i < _remote!.pages; i++) {
        _remote!.acceptPage(await _rpc('page', {'ordinal': i}));
      }
      _requireInventories();
      final ours = _local!.descriptors;
      final theirs = _remote!.descriptors;
      final ourKeys = _local!.byKey;
      final theirKeys = _remote!.byKey;
      stage = CreatedJobSyncStage.transfer;
      for (
        var i = 0;
        i < (ours.length > theirs.length ? ours.length : theirs.length);
        i++
      ) {
        if (i < ours.length) {
          final d = ours[i];
          if (theirKeys.containsKey(_descriptorKey(d))) {
            final confirmed =
                _cachedAckStores[_descriptorKey(d)] == _remoteStore &&
                _remote!.peerAckStore(_descriptorKey(d)) ==
                    _installation.receivingStoreGeneration!.value;
            if (!confirmed) {
              if (!_canExchange(2)) {
                throw const CompanyBootstrapRefusal('More Jobs pending');
              }
              final reply = await _rpc('ackBoth', {
                'descriptor': d,
                'ack': await _ack(d),
              });
              await _saveAck(d, reply['ack']);
            }
          } else if (_authoredHere(d)) {
            _status('Sending an offline-created Job to the retained peer.');
            final row = await _record(d);
            final bytes = utf8.encode(row.operationBytes);
            if (!_canExchange(
              (bytes.length + chunkBytes - 1) ~/ chunkBytes + 2,
            )) {
              throw const CompanyBootstrapRefusal('More Jobs pending');
            }
            for (var offset = 0; offset < bytes.length; offset += chunkBytes) {
              final end = offset + chunkBytes > bytes.length
                  ? bytes.length
                  : offset + chunkBytes;
              final reply = await _rpc('put', {
                'descriptor': d,
                'offset': offset,
                'bytes': base64Encode(bytes.sublist(offset, end)),
              });
              if (end == bytes.length) {
                await _saveAck(d, reply['ack']);
                final confirmed = await _rpc('ackBoth', {
                  'descriptor': d,
                  'ack': await _ack(d),
                });
                await _saveAck(d, confirmed['ack']);
                _sentJobs++;
              } else if (reply.isNotEmpty) {
                throw const CompanyBootstrapRefusal('Premature Job ACK');
              }
            }
          } else {
            unsupported++;
          }
        }
        if (i < theirs.length) {
          final d = theirs[i];
          if (ourKeys.containsKey(_descriptorKey(d))) continue;
          final member = availability.peer._held.peer._membership;
          if (d['author'] != member.device['id'] ||
              d['installation'] != member.device['installation'] ||
              d['origin'] != member.device['generation']) {
            unsupported++;
            continue;
          }
          if (!_canExchange(
            ((d['length'] as int) + chunkBytes - 1) ~/ chunkBytes + 2,
          )) {
            throw const CompanyBootstrapRefusal('More Jobs pending');
          }
          final buffer = CreatedJobTransferBuffer(
            length: d['length'] as int,
            digest: d['digest'] as String,
          );
          _status('Receiving an offline-created Job from the retained peer.');
          while (!buffer.complete) {
            final reply = await _rpc('get', {
              'descriptor': d,
              'offset': buffer.receivedBytes,
              'limit': chunkBytes,
            });
            _joinObject(reply, {'offset', 'bytes'});
            buffer.append(reply['offset'], reply['bytes']);
          }
          await _commands.applyIncomingCreate(
            buffer.bytes,
            ownerSession: availability.owner,
            availability: availability,
          );
          final confirmed = await _rpc('ackBoth', {
            'descriptor': d,
            'ack': await _ack(d),
          });
          await _saveAck(d, confirmed['ack']);
          _receivedJobs++;
        }
      }
      stage = CreatedJobSyncStage.confirmation;
      complete = unsupported == 0 && await _snapshotConfirmed();
      if (!complete) {
        failure = CreatedJobSyncFailure(
          stage,
          unsupported > 0
              ? CreatedJobSyncReason.unsupportedAuthor
              : CreatedJobSyncReason.unconfirmedSnapshot,
        );
      }
      _status('Confirming the Job snapshot exchange.');
      await _rpc('finish', {'complete': complete, 'unsupported': unsupported});
    } catch (error) {
      lastFailure = error;
      failure = CreatedJobSyncFailure.fromError(error, stage);
      complete = false;
    } finally {
      _busy = false;
      _incoming = null;
      _incomingDescriptor = null;
    }
    final result = CreatedJobSyncResult(
      _sentJobs,
      _receivedJobs,
      complete,
      unsupported,
      failure: failure,
    );
    _terminal(result);
    return result;
  }
}
