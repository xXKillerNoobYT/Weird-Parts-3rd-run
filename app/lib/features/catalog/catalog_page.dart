import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../pin/pin_gate.dart';
import 'catalog_repository.dart';
import 'part_detail_page.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  final _searchController = TextEditingController();
  late final CatalogRepository _catalog;
  List<Part> _parts = [];
  bool _loading = true;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _catalog = CatalogRepository(scope.db, scope.pin, scope.deviceId);
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final all = await _catalog.listParts(activeOnly: false);
    if (!mounted) return;
    setState(() {
      _parts = all;
      _loading = false;
    });
  }

  List<Part> get _filtered {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _parts;
    return _parts
        .where(
          (p) =>
              p.name.toLowerCase().contains(q) ||
              p.description.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  Future<void> _addPart() async {
    final scope = AppScope.of(context);
    final unlocked = await ensurePinUnlocked(context, scope.pin);
    if (!unlocked || !mounted) return;

    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('New part'),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'General part name',
            ),
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) {
              final v = nameController.text.trim();
              if (v.isNotEmpty) Navigator.of(ctx).pop(v);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final v = nameController.text.trim();
                if (v.isEmpty) return;
                Navigator.of(ctx).pop(v);
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    nameController.dispose();
    if (name == null || name.isEmpty || !mounted) return;

    try {
      final id = await _catalog.createGeneralPart(name: name);
      await _reload();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PartDetailPage(partId: id),
        ),
      );
      await _reload();
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  Future<void> _openPart(Part part) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PartDetailPage(partId: part.id),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(title: const Text('Catalog')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search parts',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? const Center(child: Text('No parts yet'))
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final part = items[index];
                          return ListTile(
                            title: Text(part.name),
                            subtitle: Text(
                              [
                                if (part.uom.isNotEmpty) part.uom,
                                if (!part.active) 'Inactive',
                              ].join(' · '),
                            ),
                            onTap: () => _openPart(part),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addPart,
        tooltip: 'New part',
        child: const Icon(Icons.add),
      ),
    );
  }
}
