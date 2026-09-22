import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../backup/backup_codec.dart';
import 'nearby_codec.dart';
import 'nearby_discovery.dart';
import 'nearby_protocol.dart';
import 'nearby_pairing.dart';
import 'nearby_wifi.dart';

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
    this.status = 'Open Nearby on the other device. Stay on the same Wi‑Fi.',
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

  bool get running => phase != NearbyPhase.idle && phase != NearbyPhase.failed;
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
    this.peerAllowed,
    this.readNetwork = readNearbyWifiNetwork,
  });

  final String deviceId;
  String deviceName;
  final NearbyDiscovery discovery;
  final Future<({BackupPayload payload, NearbyOffer offer})> Function()
  collectPayload;
  final NearbyApplyPayload applyPayload;
  final InternetAddress? bindAddress;
  final Future<List<String>> Function()? localIps;
  final NearbyCodec? codec;
  final bool Function(String host)? peerAllowed;
  final Future<NearbyWifiNetwork> Function() readNetwork;

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
  int _lifecycle = 0;
  int? _discoveryOwner;
  bool _disposed = false;
  Future<void>? _disposal;
  NearbyWifiNetwork? _wifi;
  StreamSubscription<List<NearbyPeer>>? _peerSub;
  _PairAttempt? _pending;
  int _pairGeneration = 0;
  final _pairStarts = <DateTime>[];
  final _authenticated = Expando<_AuthenticatedRequest>();
  _Session? _session;
  Completer<bool>? _hostMatch;
  Completer<bool>? _offerDecision;
  _AcceptedOffer? _acceptedOffer;
  Timer? _pairTimer;

  Future<void> start() async {
    if (_disposed) return;
    if (_state.phase != NearbyPhase.idle &&
        _state.phase != NearbyPhase.failed) {
      return;
    }
    final generation = ++_lifecycle;
    HttpServer? server;
    NearbyWifiNetwork? wifi;
    _emit(
      NearbyViewState(
        phase: NearbyPhase.starting,
        deviceName: deviceName,
        deviceId: deviceId,
        status: 'Opening Nearby on this Wi‑Fi…',
      ),
    );
    try {
      wifi = bindAddress == null ? await readNetwork() : null;
      if (generation != _lifecycle) return;
      server = wifi != null
          ? await wifi.listen()
          : await HttpServer.bind(bindAddress!, 0);
      if (generation != _lifecycle) {
        await _closeServer(server, wifi);
        return;
      }
      _server = server;
      _wifi = wifi;
      server.listen(
        _handleHttp,
        onError: (Object e) {
          if (generation == _lifecycle) {
            _fail('Nearby connection failed: $e');
          }
        },
      );
      final ips = wifi != null
          ? [wifi.address]
          : await (localIps ?? localIpv4Addresses)();
      if (generation != _lifecycle) {
        await _closeServer(server, wifi);
        return;
      }
      final advertiseIps = ips.isNotEmpty ? ips : [server.address.address];
      _peerSub = discovery.peers.listen(
        (peers) {
          if (generation != _lifecycle || _state.phase == NearbyPhase.starting) {
            return;
          }
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
        },
        onError: (Object error) {
          unawaited(_discoveryFailed(generation, error));
        },
      );
      _discoveryOwner = generation;
      await discovery.start(
        deviceId: deviceId,
        name: deviceName,
        port: server.port,
        ips: advertiseIps,
      );
      if (generation != _lifecycle) {
        if (_discoveryOwner == generation) await discovery.stop();
        await _closeServer(server, wifi);
        return;
      }
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
      if (generation != _lifecycle) {
        await _closeServer(server, wifi);
        return;
      }
      await stop();
      if (!_disposed && _lifecycle == generation + 1) {
        _fail(
          'Could not listen on this Wi-Fi. Allow Wired Parts through the firewall and try again. $e',
        );
      }
    }
  }

  Future<void> _discoveryFailed(int generation, Object error) async {
    if (generation != _lifecycle || _disposed) return;
    await stop();
    if (!_disposed && _lifecycle == generation + 1) {
      _fail(
        'Nearby discovery stopped. Check local network access and reopen Nearby. $error',
      );
    }
  }

  Future<void> _closeServer(HttpServer? server, NearbyWifiNetwork? wifi) async {
    try {
      await server?.close(force: true);
    } finally {
      await wifi?.close();
    }
  }

  Future<void> stop() async {
    ++_lifecycle;
    _failPending(cancel: true);
    final peerSub = _peerSub;
    final server = _server;
    final wifi = _wifi;
    _peerSub = null;
    _server = null;
    _wifi = null;
    final stopDiscovery = discovery.stop();
    final closeServer = _closeServer(server, wifi);
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
    await Future.wait<void>([
      if (peerSub != null) peerSub.cancel(),
      stopDiscovery,
      closeServer,
    ]);
  }

  Future<void> rename(String name) async {
    final trimmed = name.trim();
    deviceName = trimmed.isEmpty ? defaultNearbyName(deviceId) : trimmed;
    final generation = _lifecycle;
    final port = _server?.port;
    if (port != null) {
      final ips = _wifi != null
          ? [_wifi!.address]
          : await (localIps ?? localIpv4Addresses)();
      if (generation != _lifecycle) return;
      await discovery.updateAdvertisement(
        name: deviceName,
        port: port,
        ips: ips.isNotEmpty ? ips : [InternetAddress.loopbackIPv4.address],
      );
    }
    if (generation == _lifecycle && !_disposed) {
      _emit(_state.copyWith(deviceName: deviceName));
    }
  }

  Future<void> pair(NearbyPeer peer) async {
    if (_server == null) {
      _fail('Nearby is not listening. Open this page again.');
      return;
    }
    _failPending(cancel: true);
    final generation = _pairGeneration;
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
      final context = NearbyPairContext(
        id: nearbyRandomId(),
        guestId: deviceId,
        hostId: peer.deviceId,
        guestName: deviceName,
        hostName: peer.name,
        guestPort: _server!.port,
        hostPort: peer.port,
      );
      final agreement = await NearbyPendingPair.create(context, guest: true);
      if (generation != _pairGeneration) return;
      final attempt = _PairAttempt(peer, agreement);
      _pending = attempt;
      _armPairExpiry(attempt);
      final start = await _jsonPost(peer, '/v2/pair/start', {
        ...context.toJson(),
        'commitment': agreement.commitment,
      });
      if (!identical(_pending, attempt)) return;
      agreement.receiveCommitment(start['commitment']);
      final revealed = await _jsonPost(
        peer,
        '/v2/pair/reveal',
        agreement.reveal(),
      );
      final match = await agreement.receiveReveal(revealed);
      if (!identical(_pending, attempt)) return;
      attempt.match = match;
      _showMatch(attempt);
    } catch (e) {
      if (generation == _pairGeneration) {
        _fail(_crewError(e, 'Could not reach ${peer.label}'));
      }
    }
  }

  void _armPairExpiry(_PairAttempt attempt) {
    _pairTimer?.cancel();
    _pairTimer = Timer(const Duration(minutes: 2), () {
      if (identical(_pending, attempt)) _fail('Pair expired. Try again.');
    });
  }

  void _showMatch(_PairAttempt attempt) {
    _emit(
      NearbyViewState(
        phase: NearbyPhase.pairing,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        peerName: attempt.peer.label,
        verifyCode: attempt.match!.code,
        status:
            'Check that ${attempt.peer.label} shows this same code, then tap Match.',
      ),
    );
  }

  void _paired(_PairAttempt attempt, NearbySessionKeys keys) {
    _pairTimer?.cancel();
    _pairTimer = null;
    _pending = null;
    _hostMatch = null;
    _session = _Session(attempt.peer, keys);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.paired,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        peerName: attempt.peer.label,
        pairedPeer: attempt.peer,
        status:
            'Paired with ${attempt.peer.label}. Send this shop to replace the shop on that device.',
      ),
    );
  }

  Future<void> confirmCode() async {
    final attempt = _pending;
    final match = attempt?.match;
    if (attempt == null || match == null || attempt.localConfirmed) return;
    attempt.localConfirmed = true;
    final proof = match.confirmLocal();
    _emit(
      _state.copyWith(
        status: 'Waiting for ${attempt.peer.label} to tap Match…',
      ),
    );
    if (!attempt.agreement.guest) {
      _hostMatch?.complete(true);
      return;
    }
    try {
      final reply = await _jsonPost(attempt.peer, '/v2/pair/confirm', {
        'id': match.transactionId,
        'proof': proof,
      }, timeout: const Duration(minutes: 2));
      if (!identical(_pending, attempt)) return;
      match.confirmRemote(reply['proof']);
      _paired(attempt, match.finish());
    } catch (e) {
      if (identical(_pending, attempt)) _fail(_crewError(e, 'Pair failed'));
    }
  }

  Future<void> rejectCode() async {
    final attempt = _pending;
    final session = _session;
    _failPending(cancel: true);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.looking,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        error: 'Pair cancelled. Codes must match on both screens.',
        status: 'Tap a device to pair. You will both see a 6-digit code.',
      ),
    );
    try {
      if (session != null) {
        await _jsonPost(session.peer, '/v2/pair/cancel', {}, session: session);
      } else if (attempt != null) {
        await _jsonPost(attempt.peer, '/v2/pair/cancel', {
          'id': attempt.agreement.context.id,
        });
      }
    } catch (_) {}
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
        error:
            'You declined the incoming shop. Nothing on this device changed.',
        status: 'Looking for Wired Parts on this Wi‑Fi.',
      ),
    );
  }

  Future<void> sendTo(NearbyPeer peer) async {
    final session = _session;
    if (session == null || peer != session.peer) {
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
      if (!identical(_session, session)) return;
      final transferId = nearbyRandomId();
      final bytes = await _codec.encrypt(
        payload: packed.payload,
        key: session.keys.sendKey,
        sessionId: session.keys.id,
        direction: session.keys.sendDirection,
        transferId: transferId,
        offer: packed.offer,
      );
      if (!identical(_session, session)) return;
      _emit(
        _state.copyWith(
          status: 'Waiting for ${peer.label} to accept…',
          progress: 0,
        ),
      );
      await _jsonPost(
        peer,
        '/v2/offer',
        {
          'sourceDeviceId': packed.offer.sourceDeviceId,
          'sourceName': packed.offer.sourceName,
          'jobs': packed.offer.jobs,
          'parts': packed.offer.parts,
          'photos': packed.offer.photos,
          'bytes': bytes.length,
          'transferId': transferId,
          'digest': nearbyDigest(bytes),
        },
        session: session,
        timeout: const Duration(minutes: 2),
      );
      if (!identical(_session, session)) return;
      _emit(
        _state.copyWith(status: 'Sending shop to ${peer.label}…', progress: 0),
      );
      await _putBytes(
        peer,
        '/v2/transfer',
        bytes,
        session: session,
        onProgress: (p) {
          if (!identical(_session, session)) return;
          _emit(
            _state.copyWith(
              progress: p,
              status: 'Sending shop to ${peer.label}… ${(p * 100).round()}%',
            ),
          );
        },
      );
      if (!identical(_session, session)) return;
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
      if (identical(_session, session)) {
        _fail(_crewError(e, 'Send did not finish. Check the other device.'));
      }
    }
  }

  Future<void> _handleHttp(HttpRequest request) async {
    try {
      if (!_allowsPeer(request.connectionInfo?.remoteAddress.address ?? '')) {
        request.response.statusCode = HttpStatus.forbidden;
        await _writeJson(request, {'error': 'Use the same Wi-Fi network'});
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/v2/hello') {
        await _writeJson(request, {
          'proto': kNearbyProto,
          'v': kNearbyProtoVersion,
          'deviceId': deviceId,
          'name': deviceName,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v2/pair/start') {
        await _onPairStart(request);
        return;
      }
      if (request.method == 'POST' && path == '/v2/pair/reveal') {
        await _onPairReveal(request);
        return;
      }
      if (request.method == 'POST' && path == '/v2/pair/confirm') {
        await _onPairConfirm(request);
        return;
      }
      if (request.method == 'POST' && path == '/v2/pair/cancel') {
        await _onPairCancel(request);
        return;
      }
      if (request.method == 'POST' && path == '/v2/offer') {
        await _onOffer(request);
        return;
      }
      if (request.method == 'PUT' && path == '/v2/transfer') {
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
    final context = NearbyPairContext.parse(body);
    if (context.hostId != deviceId ||
        context.guestId == deviceId ||
        context.hostPort != _server?.port ||
        context.hostName != deviceName) {
      throw const NearbyException('Pair does not match this device');
    }
    final now = DateTime.now();
    _pairStarts.removeWhere(
      (time) => now.difference(time) > const Duration(minutes: 1),
    );
    if (_pairStarts.length >= 5) {
      request.response.statusCode = HttpStatus.tooManyRequests;
      await _writeJson(request, {
        'error': 'Too many pair attempts. Wait a minute.',
      });
      return;
    }
    _pairStarts.add(now);
    _failPending(cancel: true);
    final generation = _pairGeneration;
    final agreement = await NearbyPendingPair.create(context, guest: false);
    if (generation != _pairGeneration) {
      throw const NearbyException('Pair cancelled');
    }
    agreement.receiveCommitment(body['commitment']);
    final attempt = _PairAttempt(
      NearbyPeer(
        deviceId: context.guestId,
        name: context.guestName,
        host: request.connectionInfo?.remoteAddress.address ?? '',
        port: context.guestPort,
      ),
      agreement,
    );
    _pending = attempt;
    _hostMatch = Completer<bool>();
    _armPairExpiry(attempt);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.pairing,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        peerName: attempt.peer.label,
        status: 'Connecting to ${attempt.peer.label}…',
      ),
    );
    await _writeJson(request, {'commitment': agreement.commitment});
  }

  _PairAttempt _hostAttempt(Map<String, Object?> body) {
    final attempt = _pending;
    if (attempt == null ||
        attempt.agreement.guest ||
        attempt.agreement.context.id != body['id']) {
      throw const NearbyException('Pair expired or was cancelled');
    }
    return attempt;
  }

  Future<void> _onPairReveal(HttpRequest request) async {
    final body = await _readJson(request);
    final attempt = _hostAttempt(body);
    final reveal = attempt.agreement.reveal();
    final match = await attempt.agreement.receiveReveal(body);
    if (!identical(_pending, attempt)) {
      throw const NearbyException('Pair cancelled');
    }
    attempt.match = match;
    _showMatch(attempt);
    await _writeJson(request, reveal);
  }

  Future<void> _onPairConfirm(HttpRequest request) async {
    final body = await _readJson(request);
    final attempt = _hostAttempt(body);
    final match = attempt.match;
    if (match == null) throw const NearbyException('Pair reveal required');
    match.confirmRemote(body['proof']);
    final accepted = await _hostMatch!.future;
    if (!accepted || !identical(_pending, attempt)) {
      throw const NearbyException('Pair cancelled');
    }
    final proof = match.confirmLocal();
    _paired(attempt, match.finish());
    await _writeJson(request, {'proof': proof});
  }

  Future<void> _onPairCancel(HttpRequest request) async {
    final session = _session;
    if (session != null) {
      if (!_authed(request)) {
        request.response.statusCode = HttpStatus.unauthorized;
        await _writeJson(request, {'error': 'Pair again'});
        return;
      }
      await _readJson(request);
      if (!identical(_session, session)) {
        throw const NearbyException('Pair expired');
      }
    } else {
      final body = await _readJson(request);
      if (_pending == null || body['id'] != _pending!.agreement.context.id) {
        throw const NearbyException('Pair expired');
      }
    }
    _failPending(cancel: true);
    _emit(
      NearbyViewState(
        phase: NearbyPhase.looking,
        deviceName: deviceName,
        deviceId: deviceId,
        peers: _state.peers,
        error: 'The other device cancelled pair.',
        status: 'Looking for Wired Parts on this Wi-Fi.',
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
    final transferId = body['transferId'];
    final digest = body['digest'];
    if (transferId is! String ||
        transferId.length > 128 ||
        transferId.isEmpty ||
        digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const NearbyException('Invalid transfer identity');
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
      session: session,
      transferId: transferId,
      digest: digest,
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
        !identical(accepted.session, _session) ||
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
      await _writeJson(request, {
        'error': 'Shop is too large to send this way',
      });
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
      if (!identical(_acceptedOffer, accepted) ||
          !identical(_session, accepted.session)) {
        request.response.statusCode = HttpStatus.forbidden;
        await _writeJson(request, {'error': 'Shop acceptance was cancelled'});
        return;
      }
      got += chunk.length;
      if (got > kMaxNearbyTransferBytes) {
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
        await _writeJson(request, {
          'error': 'Shop is too large to send this way',
        });
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
    final authentication = _authenticated[request]!;
    try {
      authentication.session.keys.verifyBody(authentication.proof, bytes);
      if (nearbyDigest(bytes) != accepted.digest) {
        throw const NearbyException(
          'Transfer does not match the accepted shop',
        );
      }
      final decrypted = await _codec.decrypt(
        Uint8List.fromList(bytes),
        accepted.session.keys.receiveKey,
        sessionId: accepted.session.keys.id,
        direction: accepted.session.keys.receiveDirection,
        transferId: accepted.transferId,
      );
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
      if (!identical(_acceptedOffer, accepted) ||
          !identical(_session, accepted.session) ||
          !DateTime.now().isBefore(accepted.expiresAt)) {
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
      if (identical(_session, accepted.session)) {
        _fail(_crewError(e, 'Receive failed. This shop was not replaced.'));
      }
      request.response.statusCode = HttpStatus.badRequest;
      await _writeJson(request, {'error': '$e'});
    }
  }

  bool _authed(HttpRequest request) {
    final session = _session;
    if (session == null ||
        request.headers.value('x-nearby-session') != session.keys.id) {
      return false;
    }
    try {
      final sequence = int.tryParse(
        request.headers.value('x-nearby-sequence') ?? '',
      );
      final digest = request.headers.value('x-nearby-digest');
      final mac = request.headers.value('x-nearby-mac');
      if (sequence == null || digest == null || mac == null) return false;
      final proof = NearbyRequestProof(sequence, digest, mac);
      session.keys.acceptRequest(request.method, request.uri.path, proof);
      _authenticated[request] = _AuthenticatedRequest(session, proof);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setProof(
    HttpClientRequest request,
    _Session session,
    NearbyRequestProof proof,
  ) {
    request.headers.set('x-nearby-session', session.keys.id);
    request.headers.set('x-nearby-sequence', proof.sequence);
    request.headers.set('x-nearby-digest', proof.digest);
    request.headers.set('x-nearby-mac', proof.mac);
  }

  Future<Map<String, Object?>> _jsonPost(
    NearbyPeer peer,
    String path,
    Map<String, Object?> body, {
    _Session? session,
    Duration timeout = const Duration(seconds: 20),
  }) => _request(
    peer,
    'POST',
    path,
    Uint8List.fromList(utf8.encode(jsonEncode(body))),
    session: session,
    timeout: timeout,
  );

  Future<void> _putBytes(
    NearbyPeer peer,
    String path,
    Uint8List bytes, {
    required _Session session,
    required void Function(double progress) onProgress,
  }) async {
    await _request(
      peer,
      'PUT',
      path,
      bytes,
      session: session,
      timeout: const Duration(minutes: 10),
      onProgress: onProgress,
    );
  }

  Future<Map<String, Object?>> _request(
    NearbyPeer peer,
    String method,
    String path,
    Uint8List bytes, {
    _Session? session,
    Duration timeout = const Duration(seconds: 20),
    void Function(double progress)? onProgress,
  }) async {
    if (!_allowsPeer(peer.host)) {
      throw const NearbyException('Use the same Wi-Fi network');
    }
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final wifi = _wifi;
    if (wifi != null) {
      client.connectionFactory = (uri, proxyHost, proxyPort) =>
          wifi.connect(uri);
    }
    try {
      final req = await client
          .open(method, peer.host, peer.port, path)
          .timeout(timeout);
      req.followRedirects = false;
      req.headers.contentLength = bytes.length;
      req.headers.contentType = method == 'PUT'
          ? ContentType.binary
          : ContentType.json;
      final proof = session?.keys.signRequest(method, path, bytes);
      if (session != null && proof != null) _setProof(req, session, proof);
      const chunk = 64 * 1024;
      for (var i = 0; i < bytes.length; i += chunk) {
        final end = i + chunk > bytes.length ? bytes.length : i + chunk;
        req.add(bytes.sublist(i, end));
        onProgress?.call(end / bytes.length);
      }
      final response = await req.close().timeout(timeout);
      final responseBytes = await _readBounded(
        response,
        64 * 1024,
      ).timeout(timeout);
      if (session != null && proof != null) {
        session.keys.verifyResponse(
          proof,
          method,
          path,
          response.statusCode,
          responseBytes,
          response.headers.value('x-nearby-mac'),
        );
      }
      final map = _decodeJson(responseBytes);
      if (response.statusCode != HttpStatus.ok) {
        throw NearbyException(
          map['error'] is String
              ? map['error']! as String
              : 'Nearby request failed',
        );
      }
      return map;
    } on TimeoutException {
      throw const NearbyException(
        'The other device did not answer. Keep Nearby open on both, same Wi-Fi.',
      );
    } finally {
      client.close(force: true);
    }
  }

  bool _allowsPeer(String host) =>
      (peerAllowed?.call(host) ?? true) && (_wifi?.allowsPeer(host) ?? true);

  Future<Uint8List> _readBounded(Stream<List<int>> stream, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > limit) {
        throw const NearbyException('Nearby message is too large');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Map<String, Object?> _decodeJson(List<int> bytes) {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const NearbyException('Damaged nearby message');
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final bytes = await _readBounded(
      request,
      64 * 1024,
    ).timeout(const Duration(seconds: 20));
    final authentication = _authenticated[request];
    authentication?.session.keys.verifyBody(authentication.proof, bytes);
    return _decodeJson(bytes);
  }

  Future<void> _writeJson(
    HttpRequest request,
    Map<String, Object?> body,
  ) async {
    final bytes = utf8.encode(jsonEncode(body));
    request.response.headers.contentType = ContentType.json;
    final authentication = _authenticated[request];
    if (authentication != null) {
      request.response.headers.set(
        'x-nearby-mac',
        authentication.session.keys.signResponse(
          authentication.proof,
          request.method,
          request.uri.path,
          request.response.statusCode,
          bytes,
        ),
      );
    }
    request.response.add(bytes);
    await request.response.close();
  }

  void _failPending({required bool cancel}) {
    _acceptedOffer = null;
    _pairTimer?.cancel();
    _pairTimer = null;
    _pairGeneration++;
    _pending = null;
    _session = null;
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

  void _emit(NearbyViewState next) {
    _state = next;
    if (!_stateCtrl.isClosed) _stateCtrl.add(next);
  }

  Future<void> dispose() {
    _disposed = true;
    return _disposal ??= _dispose();
  }

  Future<void> _dispose() async {
    await stop();
    await _stateCtrl.close();
  }
}

class _PairAttempt {
  _PairAttempt(this.peer, this.agreement);
  final NearbyPeer peer;
  final NearbyPendingPair agreement;
  NearbyAwaitingMatch? match;
  bool localConfirmed = false;
}

class _Session {
  _Session(this.peer, this.keys);
  final NearbyPeer peer;
  final NearbySessionKeys keys;
}

class _AuthenticatedRequest {
  _AuthenticatedRequest(this.session, this.proof);
  final _Session session;
  final NearbyRequestProof proof;
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
    required this.session,
    required this.transferId,
    required this.digest,
    required this.expiresAt,
  });

  final NearbyOffer offer;
  final _Session session;
  final String transferId;
  final String digest;
  final DateTime expiresAt;
  bool claimed = false;
}
