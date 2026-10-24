import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'edit_drafts.dart';

class EditStatusBanner extends StatelessWidget {
  const EditStatusBanner({required this.status, super.key});

  final ValueListenable<EditStatus> status;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EditStatus>(
    valueListenable: status,
    builder: (context, value, _) {
      final message = switch (value.phase) {
        EditPhase.durable when value.latestSequence == value.durableSequence =>
          'Unfinished edits saved on this device',
        EditPhase.storageFailed =>
          'Unfinished edits could not be saved. ${value.error ?? ''}',
        EditPhase.recoveryBlocked =>
          'Unfinished edits are blocked. ${value.error ?? ''}',
        EditPhase.saving => 'Saving changes...',
        EditPhase.saveFailed =>
          'Save failed. Unfinished input remains on this device. ${value.error ?? ''}',
        EditPhase.closed => 'This edit session is closed',
        EditPhase.unpersisted when value.latestSequence == 0 =>
          'No unfinished changes',
        EditPhase.unpersisted => 'Unfinished edits are not saved yet',
        EditPhase.writing ||
        EditPhase.durable => 'Saving unfinished edits on this device...',
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(message, key: const ValueKey('edit-draft-status')),
      );
    },
  );
}

class EditOpeningPanel<S> extends StatefulWidget {
  const EditOpeningPanel({
    required this.opening,
    required this.onResume,
    required this.onDiscard,
    super.key,
  });

  final EditOpening<S> opening;
  final Future<void> Function(S) onResume;
  final Future<void> Function() onDiscard;

  @override
  State<EditOpeningPanel<S>> createState() => _EditOpeningPanelState<S>();
}

class _EditOpeningPanelState<S> extends State<EditOpeningPanel<S>> {
  bool _busy = false;
  Object? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opening = widget.opening;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (opening is RecoverableEdit<S>) ...[
          const Text('Unfinished edits are available on this device.'),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final session = await opening.resume();
                    await widget.onResume(session);
                  }),
            child: const Text('Resume'),
          ),
        ],
        if (opening is BlockedEdit<S>) ...[
          const Text('Unfinished edits cannot be resumed.'),
          Text(opening.reason),
          if (opening.preservedInput != null) ...[
            const SizedBox(height: 12),
            const Text('Preserved input'),
            SelectableText(opening.preservedInput!),
          ],
        ],
        TextButton(
          onPressed: _busy ? null : () => _run(widget.onDiscard),
          child: const Text('Discard unfinished edits'),
        ),
        if (_error != null) Text('Could not continue. $_error'),
      ],
    );
  }
}
