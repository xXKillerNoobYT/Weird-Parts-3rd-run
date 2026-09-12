import 'package:flutter/material.dart';

import 'pin_service.dart';

Future<bool> showPinGate(BuildContext context, PinService pin) async {
  final controller = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Editor PIN'),
      content: TextField(
        controller: controller,
        obscureText: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'PIN'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final unlocked = await pin.unlock(controller.text);
            if (ctx.mounted) Navigator.pop(ctx, unlocked);
          },
          child: const Text('Unlock'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
