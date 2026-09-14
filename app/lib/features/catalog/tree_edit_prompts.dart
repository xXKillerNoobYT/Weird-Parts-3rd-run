import 'package:flutter/material.dart';

Future<String?> promptName(
  BuildContext context, {
  required String title,
  String? initial,
  String label = 'Name',
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _NamePromptDialog(
      title: title,
      initial: initial,
      label: label,
    ),
  );
}

class _NamePromptDialog extends StatefulWidget {
  const _NamePromptDialog({
    required this.title,
    required this.label,
    this.initial,
  });

  final String title;
  final String label;
  final String? initial;

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (v.isEmpty) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
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

/// Dropdown plus a labeled Add button under the field (touch, not tooltip-only).
class TaxonomyPickField extends StatelessWidget {
  const TaxonomyPickField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.onAdd,
    required this.addLabel,
    this.enabled = true,
    this.allowNone = false,
    super.key,
  });

  final String label;
  final String? value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?> onChanged;
  final VoidCallback? onAdd;
  final bool enabled;
  final bool allowNone;

  /// Visible Add button text (e.g. "Add Category").
  final String addLabel;

  @override
  Widget build(BuildContext context) {
    final inItems = items.any((i) => i.value == value);
    final resolved = enabled && inItems ? value : null;
    final field = allowNone
        ? DropdownButtonFormField<String?>(
            // ignore: deprecated_member_use
            value: resolved,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('None'),
              ),
              ...items.map(
                (i) => DropdownMenuItem<String?>(
                  value: i.value,
                  child: i.child,
                ),
              ),
            ],
            onChanged: enabled ? onChanged : null,
          )
        : DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: resolved,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            hint: Text(enabled ? 'Select' : 'Set the parent first'),
            items: items,
            onChanged: enabled ? onChanged : null,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(addLabel),
          ),
        ),
      ],
    );
  }
}
