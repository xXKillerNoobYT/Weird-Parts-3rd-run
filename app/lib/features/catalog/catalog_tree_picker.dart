import 'package:flutter/material.dart';

import 'catalog_tree.dart';
import 'catalog_tree_view.dart';

class CatalogTreePick {
  const CatalogTreePick({required this.partId, this.brandVersionId});

  final String partId;
  final String? brandVersionId;
}

Future<CatalogTreePick?> pickFromCatalogTree(
  BuildContext context, {
  required List<CatalogTreeNode> tree,
  String? selectedPartId,
  String? selectedBrandVersionId,
}) {
  return showModalBottomSheet<CatalogTreePick>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return _PickerSheet(
        tree: tree,
        selectedPartId: selectedPartId,
        selectedBrandVersionId: selectedBrandVersionId,
      );
    },
  );
}

class _PickerSheet extends StatefulWidget {
  const _PickerSheet({
    required this.tree,
    this.selectedPartId,
    this.selectedBrandVersionId,
  });

  final List<CatalogTreeNode> tree;
  final String? selectedPartId;
  final String? selectedBrandVersionId;

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.85;
    final nodes = filterCatalogTree(widget.tree, _search.text);
    return SizedBox(
      height: height,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Text('Pick a part', style: Theme.of(context).textTheme.titleMedium),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search the tree',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Folders are not parts. Open down to a part number.'),
          ),
          Expanded(
            child: CatalogTreeView(
              nodes: nodes,
              mode: CatalogTreeMode.picker,
              expandAll: _search.text.trim().isNotEmpty,
              selectedPartId: widget.selectedPartId,
              selectedBrandVersionId: widget.selectedBrandVersionId,
              onPick: (node) {
                if (!node.isJobPickable || node.partId == null) return;
                Navigator.pop(
                  context,
                  CatalogTreePick(
                    partId: node.partId!,
                    brandVersionId: node.brandVersionId,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
