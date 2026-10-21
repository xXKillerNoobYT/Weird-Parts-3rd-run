import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../edit_drafts/edit_draft_widgets.dart';
import '../edit_drafts/edit_drafts.dart';

class WarehouseCountDialog extends StatefulWidget {
  const WarehouseCountDialog({
    required this.edits,
    required this.locationId,
    required this.part,
    required this.head,
    super.key,
  });

  final EditDrafts edits;
  final String locationId;
  final Part part;
  final WarehouseCount? head;

  @override
  State<WarehouseCountDialog> createState() => _WarehouseCountDialogState();
}

class _WarehouseCountDialogState extends State<WarehouseCountDialog> {
  final _quantityController = TextEditingController();
  final _noteController = TextEditingController();
  WarehouseCountEditSession? _session;
  EditOpening<WarehouseCountEditSession>? _opening;
  WarehouseCountSaved? _saved;
  DateTime _observedAt = DateTime.now();
  bool _loading = true;
  bool _busy = false;
  bool _applyingInput = false;
  bool _allowPop = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _quantityController.addListener(_capture);
    _noteController.addListener(_capture);
    _openDraft();
  }

  @override
  void dispose() {
    _quantityController.removeListener(_capture);
    _noteController.removeListener(_capture);
    final session = _session;
    if (session != null) {
      unawaited(session.leave(LeaveIntent.back).catchError((Object _) {}));
    }
    _quantityController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _capture() {
    if (_applyingInput) return;
    final session = _session;
    if (session == null) return;
    session.replace(
      WarehouseCountInput(
        quantityText: _quantityController.text,
        noteText: _noteController.text,
        observedAt: _observedAt,
      ),
    );
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
      final opening = await widget.edits.openWarehouseCount(
        locationId: widget.locationId,
        partId: widget.part.id,
        uom: widget.part.uom,
        expectedPriorCountId: widget.head?.id,
      );
      if (!mounted) {
        if (opening is FreshEdit<WarehouseCountEditSession>) {
          await opening.session.leave(LeaveIntent.back);
        }
        return;
      }
      if (opening is FreshEdit<WarehouseCountEditSession>) {
        await _useSession(opening.session);
      } else if (opening is WarehouseCountSaved) {
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

  Future<void> _useSession(WarehouseCountEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    _applyingInput = true;
    setState(() {
      _session = session;
      _opening = null;
      _saved = null;
      _quantityController.text = session.initial.quantityText;
      _noteController.text = session.initial.noteText;
      _observedAt = session.initial.observedAt.toLocal();
    });
    _applyingInput = false;
  }

  Future<void> _chooseTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _observedAt,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_observedAt),
    );
    if (time == null || !mounted) return;
    setState(
      () => _observedAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
    _capture();
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<WarehouseCountEditSession> opening:
        await opening.discard();
      case BlockedEdit<WarehouseCountEditSession> opening:
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
    final quantity = double.tryParse(_quantityController.text.trim());
    if (quantity == null || !quantity.isFinite || quantity < 0) {
      setState(
        () => _error = 'Enter a finite, nonnegative quantity. Zero is a count.',
      );
      return;
    }
    _capture();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await session.save();
      if (mounted) Navigator.of(context).pop<WarehouseCountSaved>(saved);
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
          case RecoverableEdit<WarehouseCountEditSession> opening:
            await opening.discard();
          case BlockedEdit<WarehouseCountEditSession> opening:
            await opening.discard();
          default:
            break;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop<WarehouseCountSaved>();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_opening case final opening?) {
      return EditOpeningPanel<WarehouseCountEditSession>(
        opening: opening,
        onResume: _useSession,
        onDiscard: _discardRecovery,
      );
    }
    if (_saved case final saved?) {
      final count = saved.count;
      return ListView(
        children: [
          Text('Saved ${_quantity(count.quantity)} ${count.uom}'),
          Text('Observed ${_stamp(count.observedAt)}'),
          if (count.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(count.note),
          ],
          if (_error != null) ...[const SizedBox(height: 12), Text(_error!)],
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4),
      children: [
        Text(
          widget.head == null
              ? 'Not counted'
              : 'Previous observation: ${_quantity(widget.head!.quantity)} ${widget.head!.uom}',
        ),
        Text(
          'Record the absolute physical quantity in ${widget.part.uom}. No conversion is applied.',
        ),
        if (_session case final session?)
          EditStatusBanner(status: session.status),
        TextField(
          controller: _quantityController,
          enabled: !_busy,
          autofocus: _session != null,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Count quantity'),
          onSubmitted: (_) => _save(),
        ),
        TextButton(
          onPressed: _busy ? null : _chooseTime,
          child: Text('Observed ${_stamp(_observedAt)}'),
        ),
        TextField(
          controller: _noteController,
          enabled: !_busy,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Count note'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<WarehouseCountSaved>(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave(LeaveIntent.back);
    },
    child: AlertDialog(
      title: Text(_saved == null ? 'Count ${widget.part.name}' : 'Count saved'),
      content: SizedBox(
        width: 480,
        height: _opening != null ? 250 : 390,
        child: _content(),
      ),
      actions: [
        if (_saved case final saved?) ...[
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).pop<WarehouseCountSaved>(saved),
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
          if (_opening == null)
            FilledButton(
              onPressed: _busy || _loading || _session == null ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save count'),
            ),
        ],
      ],
    ),
  );
}

String _quantity(double quantity) =>
    quantity.toString().replaceFirst(RegExp(r'\.0$'), '');

String _stamp(DateTime time) => time.toUtc().toIso8601String();
