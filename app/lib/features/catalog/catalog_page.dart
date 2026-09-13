import 'package:flutter/material.dart';

import '../../app.dart';
import '../maintenance/maintenance_repository.dart';
import '../pin/pin_gate.dart';
import 'catalog_repository.dart';
import 'catalog_tree.dart';
import 'catalog_tree_view.dart';
import 'part_detail_page.dart';
import 'tree_edit_prompts.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  final _searchController = TextEditingController();
  late final CatalogRepository _catalog;
  late final MaintenanceRepository _maintenance;
  List<CatalogTreeNode> _tree = [];
  bool _loading = true;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _catalog = CatalogRepository(scope.db, scope.pin, scope.deviceId);
    _maintenance = MaintenanceRepository(scope.db, scope.pin, scope.deviceId);
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final snap = await _catalog.loadTreeSnapshot();
    if (!mounted) return;
    setState(() {
      _tree = buildCatalogTree(snap);
      _loading = false;
    });
  }

  List<CatalogTreeNode> get _visible {
    return filterCatalogTree(_tree, _searchController.text);
  }

  Future<bool> _gate() async {
    final scope = AppScope.of(context);
    return ensurePinUnlocked(context, scope.pin);
  }

  Future<void> _addPart({CatalogTreeNode? parent}) async {
    if (!await _gate() || !mounted) return;
    final name = await promptName(context, title: 'New part');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await _catalog.createGeneralPart(
        name: name,
        categoryId: parent?.categoryId,
        styleId: parent?.styleId,
        typeId: parent?.typeId,
      );
      await _reload();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PartDetailPage(partId: id),
        ),
      );
      await _reload();
    } on StateError catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _openNode(CatalogTreeNode node) async {
    final partId = node.partId;
    if (partId == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PartDetailPage(partId: partId),
      ),
    );
    await _reload();
  }

  Future<void> _addChild(CatalogTreeNode parent) async {
    if (!await _gate() || !mounted) return;
    try {
      switch (parent.kind) {
        case CatalogTreeKind.category:
          final name = await promptName(context, title: 'Add type');
          if (name == null || name.isEmpty) return;
          await _maintenance.createStyle(
            categoryId: parent.id,
            name: name,
          );
        case CatalogTreeKind.type:
          final name = await promptName(context, title: 'Add variant');
          if (name == null || name.isEmpty) return;
          await _maintenance.createType(styleId: parent.id, name: name);
        case CatalogTreeKind.variant:
          await _addPart(parent: parent);
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
      _toast(e.message);
    }
  }

  Future<void> _rename(CatalogTreeNode node) async {
    if (!await _gate() || !mounted) return;
    final name = await promptName(
      context,
      title: 'Rename',
      initial: node.label,
    );
    if (name == null || name.isEmpty) return;
    try {
      switch (node.kind) {
        case CatalogTreeKind.category:
          await _maintenance.renameCategory(node.id, name);
        case CatalogTreeKind.type:
          await _maintenance.renameStyle(node.id, name);
        case CatalogTreeKind.variant:
          await _maintenance.renameType(node.id, name);
        case CatalogTreeKind.part:
          final part = await _catalog.getPart(node.id);
          if (part == null) return;
          await _catalog.updatePart(
            partId: part.id,
            name: name,
            description: part.description,
            uom: part.uom,
            defaultSupplierId: part.defaultSupplierId,
            active: part.active,
            categoryId: part.categoryId,
            styleId: part.styleId,
            typeId: part.typeId,
          );
        case CatalogTreeKind.brand:
          if (node.brandId != null) {
            await _maintenance.renameBrand(node.brandId!, name);
          }
        default:
          return;
      }
      await _reload();
    } on StateError catch (e) {
      _toast(e.message);
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
      _toast(e.message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _visible;
    final searching = _searchController.text.trim().isNotEmpty;
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
                hintText: 'Search the tree',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : CatalogTreeView(
                    nodes: items,
                    mode: CatalogTreeMode.editor,
                    expandAll: searching,
                    onOpenPart: _openNode,
                    onAddChild: _addChild,
                    onRename: _rename,
                    onRemove: _removeNode,
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
