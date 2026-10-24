import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../edit_drafts/edit_draft_widgets.dart';
import '../edit_drafts/edit_drafts.dart';

class WarehouseLocationDialog extends StatefulWidget {
  const WarehouseLocationDialog({
    required this.edits,
    this.location,
    super.key,
  });

  final EditDrafts edits;
  final WarehouseLocation? location;

  @override
  State<WarehouseLocationDialog> createState() =>
      _WarehouseLocationDialogState();
}

class _WarehouseLocationDialogState extends State<WarehouseLocationDialog> {
  final _controller = TextEditingController();
  WarehouseLocationEditSession? _session;
  EditOpening<WarehouseLocationEditSession>? _opening;
  WarehouseLocationSaved? _saved;
  bool _loading = true;
  bool _busy = false;
  bool _applyingInput = false;
  bool _allowPop = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_capture);
    _openDraft();
  }

  @override
  void dispose() {
    _controller.removeListener(_capture);
    final session = _session;
    if (session != null) {
      unawaited(session.leave(LeaveIntent.back).catchError((Object _) {}));
    }
    _controller.dispose();
    super.dispose();
  }

  void _capture() {
    if (_applyingInput) return;
    final session = _session;
    if (session == null) return;
    session.replace(WarehouseLocationNameInput(nameText: _controller.text));
    if (mounted && _error != null) setState(() => _error = null);
  }

  Future<void> _openDraft() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final location = widget.location;
      final opening = location == null
          ? await widget.edits.openNewWarehouseLocation()
          : await widget.edits.openWarehouseLocationRename(
              locationId: location.id,
              expectedRevision: location.revision,
            );
      if (!mounted) {
        if (opening is FreshEdit<WarehouseLocationEditSession>) {
          await opening.session.leave(LeaveIntent.back);
        }
        return;
      }
      if (opening is FreshEdit<WarehouseLocationEditSession>) {
        await _useSession(opening.session);
      } else if (opening is WarehouseLocationSaved) {
        setState(() {
          _saved = opening;
          _opening = null;
        });
      } else {
        setState(() => _opening = opening);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useSession(WarehouseLocationEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    _applyingInput = true;
    setState(() {
      _session = session;
      _opening = null;
      _saved = null;
      _controller.text = session.initial.nameText;
    });
    _applyingInput = false;
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<WarehouseLocationEditSession> opening:
        await opening.discard();
      case BlockedEdit<WarehouseLocationEditSession> opening:
        await opening.discard();
      default:
        return;
    }
    if (mounted) setState(() => _opening = null);
    await _openDraft();
  }

  Future<void> _save() async {
    final session = _session;
    if (_busy || session == null) return;
    _capture();
    if (_controller.text.trim().isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await session.save();
      _finish(saved);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish(WarehouseLocationSaved saved) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop<WarehouseLocationSaved>(saved);
  }

  Future<void> _leave(LeaveIntent intent) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_session case final session?) {
        await session.leave(intent);
      } else if (intent == LeaveIntent.discard) {
        switch (_opening) {
          case RecoverableEdit<WarehouseLocationEditSession> opening:
            await opening.discard();
          case BlockedEdit<WarehouseLocationEditSession> opening:
            await opening.discard();
          default:
            break;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop<WarehouseLocationSaved>();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_opening case final opening?) {
      return EditOpeningPanel<WarehouseLocationEditSession>(
        opening: opening,
        onResume: _useSession,
        onDiscard: _discardRecovery,
      );
    }
    if (_saved case final saved?) {
      return ListView(children: [Text('Saved ${saved.location.name}')]);
    }
    return ListView(
      padding: const EdgeInsets.only(top: 8),
      children: [
        if (_session case final session?) ...[
          EditStatusBanner(status: session.status),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Name'),
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _save(),
          ),
        ] else
          TextButton(
            onPressed: _busy ? null : _openDraft,
            child: const Text('Retry'),
          ),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!)],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<WarehouseLocationSaved>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave(LeaveIntent.back);
    },
    child: AlertDialog(
      title: Text(
        _saved != null
            ? 'Warehouse saved'
            : widget.location == null
            ? 'New warehouse'
            : 'Rename warehouse',
      ),
      content: SizedBox(
        width: 420,
        height: _opening != null ? 250 : 160,
        child: _content(),
      ),
      actions: [
        if (_saved case final saved?) ...[
          TextButton(
            onPressed: _busy ? null : () => _finish(saved),
            child: const Text('Done'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _leave(LeaveIntent.back),
            child: const Text('Close'),
          ),
        ] else ...[
          TextButton(
            onPressed: _busy || _loading
                ? null
                : () => _leave(LeaveIntent.discard),
            child: const Text('Cancel'),
          ),
          if (_opening == null && _session != null)
            FilledButton(
              onPressed: _busy || _loading ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
        ],
      ],
    ),
  );
}
