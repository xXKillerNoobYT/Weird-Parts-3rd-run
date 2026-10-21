import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../maintenance/maintenance_repository.dart';
import '../pin/pin_gate.dart';
import 'tree_edit_prompts.dart';

class PartDetails {
  const PartDetails({
    required this.name,
    required this.categoryId,
    required this.styleId,
    required this.typeId,
  });

  final String name;
  final String categoryId;
  final String styleId;
  final String typeId;
}

class PartDetailsDialog extends StatefulWidget {
  const PartDetailsDialog({
    this.initialName = '',
    this.initialCategoryId,
    this.initialStyleId,
    this.initialTypeId,
    this.title = 'New part',
    this.submitLabel = 'Save',
    this.introduction =
        'Choose a Category, Type, and Variant before saving the part.',
    required this.maintenance,
    super.key,
  });

  final String initialName;
  final String? initialCategoryId;
  final String? initialStyleId;
  final String? initialTypeId;
  final String title;
  final String submitLabel;
  final String introduction;
  final MaintenanceRepository maintenance;

  @override
  State<PartDetailsDialog> createState() => _PartDetailsDialogState();
}

class _PartDetailsDialogState extends State<PartDetailsDialog> {
  late final TextEditingController _name;
  List<Category> _categories = [];
  List<Style> _styles = [];
  List<Type> _variants = [];
  String? _categoryId;
  String? _styleId;
  String? _typeId;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _categoryId = widget.initialCategoryId;
    _styleId = widget.initialStyleId;
    _typeId = widget.initialTypeId;
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<Style> get _typesForCat => _styles
      .where((s) => _categoryId != null && s.categoryId == _categoryId)
      .toList();

  List<Type> get _variantsForType => _variants
      .where((t) => _styleId != null && t.styleId == _styleId)
      .toList();

  Future<bool> _gate() async {
    final scope = AppScope.of(context);
    return ensurePinUnlocked(context, scope.pin);
  }

  Future<void> _load() async {
    final cats = await widget.maintenance.listCategories();
    final styles = await widget.maintenance.listStyles();
    final variants = await widget.maintenance.listTypes();
    if (!mounted) return;
    setState(() {
      _categories = cats;
      _styles = styles;
      _variants = variants;
      if (!cats.any((c) => c.id == _categoryId)) _categoryId = null;
      if (!styles.any((s) => s.id == _styleId && s.categoryId == _categoryId)) {
        _styleId = null;
      }
      if (!variants.any((t) => t.id == _typeId && t.styleId == _styleId)) {
        _typeId = null;
      }
      _loading = false;
    });
  }

  Future<void> _addCategory() async {
    if (!await _gate() || !mounted) return;
    final name = await promptName(context, title: 'Add category');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await widget.maintenance.createCategory(name);
      await _load();
      if (!mounted) return;
      setState(() {
        _categoryId = id;
        _styleId = null;
        _typeId = null;
        _error = null;
      });
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _addType() async {
    if (_categoryId == null) {
      setState(() => _error = 'Set Category first');
      return;
    }
    if (!await _gate() || !mounted) return;
    final name = await promptName(context, title: 'Add type');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await widget.maintenance.createStyle(
        categoryId: _categoryId!,
        name: name,
      );
      await _load();
      if (!mounted) return;
      setState(() {
        _styleId = id;
        _typeId = null;
        _error = null;
      });
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _addVariant() async {
    if (_styleId == null) {
      setState(() => _error = 'Set Type first');
      return;
    }
    if (!await _gate() || !mounted) return;
    final name = await promptName(context, title: 'Add variant');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await widget.maintenance.createType(
        styleId: _styleId!,
        name: name,
      );
      await _load();
      if (!mounted) return;
      setState(() {
        _typeId = id;
        _error = null;
      });
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Part name is required');
      return;
    }
    if (_categoryId == null || _styleId == null || _typeId == null) {
      setState(() => _error = 'Category, Type, and Variant are required');
      return;
    }
    Navigator.pop(
      context,
      PartDetails(
        name: name,
        categoryId: _categoryId!,
        styleId: _styleId!,
        typeId: _typeId!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.introduction),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Part name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TaxonomyPickField(
                      label: 'Category',
                      value: _categoryId,
                      addLabel: 'Add Category',
                      items: [
                        for (final c in _categories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => setState(() {
                        _categoryId = v;
                        _styleId = null;
                        _typeId = null;
                        _error = null;
                      }),
                      onAdd: _addCategory,
                    ),
                    TaxonomyPickField(
                      label: 'Type',
                      value: _styleId,
                      enabled: _categoryId != null,
                      addLabel: 'Add Type',
                      items: [
                        for (final s in _typesForCat)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: (v) => setState(() {
                        _styleId = v;
                        _typeId = null;
                        _error = null;
                      }),
                      onAdd: _addType,
                    ),
                    TaxonomyPickField(
                      label: 'Variant',
                      value: _typeId,
                      enabled: _styleId != null,
                      addLabel: 'Add Variant',
                      items: [
                        for (final t in _variantsForType)
                          DropdownMenuItem(value: t.id, child: Text(t.name)),
                      ],
                      onChanged: (v) => setState(() {
                        _typeId = v;
                        _error = null;
                      }),
                      onAdd: _addVariant,
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
