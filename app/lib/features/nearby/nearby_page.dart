import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../backup/backup_codec.dart';
import '../backup/backup_store.dart';
import '../catalog/tree_edit_prompts.dart';
import '../pin/pin_gate.dart';
import 'nearby_controller.dart';
import 'nearby_discovery.dart';
import 'nearby_protocol.dart';

typedef NearbyControllerFactory = NearbyController Function({
  required String deviceId,
  required String deviceName,
  required AppDatabase db,
});

class NearbyPage extends StatefulWidget {
  const NearbyPage({
    this.controller,
    this.createController,
    this.flushWal,
    super.key,
  });

  final NearbyController? controller;
  final NearbyControllerFactory? createController;
  final Future<void> Function()? flushWal;

  @override
  State<NearbyPage> createState() => _NearbyPageState();
}

class _NearbyPageState extends State<NearbyPage> {
  NearbyController? _owned;
  NearbyController? _active;
  StreamSubscription<NearbyViewState>? _sub;
  NearbyViewState _state = const NearbyViewState(
    phase: NearbyPhase.starting,
    deviceName: '',
    deviceId: '',
    status: 'Opening Nearby…',
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_active != null) return;
    final scope = AppScope.of(context);
    final existing = widget.controller;
    if (existing != null) {
      _active = existing;
      _state = existing.state;
      _sub = existing.states.listen((s) {
        if (mounted) setState(() => _state = s);
      });
      return;
    }
    _start(scope);
  }

  Future<void> _start(AppScope scope) async {
    var name = await scope.db.settingsDao.deviceDisplayName();
    if (name == 'This device' || name.trim().isEmpty) {
      name = defaultNearbyName(scope.deviceId);
    }
    final controller = widget.createController?.call(
          deviceId: scope.deviceId,
          deviceName: name,
          db: scope.db,
        ) ??
        NearbyController(
          deviceId: scope.deviceId,
          deviceName: name,
          discovery: LanNearbyDiscovery(),
          collectPayload: () => collectNearbyShop(
            db: scope.db,
            deviceId: scope.deviceId,
            deviceName: name,
            flushWal: widget.flushWal,
          ),
          applyPayload: (payload) async {
            final restore = scope.restoreFromPayload;
            if (restore == null) {
              throw const NearbyException(
                'This build cannot receive a shop. Update Wired Parts.',
              );
            }
            if (!BackupIo.tryStart()) {
              throw const RestoreBusyException();
            }
            try {
              await restore(payload);
            } finally {
              BackupIo.end();
            }
          },
        );
    _owned = controller;
    _active = controller;
    _sub = controller.states.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    await controller.start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _owned?.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    final next = await promptName(
      context,
      title: 'Name on this Wi‑Fi',
      initial: _state.deviceName,
      label: 'Device name',
    );
    if (next == null || !mounted) return;
    await AppScope.of(context).db.settingsDao.setDeviceDisplayName(next);
    await _active?.rename(next);
  }

  Future<void> _send(NearbyPeer peer) async {
    if (!await ensurePinUnlocked(context, AppScope.of(context).pin)) return;
    if (!mounted) return;
    final ok = await confirmAction(
      context,
      title: 'Send this shop to ${peer.label}?',
      body:
          'Copies jobs, catalog, and photos onto ${peer.label}. That replaces '
          'the shop over there. Not two-way sync.',
      confirmLabel: 'Send this shop',
      destructive: true,
    );
    if (!ok || !mounted) return;
    if (!BackupIo.tryStart()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(kBackupAlreadyInProgressMessage)),
      );
      return;
    }
    try {
      await _active?.sendTo(peer);
    } finally {
      BackupIo.end();
    }
  }

  Future<void> _accept() async {
    if (!await ensurePinUnlocked(context, AppScope.of(context).pin)) return;
    if (!mounted) return;
    final offer = _state.incoming;
    final ok = await confirmAction(
      context,
      title: 'Accept this shop?',
      body:
          'Replaces catalog, jobs, and photos on this device with the shop from '
          '${offer?.sourceName ?? 'the other device'} (${offer?.summary ?? ''}). '
          'Cannot undo. This device keeps its own id.',
      confirmLabel: 'Accept shop',
    );
    if (!ok || !mounted) {
      await _active?.declineOffer();
      return;
    }
    await _active?.acceptOffer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nearby')),
      body: NearbyView(
        state: _state,
        onRename: _rename,
        onPair: (peer) => _active?.pair(peer),
        onConfirmCode: () => _active?.confirmCode(),
        onRejectCode: () => _active?.rejectCode(),
        onAcceptOffer: _accept,
        onDeclineOffer: () => _active?.declineOffer(),
        onSend: _send,
        onRetry: () async {
          await _active?.stop();
          if (!mounted) return;
          await _active?.start();
        },
      ),
    );
  }
}

class NearbyView extends StatelessWidget {
  const NearbyView({
    required this.state,
    required this.onRename,
    required this.onPair,
    required this.onConfirmCode,
    required this.onRejectCode,
    required this.onAcceptOffer,
    required this.onDeclineOffer,
    required this.onSend,
    required this.onRetry,
    super.key,
  });

  final NearbyViewState state;
  final VoidCallback onRename;
  final ValueChanged<NearbyPeer> onPair;
  final VoidCallback onConfirmCode;
  final VoidCallback onRejectCode;
  final VoidCallback onAcceptOffer;
  final VoidCallback onDeclineOffer;
  final ValueChanged<NearbyPeer> onSend;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ListTile(
          leading: const Icon(Icons.wifi),
          title: Text(state.deviceName.isEmpty ? 'This device' : state.deviceName),
          subtitle: const Text('Name the other device will see on this Wi‑Fi'),
          trailing: TextButton(onPressed: onRename, child: const Text('Rename')),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(state.status),
        ),
        if (state.error != null)
          ListTile(
            leading: Icon(Icons.error_outline, color: scheme.error),
            title: Text(
              'Nearby failed',
              style: TextStyle(color: scheme.error),
            ),
            subtitle: Text(state.error!),
            trailing: TextButton(onPressed: onRetry, child: const Text('Try again')),
          ),
        if (state.successMessage != null)
          ListTile(
            leading: Icon(Icons.check_circle_outline, color: scheme.primary),
            title: const Text('Nearby finished'),
            subtitle: Text(state.successMessage!),
          ),
        if (state.verifyCode != null) ...[
          const ListTile(
            title: Text('Match this code'),
            subtitle: Text(
              'Both screens must show the same numbers. Do not tap Match if they differ.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              state.verifyCode!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                letterSpacing: 8,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          OverflowBar(
            alignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: onRejectCode,
                child: const Text("Codes don't match"),
              ),
              FilledButton(
                onPressed: onConfirmCode,
                child: const Text('Match'),
              ),
            ],
          ),
        ],
        if (state.incoming != null && state.phase == NearbyPhase.offering) ...[
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text('Incoming shop from ${state.incoming!.sourceName}'),
            subtitle: Text(
              '${state.incoming!.summary}. Accept replaces the shop on this device.',
            ),
          ),
          OverflowBar(
            alignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: onDeclineOffer,
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: onAcceptOffer,
                child: const Text('Accept shop'),
              ),
            ],
          ),
        ],
        if (state.progress != null &&
            (state.phase == NearbyPhase.transferring ||
                state.phase == NearbyPhase.success))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: state.progress),
                const SizedBox(height: 8),
                Text('${((state.progress ?? 0) * 100).round()}%'),
              ],
            ),
          ),
        const Divider(),
        const ListTile(
          title: Text('Devices on this Wi‑Fi'),
          subtitle: Text(
            'Not Bluetooth. Not internet. The other device must have Nearby open.',
          ),
        ),
        if (state.peers.isEmpty &&
            state.phase != NearbyPhase.pairing &&
            state.phase != NearbyPhase.offering &&
            state.phase != NearbyPhase.transferring)
          const ListTile(
            leading: Icon(Icons.search),
            title: Text('None found yet'),
            subtitle: Text(
              'Keep this page open. On the other device: More → Nearby. Same Wi‑Fi.',
            ),
          ),
        for (final peer in state.peers)
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: Text(peer.label),
            subtitle: Text(
              state.pairedPeer?.deviceId == peer.deviceId
                  ? 'Paired. Send copies this shop over there (one-way).'
                  : 'Tap to pair. You will both confirm a code.',
            ),
            trailing: state.pairedPeer?.deviceId == peer.deviceId
                ? FilledButton(
                    onPressed: state.phase == NearbyPhase.transferring
                        ? null
                        : () => onSend(peer),
                    child: const Text('Send this shop'),
                  )
                : TextButton(
                    onPressed: state.phase == NearbyPhase.pairing
                        ? null
                        : () => onPair(peer),
                    child: const Text('Pair'),
                  ),
          ),
      ],
    );
  }
}

Future<({BackupPayload payload, NearbyOffer offer})> collectNearbyShop({
  required AppDatabase db,
  required String deviceId,
  required String deviceName,
  BackupStore store = const BackupStore(),
  Future<void> Function()? flushWal,
}) async {
  if (flushWal != null) {
    await flushWal();
  } else {
    await checkpointWalForExport(db);
  }
  final sqlite = await store.sqliteFile();
  if (!await sqlite.exists()) {
    throw const NearbyException('No local shop to send');
  }
  final sqliteBytes = await sqlite.readAsBytes();
  final payload = await store.collect(
    sourceDeviceId: deviceId,
    createdAt: DateTime.now().toUtc(),
    sqliteBytes: sqliteBytes,
  );
  final jobs = (await db.jobsDao.listActiveJobs()).length;
  final parts = (await db.partsDao.listParts()).length;
  return (
    payload: payload,
    offer: NearbyOffer(
      sourceDeviceId: deviceId,
      sourceName: deviceName,
      jobs: jobs,
      parts: parts,
      photos: payload.photos.length,
      bytes: sqliteBytes.length,
    ),
  );
}
