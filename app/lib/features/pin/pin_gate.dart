import 'package:flutter/material.dart';

import 'pin_service.dart';

Future<bool> showPinGate(BuildContext context, PinService pin) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _PinGateDialog(pin: pin),
  );
  return ok ?? false;
}

/// Returns true if catalog edits are allowed (no PIN, already unlocked, or gate OK).
Future<bool> ensurePinUnlocked(BuildContext context, PinService pin) async {
  if (!await pin.isPinSet()) return true;
  if (pin.isUnlocked) return true;
  if (!context.mounted) return false;
  return showPinGate(context, pin);
}

class _PinGateDialog extends StatefulWidget {
  const _PinGateDialog({required this.pin});

  final PinService pin;

  @override
  State<_PinGateDialog> createState() => _PinGateDialogState();
}

class _PinGateDialogState extends State<_PinGateDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final unlocked = await widget.pin.unlock(_controller.text);
    if (!mounted) return;
    if (unlocked) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _error = 'Wrong PIN';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editor PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            obscureText: true,
            keyboardType: TextInputType.number,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: 'PIN',
              errorText: _error,
            ),
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}
