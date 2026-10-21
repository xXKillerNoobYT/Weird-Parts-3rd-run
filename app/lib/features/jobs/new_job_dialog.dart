import 'dart:async';

import 'package:flutter/material.dart';

import '../edit_drafts/edit_draft_widgets.dart';
import '../edit_drafts/edit_drafts.dart';

class NewJobDialog extends StatefulWidget {
  const NewJobDialog({required this.edits, super.key});

  final EditDrafts edits;

  @override
  State<NewJobDialog> createState() => _NewJobDialogState();
}

class _NewJobDialogState extends State<NewJobDialog> {
  final _controller = TextEditingController();
  NewJobEditSession? _session;
  EditOpening<NewJobEditSession>? _opening;
  NewJobCreated? _created;
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
    session.replace(NewJobInput(nameText: _controller.text));
    if (mounted) setState(() => _error = null);
  }

  Future<void> _openDraft() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final opening = await widget.edits.openNewJob();
      if (!mounted) {
        if (opening is FreshEdit<NewJobEditSession>) {
          await opening.session.leave(LeaveIntent.back);
        }
        return;
      }
      if (opening is FreshEdit<NewJobEditSession>) {
        await _useSession(opening.session);
      } else if (opening is NewJobCreated) {
        setState(() {
          _created = opening;
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

  Future<void> _useSession(NewJobEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    _applyingInput = true;
    setState(() {
      _session = session;
      _opening = null;
      _created = null;
      _controller.text = session.initial.nameText;
    });
    _applyingInput = false;
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<NewJobEditSession> opening:
        await opening.discard();
      case BlockedEdit<NewJobEditSession> opening:
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
      final created = await session.save();
      _openCreated(created);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openCreated(NewJobCreated created) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop<NewJobCreated>(created);
  }

  Future<void> _startAnother() async {
    final created = _created;
    if (_busy || created == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await created.acknowledge();
      if (!mounted) return;
      setState(() => _created = null);
      await _openDraft();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      } else if (intent == LeaveIntent.discard && _opening != null) {
        switch (_opening) {
          case RecoverableEdit<NewJobEditSession> opening:
            await opening.discard();
          case BlockedEdit<NewJobEditSession> opening:
            await opening.discard();
          default:
            break;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop<NewJobCreated>();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_opening case final opening?) {
      return EditOpeningPanel<NewJobEditSession>(
        opening: opening,
        onResume: _useSession,
        onDiscard: _discardRecovery,
      );
    }
    if (_created case final created?) {
      return ListView(
        children: [
          Text('Created ${created.name}'),
          if (_error != null) ...[const SizedBox(height: 12), Text(_error!)],
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 8),
      children: [
        if (_session case final session?)
          EditStatusBanner(status: session.status),
        TextField(
          controller: _controller,
          autofocus: _session != null,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Job name',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => _save(),
        ),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!)],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<NewJobCreated>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave(LeaveIntent.back);
    },
    child: AlertDialog(
      title: const Text('New job'),
      content: SizedBox(
        width: 420,
        height: _opening != null ? 250 : 160,
        child: _content(),
      ),
      actions: [
        if (_created case final created?) ...[
          TextButton(
            onPressed: _busy ? null : () => _openCreated(created),
            child: const Text('Open job'),
          ),
          TextButton(
            onPressed: _busy ? null : _startAnother,
            child: const Text('Start another job'),
          ),
        ],
        TextButton(
          onPressed: _busy || _loading
              ? null
              : () => _leave(LeaveIntent.discard),
          child: Text(_created == null ? 'Cancel' : 'Close'),
        ),
        if (_opening == null && _created == null)
          FilledButton(
            onPressed:
                _busy ||
                    _loading ||
                    _session == null ||
                    _controller.text.trim().isEmpty
                ? null
                : _save,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create'),
          ),
      ],
    ),
  );
}
