import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../installation/installation_security.dart';
import 'company_bootstrap.dart';
import '../nearby/nearby_controller.dart';
import '../nearby/nearby_discovery.dart';

/// Explicit approval and consent; Match alone never enrolls a company device.
class CompanyJoinPage extends StatefulWidget {
  const CompanyJoinPage({
    required this.enrollment,
    this.approver,
    this.reconnect = false,
    this.createController,
    super.key,
  });
  final CompanyEnrollment enrollment;
  final OwnerSession? approver;
  final bool reconnect;
  final NearbyController Function(String encounterAlias)? createController;
  @override
  State<CompanyJoinPage> createState() => _CompanyJoinPageState();
}

class _CompanyJoinPageState extends State<CompanyJoinPage>
    with WidgetsBindingObserver {
  late final CompanyJoin _join;
  late final CompanyPeerAuthentication _authentication;
  List<RetainedCompanyPeer> _retained = const [];
  RetainedCompanyPeer? _selected;
  late final NearbyController _controller;
  StreamSubscription<NearbyViewState>? _subscription;
  NearbyJoinChannel? _channel;
  Future<NearbyJoinChannel>? _channelPending;
  NearbyPairedJoinSession? _pair;
  VerifiedJoinRequest? _request;
  VerifiedPeerMembership? _peerMembership;
  CompanyCreatedJobSync? _jobSync;
  Timer? _jobAvailabilityTimer;
  String? _lastConfirmedJobSync;
  CompanyJoinPreview? _preview;
  String? _error;
  String _status = 'Pair and compare the code on both devices.';
  bool _busy = false;
  bool _activated = false;
  bool _confirmed = false;
  bool _closed = false;
  bool get _approving => widget.approver != null && !widget.reconnect;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _join = CompanyJoin(enrollment: widget.enrollment);
    _authentication = CompanyPeerAuthentication(enrollment: widget.enrollment);
    final alias = const Uuid().v4();
    _controller =
        widget.createController?.call(alias) ??
        NearbyController(
          deviceId: alias,
          deviceName: 'Nearby ${alias.substring(0, 6)}',
          discovery: LanNearbyDiscovery(),
          companyJoin: true,
        );
    _controller.onJoinMessage = _receive;
    _subscription = _controller.states.listen((_) {
      if (mounted) setState(() {});
    });
    _run(() async {
      if (widget.reconnect) {
        final peers = await _authentication.retainedPeers(
          session: widget.approver!,
        );
        if (mounted) setState(() => _retained = peers);
      }
      await _controller.start();
    });
  }

  Future<NearbyJoinChannel> _currentChannel(NearbyPairedJoinSession pair) {
    if (!mounted || _closed) {
      throw const CompanyBootstrapRefusal('Join is closed');
    }
    pair.requireCurrent();
    if (identical(pair, _pair)) return _channelPending!;
    _channel?.close();
    _jobAvailabilityTimer?.cancel();
    _jobSync?.close();
    _jobSync = null;
    _peerMembership = null;
    _channel = null;
    _pair = pair;
    _request = null;
    _preview = null;
    _confirmed = false;
    // All first users of this actual Pair share its single derivation.
    return _channelPending = NearbyJoinChannel.fromPairedSession(pair)
        .then((channel) {
          if (!mounted || _closed || !identical(pair, _pair)) {
            channel.close();
            throw const CompanyBootstrapRefusal('Join connection changed');
          }
          try {
            pair.requireCurrent();
          } catch (_) {
            channel.close();
            rethrow;
          }
          _channel = channel;
          return channel;
        });
  }

  Future<Map<String, Object?>> _receive(
    NearbyPairedJoinSession pair,
    Map<String, Object?> wire,
  ) async {
    final channel = await _currentChannel(pair);
    if (widget.reconnect) {
      if (wire['kind'] == 'created-jobs') {
        final sync = _jobSync;
        if (sync == null) {
          throw const CompanyBootstrapRefusal('Enable manual Job sync first');
        }
        return sync.receive(wire);
      }
      Map<String, Object?>? reply;
      if (wire['kind'] == 'peer-init') {
        reply = await _authentication.receivePeerChallenge(
          channel,
          wire,
          session: widget.approver!,
        );
      } else if (wire['kind'] == 'peer-response') {
        reply = await _authentication.receivePeerResponse(channel, wire);
      } else if (wire['kind'] == 'peer-complete') {
        final result = await _authentication.receivePeerCompletion(
          channel,
          wire,
        );
        await result.membership.requireCurrent();
        _peerMembership = result.membership;
        reply = result.acknowledgment;
        if (mounted) {
          setState(
            () =>
                _status = 'Trusted peer authenticated. Confirming completion.',
          );
        }
      } else if (wire['kind'] == 'peer-ack') {
        final membership = await _authentication.receivePeerAcknowledgment(
          channel,
          wire,
        );
        await membership.requireCurrent();
        _peerMembership = membership;
        if (mounted) {
          setState(
            () => _status = 'Trusted peer authenticated. Verification alone does not exchange Jobs.',
          );
        }
      } else {
        throw const CompanyBootstrapRefusal('Unexpected peer proof');
      }
      // Let the incoming HTTP request finish. The controller's existing queue
      // owns outbound sequence order, including this reply and completion.
      if (reply != null) unawaited(_sendPeerReply(reply));
    } else if (_approving && wire['kind'] == 'request') {
      final request = await _join.receiveJoinRequest(channel, wire);
      if (_request != null) {
        throw const CompanyBootstrapRefusal(
          'Finish the current approval first',
        );
      }
      if (!mounted) throw const CompanyBootstrapRefusal('Join is closed');
      setState(() {
        _request = request;
        _status = 'Review this installation before approving.';
      });
    } else if (!_approving && wire['kind'] == 'provision') {
      final preview = await _join.receiveProvision(channel, wire);
      if (!mounted) throw const CompanyBootstrapRefusal('Join is closed');
      setState(() {
        _preview = preview;
        _status = 'Review the company and choose whether to join.';
      });
    } else if (_approving && wire['kind'] == 'ack') {
      await _join.acknowledgeJoin(
        channel,
        wire,
        ownerSession: widget.approver!,
      );
      if (mounted) {
        setState(() {
          _confirmed = true;
          _status = 'The other installation confirmed activation.';
        });
      }
    } else {
      throw const CompanyBootstrapRefusal('Unexpected Join message');
    }
    return {'ok': true};
  }

  Future<void> _sendPeerReply(Map<String, Object?> wire) async {
    try {
      await _controller.sendJoinMessage(wire);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _enableJobSync() async {
    final peer = _peerMembership;
    if (peer == null) {
      throw const CompanyBootstrapRefusal('Verify the retained peer first');
    }
    final available = await CompanyJobSyncAvailability.open(
      enrollment: widget.enrollment,
      owner: widget.approver!,
      peer: peer,
    );
    if (!mounted || _closed) {
      available.close();
      return;
    }
    final sync = _jobSync = CompanyCreatedJobSync(
      availability: available,
      controller: _controller,
      onStatus: (status) {
        if (mounted && !_closed) {
          setState(() {
            _status = status;
            if (status.startsWith('Job snapshot synced.')) {
              _lastConfirmedJobSync = status;
            }
          });
        }
      },
    );
    _jobAvailabilityTimer?.cancel();
    final remaining =
        _controller.pairedJoinSession?.timeUntilExpiry ?? Duration.zero;
    _jobAvailabilityTimer = Timer(
      remaining + const Duration(milliseconds: 1),
      () {
        if (mounted && !_closed && identical(_jobSync, sync)) {
          setState(() {});
        }
      },
    );
    setState(
      () => _status = 'Ready to exchange Jobs with this verified peer while this page is open and unlocked. Either device can choose Sync Now.',
    );
  }

  Future<void> _syncJobs() async {
    final sync = _jobSync;
    if (sync == null) {
      throw const CompanyBootstrapRefusal('Enable manual Job sync first');
    }
    setState(
      () => _status = 'Exchanging offline-created Jobs in both directions.',
    );
    final result = await sync.syncNow();
    if (mounted && !_closed) setState(() => _status = result.message);
  }

  Future<void> _challenge() async {
    final pair = _controller.pairedJoinSession;
    if (pair == null || _selected == null) {
      throw const CompanyBootstrapRefusal(
        'Select a retained peer and pair first',
      );
    }
    final channel = await _currentChannel(pair);
    final wire = await _authentication.beginPeerChallenge(
      channel,
      _selected!,
      session: widget.approver!,
    );
    if (mounted) {
      setState(
        () => _status = 'Checking the selected retained peer. The first encrypted signature may identify this installation to that endpoint.',
      );
    }
    await _controller.sendJoinMessage(wire);
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestJoin() async {
    final pair = _controller.pairedJoinSession;
    if (pair == null) {
      throw const CompanyBootstrapRefusal('Compare and match the code first');
    }
    final channel = await _currentChannel(pair);
    await _controller.sendJoinMessage(await _join.beginJoin(channel));
    if (mounted) {
      setState(
        () => _status = 'Waiting for explicit approval on the company device.',
      );
    }
  }

  Future<void> _approve() async {
    final wire = await _join.approveJoin(
      _channel!,
      _request!,
      ownerSession: widget.approver!,
    );
    if (mounted) {
      setState(
        () => _status = 'Provision prepared locally. Waiting for the other installation to consent.',
      );
    }
    await _controller.sendJoinMessage(wire);
  }

  Future<void> _accept() async {
    await _join.acceptProvision(_preview!);
    if (mounted) {
      setState(() {
        _activated = true;
        _status = 'Joined locally. Sending activation confirmation.';
      });
    }
    await _acknowledge();
  }

  Future<void> _acknowledge() async {
    await _controller.sendJoinMessage(
      await _join.activationAcknowledgment(_channel!),
    );
    if (mounted) {
      setState(() {
        _confirmed = true;
        _status = 'Joined. Sign in with the existing company PIN. Reconnect to the trusted peer and enable Job availability to use Sync Now.';
      });
    }
  }

  Future<void> _cancel() async {
    _jobAvailabilityTimer?.cancel();
    await _jobSync?.closeAndDrain();
    _channel?.close();
    await _controller.stop();
    if (mounted) Navigator.of(context).pop(_activated);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _jobAvailabilityTimer?.cancel();
      _jobSync?.close();
      _channel?.close();
      _controller.stop();
      if (mounted) {
        setState(() {
          _closed = true;
          _request = null;
          _preview = null;
          _retained = const [];
          _selected = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _jobAvailabilityTimer?.cancel();
    _jobSync?.close();
    WidgetsBinding.instance.removeObserver(this);
    _channel?.close();
    _controller.onJoinMessage = null;
    _subscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_closed) {
      return Scaffold(
        appBar: AppBar(title: const Text('Company connection closed')),
        body: Center(
          child: TextButton(
            onPressed: _cancel,
            child: const Text('Return and sign in to pair again'),
          ),
        ),
      );
    }
    final state = _controller.state;
    final jobsLive = _jobSync?.isLive ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.reconnect
              ? 'Verify retained company peer'
              : _approving
              ? 'Approve company device'
              : 'Join company nearby',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Use the same Wi-Fi. Match establishes a private channel; company access still requires approval and consent.',
          ),
          Text(_status, key: const Key('company-join-status')),
          if (_busy)
            const LinearProgressIndicator(key: Key('company-join-busy')),
          if (_lastConfirmedJobSync case final confirmed?)
            if (_status != confirmed || !jobsLive)
              Text(
                'Last successful exchange: $confirmed',
                key: const Key('company-jobs-last-confirmed'),
              ),
          if (_jobSync != null && !jobsLive)
            const Text(
              'This connection is no longer available. Pair again and verify the company device.',
            ),
          if (_error ?? state.error case final error?)
            Text(error, key: const Key('company-join-error')),
          if (state.verifyCode case final code?) ...[
            Text(code, key: const Key('company-join-code')),
            const Text('Compare this code in person on both devices.'),
            FilledButton(
              key: const Key('company-join-match'),
              onPressed: _busy ? null : () => _run(_controller.confirmCode),
              child: const Text('Codes match'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(_controller.rejectCode),
              child: const Text('Codes differ'),
            ),
          ],
          for (final peer in state.peers)
            ListTile(
              title: Text(peer.name),
              trailing: OutlinedButton(
                key: ValueKey('company-join-pair-${peer.deviceId}'),
                onPressed: _busy
                    ? null
                    : () => _run(() => _controller.pair(peer)),
                child: const Text('Pair'),
              ),
            ),
          if (widget.reconnect) ...[
            const Text(
              'Choose a previously approved installation. Starting verification sends one encrypted installation signature before the endpoint is authenticated. This does not introduce unknown peers or sync Jobs.',
            ),
            for (final peer in _retained)
              ListTile(
                key: ValueKey('company-peer-${peer.deviceId}'),
                title: Text(peer.deviceId),
                subtitle: Text(peer.fingerprint),
                selected: identical(_selected, peer),
                onTap: _busy ? null : () => setState(() => _selected = peer),
              ),
            FilledButton(
              key: const Key('company-peer-verify'),
              onPressed:
                  _busy ||
                      _selected == null ||
                      _controller.pairedJoinSession == null
                  ? null
                  : () => _run(_challenge),
              child: const Text('Verify selected retained peer'),
            ),
            if (_peerMembership != null && _jobSync == null)
              FilledButton(
                key: const Key('company-jobs-enable-sync'),
                onPressed: _busy ? null : () => _run(_enableJobSync),
                child: const Text('Make Jobs available to this verified peer'),
              ),
            if (_jobSync != null)
              FilledButton(
                key: const Key('company-jobs-sync-now'),
                onPressed: _busy || !jobsLive ? null : () => _run(_syncJobs),
                child: const Text('Sync Now'),
              ),
          ],
          if (!widget.reconnect &&
              !_approving &&
              _controller.pairedJoinSession != null &&
              _preview == null &&
              !_activated)
            FilledButton(
              key: const Key('company-join-request'),
              onPressed: _busy ? null : () => _run(_requestJoin),
              child: const Text('Request company approval'),
            ),
          if (_approving && _request != null) ...[
            Text(
              'Installation fingerprint: ${_request!.recipientFingerprint}',
              key: const Key('company-join-recipient'),
            ),
            Text(
              'Enroll this installation for ${widget.approver!.identity.name} as the existing company user. Its PIN stays the same. It cannot enroll others.',
            ),
            FilledButton(
              key: const Key('company-join-approve'),
              onPressed: _busy || _confirmed ? null : () => _run(_approve),
              child: const Text('Approve this installation'),
            ),
            TextButton(
              key: const Key('company-join-deny'),
              onPressed: _busy ? null : () => _run(_cancel),
              child: const Text('Deny and close'),
            ),
          ],
          if (!_approving && _preview != null) ...[
            Text(
              _preview!.identity.name,
              key: const Key('company-join-company'),
            ),
            Text(
              'Company: ${_preview!.identity.companyId}\nUser: ${_preview!.identity.userId}',
            ),
            const Text(
              'Only company identity and the existing PIN credential are provisioned. No Jobs, Parts, photos or authority recovery seed are copied. Local continuity cannot know unseen offline revocations.',
            ),
            if (!_activated)
              FilledButton(
                key: const Key('company-join-consent'),
                onPressed: _busy ? null : () => _run(_accept),
                child: const Text('Join this company'),
              ),
            if (_activated && !_confirmed)
              FilledButton(
                key: const Key('company-join-ack-retry'),
                onPressed: _busy ? null : () => _run(_acknowledge),
                child: const Text('Retry activation confirmation'),
              ),
          ],
          TextButton(
            key: const Key('company-join-close'),
            onPressed: _busy ? null : () => _run(_cancel),
            child: Text(_activated ? 'Continue to sign in' : 'Close Join'),
          ),
        ],
      ),
    );
  }
}
