import 'package:flutter/material.dart';

Future<String?> promptName(
  BuildContext context, {
  required String title,
  String? initial,
  String label = 'Name',
}) async {
  final controller = TextEditingController(text: initial ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) {
            final v = controller.text.trim();
            if (v.isNotEmpty) Navigator.pop(ctx, v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isEmpty) return;
              Navigator.pop(ctx, v);
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return result;
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = 'Remove',
  bool destructive = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: destructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error,
                  )
                : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
