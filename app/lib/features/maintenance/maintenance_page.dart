import 'package:flutter/material.dart';

import '../../app.dart';
import '../pin/pin_gate.dart';
import 'maintenance_repository.dart';

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key});

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

enum _TaxonomyKind { categories, styles, types, devices, brands, suppliers }

class _MaintenancePageState extends State<MaintenancePage> {
  late final MaintenanceRepository _repo;
  _TaxonomyKind _kind = _TaxonomyKind.categories;
  List<_NamedRow> _rows = [];
  bool _loading = true;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _repo = MaintenanceRepository(scope.db, scope.pin, scope.deviceId);
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final rows = await _loadRows(_kind);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<List<_NamedRow>> _loadRows(_TaxonomyKind kind) async {
    switch (kind) {
      case _TaxonomyKind.categories:
        final items = await _repo.listCategories();
        return [for (final i in items) _NamedRow(i.id, i.name)];
      case _TaxonomyKind.styles:
        final items = await _repo.listStyles();
        final cats = await _repo.listCategories();
        final names = {for (final c in cats) c.id: c.name};
        return [
          for (final i in items)
            _NamedRow(i.id, i.name, subtitle: names[i.categoryId]),
        ];
      case _TaxonomyKind.types:
        final items = await _repo.listTypes();
        final styles = await _repo.listStyles();
        final names = {for (final s in styles) s.id: s.name};
        return [
          for (final i in items)
            _NamedRow(i.id, i.name, subtitle: names[i.styleId]),
        ];
      case _TaxonomyKind.devices:
        final items = await _repo.listDevices();
        return [for (final i in items) _NamedRow(i.id, i.name)];
      case _TaxonomyKind.brands:
        final items = await _repo.listBrands();
        return [for (final i in items) _NamedRow(i.id, i.name)];
      case _TaxonomyKind.suppliers:
        final items = await _repo.listSuppliers();
        return [for (final i in items) _NamedRow(i.id, i.name)];
    }
  }

  Future<bool> _gate() async {
    final scope = AppScope.of(context);
    return ensurePinUnlocked(context, scope.pin);
  }

  Future<void> _add() async {
    if (!await _gate() || !mounted) return;

    switch (_kind) {
      case _TaxonomyKind.categories:
      case _TaxonomyKind.devices:
      case _TaxonomyKind.brands:
      case _TaxonomyKind.suppliers:
        await _addNamed();
      case _TaxonomyKind.styles:
        await _addStyle();
      case _TaxonomyKind.types:
        await _addType();
    }
  }

  Future<void> _addNamed() async {
    final name = await _promptName(title: 'Add ${_label(_kind)}');
    if (name == null || name.isEmpty) return;
    try {
      switch (_kind) {
        case _TaxonomyKind.categories:
          await _repo.createCategory(name);
        case _TaxonomyKind.devices:
          await _repo.createDevice(name);
        case _TaxonomyKind.brands:
          await _repo.createBrand(name);
        case _TaxonomyKind.suppliers:
          await _repo.createSupplier(name);
        default:
          break;
      }
      await _reload();
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addStyle() async {
    final categories = await _repo.listCategories();
    if (!mounted) return;
    if (categories.isEmpty) {
      _showMessage('Add a category first');
      return;
    }

    String? categoryId = categories.first.id;
    final nameController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Add style'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: categoryId,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      for (final c in categories)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setLocal(() => categoryId = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                    autofocus: true,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (categoryId == null ||
                        nameController.text.trim().isEmpty) {
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
    final name = nameController.text.trim();
    nameController.dispose();
    if (ok != true || categoryId == null || name.isEmpty) return;
    try {
      await _repo.createStyle(categoryId: categoryId!, name: name);
      await _reload();
    } on StateError catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _addType() async {
    final styles = await _repo.listStyles();
    if (!mounted) return;
    if (styles.isEmpty) {
      _showMessage('Add a style first');
      return;
    }

    String? styleId = styles.first.id;
    final nameController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Add type'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: styleId,
                    decoration: const InputDecoration(labelText: 'Style'),
                    items: [
                      for (final s in styles)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (v) => setLocal(() => styleId = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                    autofocus: true,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (styleId == null || nameController.text.trim().isEmpty) {
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );
    final name = nameController.text.trim();
    nameController.dispose();
    if (ok != true || styleId == null || name.isEmpty) return;
    try {
      await _repo.createType(styleId: styleId!, name: name);
      await _reload();
    } on StateError catch (e) {
      _showMessage(e.message);
    }
  }

  Future<String?> _promptName({required String title}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
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
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  String _label(_TaxonomyKind kind) {
    switch (kind) {
      case _TaxonomyKind.categories:
        return 'Categories';
      case _TaxonomyKind.styles:
        return 'Styles';
      case _TaxonomyKind.types:
        return 'Types';
      case _TaxonomyKind.devices:
        return 'Devices';
      case _TaxonomyKind.brands:
        return 'Brands';
      case _TaxonomyKind.suppliers:
        return 'Suppliers';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Maintenance')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                for (final kind in _TaxonomyKind.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(_label(kind)),
                      selected: _kind == kind,
                      onSelected: (_) {
                        setState(() => _kind = kind);
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(child: Text('No ${_label(_kind).toLowerCase()} yet'))
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final row = _rows[index];
                          return ListTile(
                            title: Text(row.name),
                            subtitle: row.subtitle != null
                                ? Text(row.subtitle!)
                                : null,
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        tooltip: 'Add',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _NamedRow {
  _NamedRow(this.id, this.name, {this.subtitle});

  final String id;
  final String name;
  final String? subtitle;
}
