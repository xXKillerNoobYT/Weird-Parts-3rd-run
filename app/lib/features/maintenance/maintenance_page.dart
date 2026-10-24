import 'package:flutter/material.dart';

import '../../app.dart';
import '../catalog/catalog_name_dialog.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/catalog_tree.dart';
import '../catalog/catalog_tree_view.dart';
import '../catalog/part_detail_page.dart';
import '../catalog/part_details_dialog.dart';
import '../catalog/tree_edit_prompts.dart';
import '../edit_drafts/edit_drafts.dart';
import '../pin/pin_gate.dart';
import 'maintenance_repository.dart';

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key});

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

enum _Kind { types, brands, suppliers }

class _MaintenancePageState extends State<MaintenancePage> {
  late final MaintenanceRepository _repo;
  late final CatalogRepository _catalog;
  _Kind _kind = _Kind.types;
  List<_NamedRow> _rows = [];
  List<CatalogTreeNode> _tree = [];
  bool _loading = true;
  bool _initialized = false;
  String? _catalogNameNotice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _repo = MaintenanceRepository(scope.db, scope.pin, scope.deviceId);
    _catalog = CatalogRepository(scope.db, scope.pin, scope.deviceId);
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    if (_kind == _Kind.types) {
      final snap = await _catalog.loadTreeSnapshot();
      if (!mounted) return;
      setState(() {
        _tree = buildCatalogTree(snap);
        _loading = false;
      });
      return;
    }
    final rows = await _loadRows(_kind);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<List<_NamedRow>> _loadRows(_Kind kind) async {
    switch (kind) {
      case _Kind.types:
        return const [];
      case _Kind.brands:
        final items = await _repo.listBrands();
        return [for (final i in items) _NamedRow(i.id, i.name)];
      case _Kind.suppliers:
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
      case _Kind.types:
        await _editTaxonomyName(
          CatalogNameTarget.newCategory(),
          'Add category',
        );
      case _Kind.brands:
        await _editTaxonomyName(CatalogNameTarget.newBrand(), 'Add brand');
      case _Kind.suppliers:
        await _editTaxonomyName(
          CatalogNameTarget.newSupplier(),
          'Add supplier',
        );
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editTaxonomyName(CatalogNameTarget target, String title) async {
    if (mounted) setState(() => _catalogNameNotice = null);
    try {
      await showCatalogNameDialog(
        context,
        target: target,
        title: title,
        onNotice: (message) {
          if (mounted) setState(() => _catalogNameNotice = message);
        },
        onSaved: (saved) async {
          try {
            if (saved.kind != target.kind) {
              throw StateError('The saved catalog name has a different kind');
            }
            await _reload();
            if (!mounted) {
              throw StateError('Maintenance is no longer available');
            }
            if (saved.kind == CatalogNameKind.supplier &&
                (_kind != _Kind.suppliers ||
                    !_rows.any(
                      (row) => row.id == saved.id && row.name == saved.name,
                    ))) {
              throw StateError(
                'The saved supplier is not in the refreshed list',
              );
            }
          } catch (_) {
            if (mounted) setState(() => _loading = false);
            rethrow;
          }
        },
      );
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _addChild(CatalogTreeNode parent) async {
    if (!await _gate() || !mounted) return;
    try {
      switch (parent.kind) {
        case CatalogTreeKind.category:
          await _editTaxonomyName(
            CatalogNameTarget.newType(parent.id),
            'Add type',
          );
          return;
        case CatalogTreeKind.type:
          await _editTaxonomyName(
            CatalogNameTarget.newVariant(parent.id),
            'Add variant',
          );
          return;
        case CatalogTreeKind.variant:
          final saved = await showNewPartDialog(
            context,
            maintenance: _repo,
            initialCategoryId: parent.categoryId,
            initialStyleId: parent.styleId,
            initialTypeId: parent.typeId,
          );
          if (saved == null || !mounted) return;
          try {
            await _reload();
            if (!mounted) return;
            final part = await _catalog.getPart(saved.id);
            bool contains(List<CatalogTreeNode> nodes) => nodes.any(
              (node) =>
                  (node.kind == CatalogTreeKind.part && node.id == saved.id) ||
                  contains(node.children),
            );
            if (_kind != _Kind.types ||
                part == null ||
                !saved.identifies(part) ||
                !contains(_tree)) {
              throw StateError('The saved Part is not in the refreshed tree');
            }
            if (!mounted) return;
            setState(() => _catalogNameNotice = 'Part saved: ${saved.name}');
            await WidgetsBinding.instance.endOfFrame;
          } catch (error) {
            if (mounted) {
              setState(() {
                _loading = false;
                _catalogNameNotice =
                    'Part saved: ${saved.name}. Refresh pending: $error';
              });
            }
            return;
          }
          if (!mounted) return;
          try {
            await saved.acknowledge();
          } catch (error) {
            if (mounted) {
              setState(
                () => _catalogNameNotice =
                    'Part saved: ${saved.name}. Confirmation remains pending: $error',
              );
            }
          }
          return;
        case CatalogTreeKind.part:
        case CatalogTreeKind.brand:
          if (parent.partId == null) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PartDetailPage(
                partId: parent.partId!,
                focusBrandId: parent.brandId,
              ),
            ),
          );
        default:
          return;
      }
      await _reload();
    } on StateError catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _rename(CatalogTreeNode node) async {
    if (!await _gate() || !mounted) return;
    if (node.kind == CatalogTreeKind.part) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PartDetailPage(partId: node.id),
        ),
      );
      if (mounted) await _reload();
      return;
    }
    final target = switch (node.kind) {
      CatalogTreeKind.category => CatalogNameTarget.renameCategory(node.id),
      CatalogTreeKind.type => CatalogNameTarget.renameType(node.id),
      CatalogTreeKind.variant => CatalogNameTarget.renameVariant(node.id),
      CatalogTreeKind.brand when node.brandId != null =>
        CatalogNameTarget.renameBrand(node.brandId!),
      _ => null,
    };
    if (target != null) {
      await _editTaxonomyName(target, 'Rename');
    }
  }

  Future<void> _removeNode(CatalogTreeNode node) async {
    if (!await _gate() || !mounted) return;
    try {
      if (node.kind == CatalogTreeKind.part) {
        final n = await _catalog.countJobLinesForPart(node.id);
        final extra = n > 0
            ? ' It is on $n job line(s); those lines stay on jobs.'
            : '';
        if (!mounted) return;
        final ok = await confirmAction(
          context,
          title: 'Remove part?',
          body: 'Remove "${node.label}" from the catalog.$extra',
        );
        if (!ok || !mounted) return;
        await _catalog.deletePart(node.id);
      } else {
        final ok = await confirmAction(
          context,
          title: 'Remove folder?',
          body: 'Remove empty folder "${node.label}"?',
        );
        if (!ok || !mounted) return;
        await _catalog.deleteEmptyFolder(kind: node.kind, id: node.id);
      }
      await _reload();
    } on StateError catch (e) {
      _showMessage(e.message);
    }
  }

  Future<void> _openPart(CatalogTreeNode node) async {
    if (node.partId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PartDetailPage(partId: node.partId!),
      ),
    );
    await _reload();
  }

  String _label(_Kind kind) {
    switch (kind) {
      case _Kind.types:
        return 'Types';
      case _Kind.brands:
        return 'Brands';
      case _Kind.suppliers:
        return 'Suppliers';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Maintenance')),
      body: Column(
        children: [
          if (_catalogNameNotice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Semantics(
                liveRegion: true,
                child: Text(_catalogNameNotice!),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                for (final kind in _Kind.values)
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
          if (_kind == _Kind.types)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Same tree as Catalog. Variance is under a brand, not a chip.',
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _kind == _Kind.types
                ? CatalogTreeView(
                    nodes: _tree,
                    mode: CatalogTreeMode.editor,
                    onOpenPart: _openPart,
                    onAddChild: _addChild,
                    onRename: _rename,
                    onRemove: _removeNode,
                  )
                : _rows.isEmpty
                ? Center(child: Text('No ${_label(_kind).toLowerCase()} yet'))
                : ListView.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final row = _rows[index];
                      return ListTile(title: Text(row.name));
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'maintenance-fab',
        onPressed: _add,
        tooltip: _kind == _Kind.types ? 'Add category' : 'Add',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _NamedRow {
  _NamedRow(this.id, this.name);

  final String id;
  final String name;
}
