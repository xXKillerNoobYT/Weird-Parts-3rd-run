import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../backup/backup_codec.dart';
import 'nearby_codec.dart';
import 'nearby_discovery.dart';
import 'nearby_protocol.dart';

enum NearbyPhase {
  idle,
  starting,
  looking,
  pairing,
  paired,
  offering,
  transferring,
  success,
  failed,
}

class NearbyViewState {
  const NearbyViewState({
    required this.phase,
    required this.deviceName,
    required this.deviceId,
    this.status =
        'Open Nearby on the other device. Stay on the same Wi‑Fi.',
    this.error,
    this.verifyCode,
    this.peerName,
    this.peers = const [],
    this.incoming,
    this.progress,
    this.successMessage,
    this.pairedPeer,
  });

  final NearbyPhase phase;
  final String deviceName;
  final String deviceId;
  final String status;
  final String? error;
  final String? verifyCode;
  final String? peerName;
  final List<NearbyPeer> peers;
  final NearbyOffer? incoming;
  final double? progress;
  final String? successMessage;
  final NearbyPeer? pairedPeer;

  bool get running =>
      phase != NearbyPhase.idle && phase != NearbyPhase.failed;
}

typedef NearbyApplyPayload = Future<void> Function(BackupPayload payload);

class NearbyController {
  NearbyController({
    required this.deviceId,
    required this.deviceName,
    required this.discovery,
    required this.collectPayload,
    required this.applyPayload,
    this.bindAddress,
    this.localIps,
    this.codec,
    Random? random,
  }) : _random = random ?? Random.secure();

  final String deviceId;
  String deviceName;
  final NearbyDiscovery discovery;
  final Future<({BackupPayload payload, NearbyOffer offer})> Function()
  collectPayload;
  final NearbyApplyPayload applyPayload;
  final InternetAddress? bindAddress;
  final Future<List<String>> Function()? localIps;
  final NearbyCodec? codec;
  final Random _random;

  NearbyCodec get _codec => codec ?? NearbyCodec();

  final _stateCtrl = StreamController<NearbyViewState>.broadcast();
  Stream<NearbyViewState> get states => _stateCtrl.stream;

  NearbyViewState _state = NearbyViewState(
    phase: NearbyPhase.idle,
    deviceName: '',
    deviceId: '',
  );

  NearbyViewState get state => _state;

  HttpServer? _server;
  StreamSubscription<List<NearbyPeer>>? _peerSub;
  _PendingPair? _pending;
  _Session? _session;
  Completer<bool>? _hostMatch;
  Completer<bool>? _offerDecision;
  _AcceptedOffer? _acceptedOffer;
  Timer? _pairTimer;

  Future<void> start() async {
    if (_state.phase != NearbyPhase.idle &&
        _state.phase != NearbyPhase.failed) {
      return;
    }
    _emit(
      NearbyViewState(
        phase: NearbyPhase.starting,
        deviceName: deviceName,
        deviceId: deviceId,
        status: 'Opening Nearby on this Wi‑Fi…',
      ),
    );
    try {
      final server = await HttpServer.bind(
        bindAddress ?? InternetAddress.anyIPv4,
        0,
      );
      _server = server;
      server.listen(_handleHttp, onError: (Object e) {
        _fail('Nearby connection failed: $e');
      });
      final ips = await (localIps ?? localIpv4Addresses)();
      final advertiseIps = ips.isNotEmpty
          ? ips
          : [server.address.address];
      await discovery.start(
        deviceId: deviceId,
        name: deviceName,
        port: server.port,
        ips: advertiseIps,
      );
      _peerSub = discovery.peers.listen((peers) {
        final filtered = peers.where((p) => p.deviceId != deviceId).toList();
        if (_state.phase == NearbyPhase.paired ||
            _state.phase == NearbyPhase.pairing ||
            _state.phase == NearbyPhase.offering ||
            _state.phase == NearbyPhase.transferring) {
          _emit(_state.copyWith(peers: filtered));
          return;
        }
        if (_state.phase == NearbyPhase.success ||
            _state.phase == NearbyPhase.failed) {
          return;
        }
        final looking = filtered.isEmpty
            ? 'Looking for Wired Parts on this Wi‑Fi. Open More → Nearby on the other device. If Windows or this Mac asks, allow Wired Parts on the network.'
            : 'Tap a device to pair. You will both see a 6-digit code.';
        _emit(
          _state.copyWith(
            phase: NearbyPhase.looking,
            peers: filtered,
            status: looking,
            error: null,
          ),
        );
      });
      _emit(
        NearbyViewState(
          phase: NearbyPhase.looking,
          deviceName: deviceName,
          deviceId: deviceId,
          status:
              'Visible on this Wi‑Fi as $deviceName. Looking for other devices… Open Nearby on the other device. Stay on the same Wi‑Fi.',
          peers: const [],
        ),
      );
    } catch (e) {
      await stop();
      _fail(
        'Could not listen on this Wi‑Fi. Allow Wired Parts through the firewall and try again. $e',
      );
    }
  }

  Future<void> stop() async {
    _pairTimer?.cancel();
    _pairTimer = null;
    _failPending(cancel: true);
    await _peerSub?.cancel();
    _peerSub = null;
    await discovery.stop();
    await _server?.close(force: true);
    _server = null;
    _session = null;
    _pending = null;
    if (!_stateCtrl.isClosed) {
      _emit(
        NearbyViewState(
          phase: NearbyPhase.idle,
          deviceName: deviceName,
          deviceId: deviceId,
          status: 'Nearby is off.',
        ),
      );
    }
  }

  Future<void> rename(String name) async {
    final trimmed = name.trim();
    deviceName = trimmed.isEmpty ? defaultNearbyName(deviceId) : trimmed;
    final port = _server?.port;
    if (port != null) {
      final ips = await (localIps ?? localIpv4Addresses)();
      await discovery.updateAdvertisement(
        name: deviceName,
        port: port,
        ips: ips.isNotEmpty ? ips : [InternetAddress.loopbackIPv4.address],
      );
    }
    _emit(_state.copyWith(deviceName: deviceName));
  }

  Future<void> pair(NearbyPeer peer) async {
    if (_server == null) {
      _fail('Nearby is not listening. Open this page again.');
      return;
    }
    final guestNonce = _nonce();
    _emit(
      NearbyViewState(
        phase: NearbyPhase.pairing,
        deviceName: deviceName,
        deviceId: deviceId,
        peerName: peer.label,
        status: 'Connecting to ${peer.label}…',
        peers: _state.peers,
      ),
    );
    try {
      final start = await _jsonPost(
        peer,
        '/v1/pair/start',
        {
          'guestDeviceId': deviceId,
          'guestName': deviceName,
          'guestNonce': base64Encode(guestNonce),
        },
      );
      final hostNonce = base64Decode(start['hostNonce'] as String);
      final code = start['verifyCode'];
      if (code is! int) {
        throw const NearbyException('The other device sent a damaged pair reply');
      }
      _session = _Session(
        peer: peer,
        token: '',
        guestNonce: guestNonce,
        hostNonce: hostNonce,
        guest: true,
        verifyCode: code,
      );
      _emit(
        _state.copyWith(
          phase: NearbyPhase.pairing,
          verifyCode: code.toString(),
          peerName: peer.label,
          status:
              'Check that ${peer.label} shows this same code, then tap Match.',
        ),
      );
    } catch (e) {
      _fail(_crewError(e, 'Could not reach ${peer.label}'));
    }
  }

  Future<void> confirmCode() async {
    final session = _session;
    if (_pending != null && _hostMatch != null && !(_hostMatch!.isCompleted)) {
      _hostMatch!.complete(true);
      _emit(
        _state.copyWith(
          status: 'Waiting for the other device to tap Match…',
        ),
      );
      return;
    }
    if (session == null || !session.guest) {
      return;
    }
    _emit(
      _state.copyWith(status: 'Waiting for ${session.peer.label} to tap Match…'),
    );
    try {
      final reply = await _jsonPost(
        session.peer,
        '/v1/pair/confirm',
        {
          'guestDeviceId': deviceId,
          'verifyCode': session.verifyCode,
        },
        timeout: const Duration(minutes: 2),
      );
      final token = reply['token'] as String?;
      if (token == null || token.isEmpty) {
        throw const NearbyException('Pair did not finish');
      }
      _session = session.copyWith(token: token);
      _emit(
        NearbyViewState(
          phase: NearbyPhase.paired,
          deviceName: deviceName,
          deviceId: deviceId,
          peerName: session.peer.label,
          peers: _state.peers,
          pairedPeer: session.peer,
          status:
              'Paired with ${session.peer.label}. Send this shop to copy jobs, catalog, and photos onto that device. That replaces the shop over there.',
        ),
      );
    } catch (e) {
      _fail(_crewError(e, 'Pair failed'));
    }
  }

  Future<void> rejectCode() async {
    final pending = _pending;
    if (pending != null) {
      pending.rejected = true;
      if (_hostMatch != null && !_hostMatch!.isCompleted) {
        _hostMatch!.complete(false);
      }
    }
    final session = _session;
    if (session != null && session.guest) {
      try {
        await _jsonPost(session.peer, '/v1/pair/cancel', {
          'guestDeviceId': deviceId,
        });
      } catch (_) {}
    }
    _pending = null;
    _session = null;
    _emit(
      NearbyViewState(
        phase: NearbyPhase.looking,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        error: 'Pair cancelled. Codes must match on both screens.',
        status:
            'Tap a device to pair. You will both see a 6-digit code.',
      ),
    );
  }

  Future<void> acceptOffer() async {
    final c = _offerDecision;
    if (c == null || c.isCompleted) return;
    c.complete(true);
    _emit(
      _state.copyWith(
        phase: NearbyPhase.transferring,
        status: 'Accepted. Receiving shop…',
        progress: 0,
      ),
    );
  }

  Future<void> declineOffer() async {
    final c = _offerDecision;
    if (c == null || c.isCompleted) return;
    c.complete(false);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.looking,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        error: 'You declined the incoming shop. Nothing on this device changed.',
        status: 'Looking for Wired Parts on this Wi‑Fi.',
      ),
    );
  }

  Future<void> sendTo(NearbyPeer peer) async {
    final session = _session;
    if (session == null || session.token.isEmpty) {
      _fail('Pair first, then send.');
      return;
    }
    _emit(
      _state.copyWith(
        phase: NearbyPhase.transferring,
        pairedPeer: peer,
        peerName: peer.label,
        status: 'Preparing this shop to send…',
        progress: 0,
      ),
    );
    try {
      final packed = await collectPayload();
      final bytes = await _codec.encrypt(
        payload: packed.payload,
        token: session.token,
        offer: packed.offer,
      );
      _emit(
        _state.copyWith(
          status: 'Waiting for ${peer.label} to accept…',
          progress: 0,
        ),
      );
      await _jsonPost(
        peer,
        '/v1/offer',
        {
          'sourceDeviceId': packed.offer.sourceDeviceId,
          'sourceName': packed.offer.sourceName,
          'jobs': packed.offer.jobs,
          'parts': packed.offer.parts,
          'photos': packed.offer.photos,
          'bytes': bytes.length,
        },
        token: session.token,
        timeout: const Duration(minutes: 2),
      );
      _emit(
        _state.copyWith(
          status: 'Sending shop to ${peer.label}…',
          progress: 0,
        ),
      );
      await _putBytes(
        peer,
        '/v1/transfer',
        bytes,
        token: session.token,
        onProgress: (p) {
          _emit(
            _state.copyWith(
              progress: p,
              status: 'Sending shop to ${peer.label}… ${(p * 100).round()}%',
            ),
          );
        },
      );
      _emit(
        NearbyViewState(
          phase: NearbyPhase.success,
          deviceName: deviceName,
          deviceId: deviceId,
          peers: _state.peers,
          pairedPeer: peer,
          peerName: peer.label,
          successMessage:
              'Sent this shop to ${peer.label} (${packed.offer.summary}).',
          status: 'Sent this shop to ${peer.label}.',
          progress: 1,
        ),
      );
    } catch (e) {
      _fail(_crewError(e, 'Send failed. The other shop was not replaced.'));
    }
  }

  Future<void> _handleHttp(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/v1/hello') {
        await _writeJson(request, {
          'proto': kNearbyProto,
          'v': kNearbyProtoVersion,
          'deviceId': deviceId,
          'name': deviceName,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/pair/start') {
        await _onPairStart(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/pair/confirm') {
        await _onPairConfirm(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/pair/cancel') {
        await _onPairCancel(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/offer') {
        await _onOffer(request);
        return;
      }
      if (request.method == 'PUT' && path == '/v1/transfer') {
        await _onTransfer(request);
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await _writeJson(request, {'error': 'Unknown nearby request'});
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await _writeJson(request, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> _onPairStart(HttpRequest request) async {
    final body = await _readJson(request);
    final guestId = body['guestDeviceId'] as String?;
    final guestName = body['guestName'] as String? ?? 'Other device';
    final nonceB64 = body['guestNonce'] as String?;
    if (guestId == null || nonceB64 == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await _writeJson(request, {'error': 'Damaged pair request'});
      return;
    }
    if (guestId == deviceId) {
      request.response.statusCode = HttpStatus.badRequest;
      await _writeJson(request, {'error': 'Cannot pair with this same device'});
      return;
    }
    final guestNonce = base64Decode(nonceB64);
    final hostSecret = _nonce();
    final hostNonce = _nonce();
    final code = pairingVerifyCode(
      hostSecret: hostSecret,
      guestDeviceId: guestId,
      guestNonce: guestNonce,
      hostNonce: hostNonce,
    );
    _failPending(cancel: true);
    _hostMatch = Completer<bool>();
    _pending = _PendingPair(
      guestDeviceId: guestId,
      guestName: guestName,
      guestNonce: guestNonce,
      hostNonce: hostNonce,
      hostSecret: hostSecret,
      verifyCode: code,
    );
    _pairTimer?.cancel();
    _pairTimer = Timer(const Duration(minutes: 2), () {
      if (_hostMatch != null && !_hostMatch!.isCompleted) {
        _hostMatch!.complete(false);
      }
    });
    _session = _Session(
      peer: NearbyPeer(
        deviceId: guestId,
        name: guestName,
        host: request.connectionInfo?.remoteAddress.address ?? '',
        port: 0,
      ),
      token: '',
      guestNonce: guestNonce,
      hostNonce: hostNonce,
      guest: false,
      verifyCode: code,
    );
    _emit(
      NearbyViewState(
        phase: NearbyPhase.pairing,
        deviceName: deviceName,
        deviceId: deviceId,
        verifyCode: code.toString(),
        peerName: guestName,
        peers: _state.peers,
        status:
            'Check that $guestName shows this same code, then tap Match.',
      ),
    );
    await _writeJson(request, {
      'hostDeviceId': deviceId,
      'hostName': deviceName,
      'hostNonce': base64Encode(hostNonce),
      'verifyCode': code,
    });
  }

  Future<void> _onPairConfirm(HttpRequest request) async {
    final body = await _readJson(request);
    final pending = _pending;
    final guestId = body['guestDeviceId'] as String?;
    final code = body['verifyCode'];
    if (pending == null ||
        guestId != pending.guestDeviceId ||
        code != pending.verifyCode) {
      request.response.statusCode = HttpStatus.forbidden;
      await _writeJson(request, {
        'error': 'Codes do not match or the pair expired',
      });
      return;
    }
    if (pending.rejected) {
      request.response.statusCode = HttpStatus.forbidden;
      await _writeJson(request, {'error': 'Pair cancelled'});
      return;
    }
    final match = _hostMatch;
    final ok = await (match?.future ?? Future<bool>.value(false));
    if (!ok || pending.rejected) {
      request.response.statusCode = HttpStatus.forbidden;
      await _writeJson(request, {
        'error': 'Pair cancelled or the codes did not match',
      });
      _pending = null;
      return;
    }
    final token = pairingSessionToken(
      hostSecret: pending.hostSecret,
      guestDeviceId: pending.guestDeviceId,
      guestNonce: pending.guestNonce,
      hostNonce: pending.hostNonce,
    );
    pending.token = token;
    _session = (_session ??
            _Session(
              peer: NearbyPeer(
                deviceId: pending.guestDeviceId,
                name: pending.guestName,
                host: '',
                port: 0,
              ),
              token: token,
              guestNonce: pending.guestNonce,
              hostNonce: pending.hostNonce,
              guest: false,
              verifyCode: pending.verifyCode,
            ))
        .copyWith(token: token);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.paired,
        deviceName: deviceName,
        deviceId: deviceId,
        peerName: pending.guestName,
        peers: _state.peers,
        pairedPeer: _session?.peer,
        status:
            'Paired with ${pending.guestName}. Wait for them to send their shop, or send this shop if they are waiting.',
      ),
    );
    await _writeJson(request, {'token': token});
  }

  Future<void> _onPairCancel(HttpRequest request) async {
    await _readJson(request);
    _failPending(cancel: true);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.looking,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        error: 'The other device cancelled pair.',
        status: 'Looking for Wired Parts on this Wi‑Fi.',
      ),
    );
    await _writeJson(request, {'ok': true});
  }

  Future<void> _onOffer(HttpRequest request) async {
    if (!_authed(request)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await _writeJson(request, {'error': 'Pair again, then send'});
      return;
    }
    final session = _session!;
    final body = await _readJson(request);
    if (!identical(_session, session)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await _writeJson(request, {'error': 'Pair again, then send'});
      return;
    }
    if (_offerDecision != null || _state.phase == NearbyPhase.transferring) {
      request.response.statusCode = HttpStatus.conflict;
      await _writeJson(request, {
        'error': 'Finish the current shop copy first',
      });
      return;
    }
    final offer = NearbyOffer(
      sourceDeviceId: body['sourceDeviceId'] as String? ?? '',
      sourceName: body['sourceName'] as String? ?? 'Other device',
      jobs: body['jobs'] as int? ?? 0,
      parts: body['parts'] as int? ?? 0,
      photos: body['photos'] as int? ?? 0,
      bytes: body['bytes'] as int? ?? 0,
    );
    if (offer.sourceDeviceId != session.peer.deviceId ||
        offer.bytes <= 0 ||
        offer.bytes > kMaxNearbyTransferBytes) {
      request.response.statusCode = HttpStatus.badRequest;
      await _writeJson(request, {'error': 'Damaged shop offer'});
      return;
    }
    final decision = Completer<bool>();
    _offerDecision = decision;
    _emit(
      NearbyViewState(
        phase: NearbyPhase.offering,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        incoming: offer,
        peerName: offer.sourceName,
        status:
            '${offer.sourceName} wants to send their shop (${offer.summary}). Accept replaces catalog, jobs, and photos on this device.',
      ),
    );
    final accepted = await decision.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () => false,
    );
    if (identical(_offerDecision, decision)) _offerDecision = null;
    if (!accepted || !identical(_session, session)) {
      request.response.statusCode = HttpStatus.forbidden;
      await _writeJson(request, {
        'error': 'They declined, or accept timed out. Nothing was copied.',
      });
      return;
    }
    _acceptedOffer = _AcceptedOffer(
      offer: offer,
      token: session.token,
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    );
    await _writeJson(request, {'ok': true});
  }

  Future<void> _onTransfer(HttpRequest request) async {
    if (!_authed(request)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await _writeJson(request, {'error': 'Pair again, then send'});
      return;
    }
    final accepted = _acceptedOffer;
    if (accepted == null ||
        accepted.claimed ||
        accepted.token != _bearer(request) ||
        !DateTime.now().isBefore(accepted.expiresAt)) {
      request.response.statusCode = HttpStatus.forbidden;
      await _writeJson(request, {
        'error': 'Accept this shop before receiving it',
      });
      return;
    }
    accepted.claimed = true;
    final length = request.contentLength;
    if (length != accepted.offer.bytes) {
      request.response.statusCode = HttpStatus.badRequest;
      await _writeJson(request, {
        'error': 'Transfer does not match the accepted shop',
      });
      return;
    }
    if (length > kMaxNearbyTransferBytes) {
      request.response.statusCode = HttpStatus.requestEntityTooLarge;
      await _writeJson(request, {'error': 'Shop is too large to send this way'});
      return;
    }
    _emit(
      _state.copyWith(
        phase: NearbyPhase.transferring,
        status: 'Receiving shop…',
        progress: 0,
      ),
    );
    final builder = BytesBuilder(copy: false);
    var got = 0;
    await for (final chunk in request) {
      got += chunk.length;
      if (got > kMaxNearbyTransferBytes) {
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
        await _writeJson(request, {'error': 'Shop is too large to send this way'});
        return;
      }
      builder.add(chunk);
      final total = length > 0 ? length : got;
      _emit(
        _state.copyWith(
          progress: total == 0 ? 0 : got / total,
          status:
              'Receiving shop… ${((total == 0 ? 0 : got / total) * 100).round()}%',
        ),
      );
    }
    final bytes = builder.takeBytes();
    final token = _bearer(request) ?? _session?.token ?? '';
    try {
      final decrypted = await _codec.decrypt(Uint8List.fromList(bytes), token);
      final offer = decrypted.offer;
      if (offer.sourceDeviceId != accepted.offer.sourceDeviceId ||
          offer.sourceName != accepted.offer.sourceName ||
          offer.jobs != accepted.offer.jobs ||
          offer.parts != accepted.offer.parts ||
          offer.photos != accepted.offer.photos ||
          got != accepted.offer.bytes) {
        throw const NearbyException(
          'Transfer does not match the accepted shop',
        );
      }
      if (!identical(_acceptedOffer, accepted)) {
        request.response.statusCode = HttpStatus.forbidden;
        await _writeJson(request, {'error': 'Shop acceptance was cancelled'});
        return;
      }
      _acceptedOffer = null;
      await applyPayload(decrypted.payload);
      _emit(
        NearbyViewState(
          phase: NearbyPhase.success,
          deviceName: deviceName,
          deviceId: deviceId,
          peers: _state.peers,
          peerName: decrypted.offer.sourceName,
          successMessage:
              'Received shop from ${decrypted.offer.sourceName} (${decrypted.offer.summary}). This device kept its own id.',
          status: 'Shop received.',
          progress: 1,
        ),
      );
      await _writeJson(request, {'ok': true});
    } catch (e) {
      _fail(_crewError(e, 'Receive failed. This shop was not replaced.'));
      request.response.statusCode = HttpStatus.badRequest;
      await _writeJson(request, {'error': '$e'});
    }
  }

  bool _authed(HttpRequest request) {
    final token = _bearer(request);
    final session = _session;
    return token != null &&
        session != null &&
        session.token.isNotEmpty &&
        token == session.token;
  }

  String? _bearer(HttpRequest request) {
    final raw = request.headers.value(HttpHeaders.authorizationHeader);
    if (raw == null || !raw.startsWith('Bearer ')) return null;
    return raw.substring(7);
  }

  Future<Map<String, Object?>> _jsonPost(
    NearbyPeer peer,
    String path,
    Map<String, Object?> body, {
    String? token,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final client = HttpClient();
    try {
      final req = await client
          .post(peer.host, peer.port, path)
          .timeout(timeout);
      req.headers.contentType = ContentType.json;
      if (token != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close().timeout(timeout);
      final text = await utf8.decoder.bind(res).join();
      final Object? decoded = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
      if (decoded is! Map) {
        throw const NearbyException('Damaged reply from the other device');
      }
      final map = Map<String, Object?>.from(decoded);
      if (res.statusCode >= 400) {
        throw NearbyException(map['error'] as String? ?? 'Nearby request failed');
      }
      return map;
    } on TimeoutException {
      throw const NearbyException(
        'The other device did not answer. Keep Nearby open on both, same Wi‑Fi.',
      );
    } on SocketException {
      throw const NearbyException(
        'Could not reach the other device. Same Wi‑Fi? Firewall allowing Wired Parts?',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _putBytes(
    NearbyPeer peer,
    String path,
    Uint8List bytes, {
    required String token,
    required void Function(double progress) onProgress,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.put(peer.host, peer.port, path);
      req.headers.contentType = ContentType.binary;
      req.headers.contentLength = bytes.length;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      const chunk = 64 * 1024;
      for (var i = 0; i < bytes.length; i += chunk) {
        final end = i + chunk > bytes.length ? bytes.length : i + chunk;
        req.add(bytes.sublist(i, end));
        onProgress(end / bytes.length);
      }
      final res = await req.close().timeout(const Duration(minutes: 10));
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode >= 400) {
        String message = 'Send failed';
        try {
          final Object? decoded = jsonDecode(text);
          if (decoded is Map && decoded['error'] is String) {
            message = decoded['error'] as String;
          }
        } catch (_) {}
        throw NearbyException(message);
      }
    } on TimeoutException {
      throw const NearbyException(
        'Send stalled. Keep Nearby open. This shop on the other device was not replaced.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.isEmpty) return {};
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const NearbyException('Damaged nearby request');
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<void> _writeJson(
    HttpRequest request,
    Map<String, Object?> body,
  ) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  void _failPending({required bool cancel}) {
    _acceptedOffer = null;
    _pairTimer?.cancel();
    _pairTimer = null;
    if (cancel) _pending?.rejected = true;
    if (_hostMatch != null && !_hostMatch!.isCompleted) {
      _hostMatch!.complete(false);
    }
    _hostMatch = null;
    if (_offerDecision != null && !_offerDecision!.isCompleted) {
      _offerDecision!.complete(false);
    }
    _offerDecision = null;
  }

  void _fail(String message) {
    _failPending(cancel: true);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.failed,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        error: message,
        status: message,
      ),
    );
  }

  String _crewError(Object e, String fallback) {
    if (e is NearbyException) return e.message;
    final s = '$e';
    if (s.isEmpty) return fallback;
    return '$fallback: $s';
  }

  Uint8List _nonce() {
    return Uint8List.fromList(List<int>.generate(16, (_) => _random.nextInt(256)));
  }

  void _emit(NearbyViewState next) {
    _state = next;
    if (!_stateCtrl.isClosed) _stateCtrl.add(next);
  }

  Future<void> dispose() async {
    await stop();
    await _stateCtrl.close();
  }
}

class _PendingPair {
  _PendingPair({
    required this.guestDeviceId,
    required this.guestName,
    required this.guestNonce,
    required this.hostNonce,
    required this.hostSecret,
    required this.verifyCode,
  });

  final String guestDeviceId;
  final String guestName;
  final List<int> guestNonce;
  final List<int> hostNonce;
  final List<int> hostSecret;
  final int verifyCode;
  var rejected = false;
  String token = '';
}

class _Session {
  const _Session({
    required this.peer,
    required this.token,
    required this.guestNonce,
    required this.hostNonce,
    required this.guest,
    required this.verifyCode,
  });

  final NearbyPeer peer;
  final String token;
  final List<int> guestNonce;
  final List<int> hostNonce;
  final bool guest;
  final int verifyCode;

  _Session copyWith({String? token, NearbyPeer? peer}) => _Session(
    peer: peer ?? this.peer,
    token: token ?? this.token,
    guestNonce: guestNonce,
    hostNonce: hostNonce,
    guest: guest,
    verifyCode: verifyCode,
  );
}

extension on NearbyViewState {
  NearbyViewState copyWith({
    NearbyPhase? phase,
    String? deviceName,
    String? deviceId,
    String? status,
    String? error,
    String? verifyCode,
    String? peerName,
    List<NearbyPeer>? peers,
    NearbyOffer? incoming,
    double? progress,
    String? successMessage,
    NearbyPeer? pairedPeer,
  }) {
    return NearbyViewState(
      phase: phase ?? this.phase,
      deviceName: deviceName ?? this.deviceName,
      deviceId: deviceId ?? this.deviceId,
      status: status ?? this.status,
      error: error,
      verifyCode: verifyCode ?? this.verifyCode,
      peerName: peerName ?? this.peerName,
      peers: peers ?? this.peers,
      incoming: incoming ?? this.incoming,
      progress: progress ?? this.progress,
      successMessage: successMessage ?? this.successMessage,
      pairedPeer: pairedPeer ?? this.pairedPeer,
    );
  }
}

class _AcceptedOffer {
  _AcceptedOffer({
    required this.offer,
    required this.token,
    required this.expiresAt,
  });

  final NearbyOffer offer;
  final String token;
  final DateTime expiresAt;
  bool claimed = false;
}
