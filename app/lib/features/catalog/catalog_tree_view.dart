import 'package:flutter/material.dart';

import 'catalog_tree.dart';

enum CatalogTreeMode { browse, editor, picker }

class CatalogTreeView extends StatelessWidget {
  const CatalogTreeView({
    required this.nodes,
    required this.mode,
    this.onOpenPart,
    this.onPick,
    this.onAddChild,
    this.onRename,
    this.selectedPartId,
    this.selectedBrandVersionId,
    this.expandAll = false,
    super.key,
  });

  final List<CatalogTreeNode> nodes;
  final CatalogTreeMode mode;
  final void Function(CatalogTreeNode node)? onOpenPart;
  final void Function(CatalogTreeNode node)? onPick;
  final void Function(CatalogTreeNode parent)? onAddChild;
  final void Function(CatalogTreeNode node)? onRename;
  final String? selectedPartId;
  final String? selectedBrandVersionId;
  final bool expandAll;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return const Center(child: Text('No folders or parts yet'));
    }
    return ListView(
      children: [
        for (final node in nodes) _Tile(node: node, view: this, depth: 0),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.node, required this.view, required this.depth});

  final CatalogTreeNode node;
  final CatalogTreeView view;
  final int depth;

  bool get _selected {
    if (node.kind == CatalogTreeKind.variance) {
      return view.selectedBrandVersionId != null &&
          node.brandVersionId == view.selectedBrandVersionId;
    }
    if (node.kind == CatalogTreeKind.part) {
      return view.selectedPartId == node.partId &&
          view.selectedBrandVersionId == null;
    }
    return false;
  }

  void _activate() {
    if (view.mode == CatalogTreeMode.picker) {
      if (node.isJobPickable) view.onPick?.call(node);
      return;
    }
    if (node.kind == CatalogTreeKind.part ||
        node.kind == CatalogTreeKind.variance) {
      view.onOpenPart?.call(node);
    }
  }

  bool get _useExpansion {
    if (node.kind == CatalogTreeKind.variance) return false;
    if (node.children.isNotEmpty) return true;
    return node.kind == CatalogTreeKind.category ||
        node.kind == CatalogTreeKind.type ||
        node.kind == CatalogTreeKind.variant ||
        node.kind == CatalogTreeKind.brand ||
        node.kind == CatalogTreeKind.unassigned;
  }

  @override
  Widget build(BuildContext context) {
    final pad = EdgeInsets.only(left: 8.0 + depth * 8);
    final icon = _iconFor(node.kind);
    final trailing = _trailing(context);

    if (_useExpansion) {
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: view.expandAll
              ? ValueKey<String>('search-${node.id}')
              : PageStorageKey<String>(node.id),
          initiallyExpanded: view.expandAll,
          tilePadding: pad,
          leading: Icon(icon),
          title: Text(node.label),
          subtitle: node.subtitle == null ? null : Text(node.subtitle!),
          trailing: trailing,
          onExpansionChanged: (_) {},
          children: [
            if (node.kind == CatalogTreeKind.part)
              ListTile(
                contentPadding: EdgeInsets.only(left: 24.0 + depth * 8),
                leading: Icon(
                  view.mode == CatalogTreeMode.picker
                      ? (_selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off)
                      : Icons.inventory_2_outlined,
                ),
                title: const Text('General (no brand)'),
                selected: _selected,
                onTap: _activate,
              ),
            for (final child in node.children)
              _Tile(node: child, view: view, depth: depth + 1),
          ],
        ),
      );
    }

    return ListTile(
      contentPadding: pad,
      leading: Icon(icon),
      title: Text(node.label),
      subtitle: node.subtitle == null ? null : Text(node.subtitle!),
      selected: _selected,
      enabled: view.mode != CatalogTreeMode.picker || node.isJobPickable,
      trailing: trailing,
      onTap: _activate,
    );
  }

  Widget? _trailing(BuildContext context) {
    if (view.mode == CatalogTreeMode.picker) {
      if (!node.isJobPickable) return null;
      return Icon(
        _selected ? Icons.radio_button_checked : Icons.radio_button_off,
      );
    }
    if (view.mode != CatalogTreeMode.editor &&
        view.onAddChild == null &&
        view.onRename == null) {
      return null;
    }
    final items = <PopupMenuEntry<String>>[
      if (view.onRename != null &&
          node.kind != CatalogTreeKind.unassigned &&
          node.kind != CatalogTreeKind.variance)
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
      if (view.onAddChild != null && _canAdd(node.kind))
        PopupMenuItem(value: 'add', child: Text(_addLabel(node.kind))),
    ];
    if (items.isEmpty) return null;
    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'rename') view.onRename?.call(node);
        if (value == 'add') view.onAddChild?.call(node);
      },
      itemBuilder: (_) => items,
    );
  }
}

IconData _iconFor(CatalogTreeKind kind) {
  switch (kind) {
    case CatalogTreeKind.category:
      return Icons.folder_outlined;
    case CatalogTreeKind.type:
      return Icons.account_tree_outlined;
    case CatalogTreeKind.variant:
      return Icons.tune;
    case CatalogTreeKind.part:
      return Icons.inventory_2_outlined;
    case CatalogTreeKind.brand:
      return Icons.sell_outlined;
    case CatalogTreeKind.variance:
      return Icons.palette_outlined;
    case CatalogTreeKind.unassigned:
      return Icons.inbox_outlined;
  }
}

bool _canAdd(CatalogTreeKind kind) {
  return kind == CatalogTreeKind.category ||
      kind == CatalogTreeKind.type ||
      kind == CatalogTreeKind.variant ||
      kind == CatalogTreeKind.part ||
      kind == CatalogTreeKind.brand;
}

String _addLabel(CatalogTreeKind kind) {
  switch (kind) {
    case CatalogTreeKind.category:
      return 'Add type';
    case CatalogTreeKind.type:
      return 'Add variant';
    case CatalogTreeKind.variant:
      return 'Add part';
    case CatalogTreeKind.part:
      return 'Add brand / variance';
    case CatalogTreeKind.brand:
      return 'Add variance';
    default:
      return 'Add';
  }
}
