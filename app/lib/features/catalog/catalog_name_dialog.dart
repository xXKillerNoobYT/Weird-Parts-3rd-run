import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../edit_drafts/edit_draft_widgets.dart';
import '../edit_drafts/edit_drafts.dart';

Future<void> showCatalogNameDialog(
  BuildContext context, {
  required CatalogNameTarget target,
  required String title,
  required Future<void> Function(CatalogNameSaved) onSaved,
  required ValueChanged<String> onNotice,
}) async {
  final edits = AppScope.of(context).edits;
  if (edits == null) throw StateError('Unfinished edits are unavailable');
  final saved = await showDialog<CatalogNameSaved>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        CatalogNameDialog(edits: edits, target: target, title: title),
  );
  if (!context.mounted || saved == null) return;
  final label = switch (saved.kind) {
    CatalogNameKind.category => 'Category',
    CatalogNameKind.type => 'Type',
    CatalogNameKind.variant => 'Variant',
  };
  void notice(String message) {
    if (!context.mounted) return;
    onNotice(message);
  }

  try {
    await onSaved(saved);
  } catch (error) {
    notice('$label saved: ${saved.name}. Refresh pending: $error');
    return;
  }
  if (!context.mounted) return;
  notice('$label saved: ${saved.name}');
  await WidgetsBinding.instance.endOfFrame;
  try {
    await saved.acknowledge();
  } catch (error) {
    notice('$label saved: ${saved.name}. Confirmation remains pending: $error');
  }
}

class CatalogNameDialog extends StatefulWidget {
  const CatalogNameDialog({
    required this.edits,
    required this.target,
    required this.title,
    super.key,
  });

  final EditDrafts edits;
  final CatalogNameTarget target;
  final String title;

  @override
  State<CatalogNameDialog> createState() => _CatalogNameDialogState();
}

class _CatalogNameDialogState extends State<CatalogNameDialog> {
  final _controller = TextEditingController();
  CatalogNameEditSession? _session;
  EditOpening<CatalogNameEditSession>? _opening;
  CatalogNameSaved? _saved;
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
    session.replace(CatalogNameInput(nameText: _controller.text));
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
      final opening = await widget.edits.openCatalogName(widget.target);
      if (!mounted) {
        if (opening is FreshEdit<CatalogNameEditSession>) {
          await opening.session.leave(LeaveIntent.back);
        }
        return;
      }
      if (opening is FreshEdit<CatalogNameEditSession>) {
        await _useSession(opening.session);
      } else if (opening is CatalogNameSaved) {
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

  Future<void> _useSession(CatalogNameEditSession session) async {
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
      case RecoverableEdit<CatalogNameEditSession> opening:
        await opening.discard();
      case BlockedEdit<CatalogNameEditSession> opening:
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
      if (mounted) {
        setState(
          () => _error = error is StateError ? error.message : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish(CatalogNameSaved saved) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop<CatalogNameSaved>(saved);
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
          case RecoverableEdit<CatalogNameEditSession> opening:
            await opening.discard();
          case BlockedEdit<CatalogNameEditSession> opening:
            await opening.discard();
          default:
            break;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop<CatalogNameSaved>();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_opening case final opening?) {
      return Column(
        children: [
          Expanded(
            child: EditOpeningPanel<CatalogNameEditSession>(
              opening: opening,
              onResume: _useSession,
              onDiscard: _discardRecovery,
            ),
          ),
          if (_error != null) Text(_error!),
        ],
      );
    }
    if (_saved case final saved?) {
      return ListView(children: [Text('Saved ${saved.name}')]);
    }
    return ListView(
      padding: const EdgeInsets.only(top: 8),
      children: [
        if (_session case final session?) ...[
          EditStatusBanner(status: session.status),
          ValueListenableBuilder<EditStatus>(
            valueListenable: session.status,
            builder: (context, status, _) => TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy && status.phase != EditPhase.closed,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => _save(),
            ),
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
  Widget build(BuildContext context) => PopScope<CatalogNameSaved>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave(LeaveIntent.back);
    },
    child: AlertDialog(
      title: Text(_saved == null ? widget.title : 'Name saved'),
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
