import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/catalog_tree.dart';
import '../catalog/catalog_tree_picker.dart';
import '../catalog/part_detail_page.dart';
import '../pin/pin_gate.dart';
import 'job_line_qty.dart';
import 'jobs_repository.dart';

class JobLineEditor extends StatefulWidget {
  const JobLineEditor({
    required this.jobId,
    this.lineId,
    super.key,
  });

  final String jobId;
  final String? lineId;

  @override
  State<JobLineEditor> createState() => _JobLineEditorState();
}

class _SplitDraft {
  _SplitDraft({this.supplierId, String qty = ''})
      : qtyController = TextEditingController(text: qty);

  String? supplierId;
  final TextEditingController qtyController;

  void dispose() => qtyController.dispose();
}

class _JobLineEditorState extends State<JobLineEditor> {
  late final JobsRepository _jobs;
  late final CatalogRepository _catalog;
  late final AppDatabase _db;

  final _customNameController = TextEditingController();
  final _neededController = TextEditingController(text: '1');
  final _pullController = TextEditingController(text: '0');

  List<Part> _parts = [];
  List<BrandVersion> _brandVersions = [];
  List<Brand> _brands = [];
  List<Supplier> _allSuppliers = [];
  List<Supplier> _supplierChoices = [];
  List<CatalogTreeNode> _tree = [];

  String? _partId;
  String? _brandVersionId;
  String _pickLabel = 'Pick from catalog tree';
  final List<_SplitDraft> _splits = [];

  bool _useCustom = false;
  bool _loading = true;
  bool _saving = false;
  bool _initialized = false;

  bool get _isEditing => widget.lineId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _db = scope.db;
    _jobs = JobsRepository(scope.db, scope.deviceId);
    _catalog = CatalogRepository(scope.db, scope.pin, scope.deviceId);
    _bootstrap();
  }

  @override
  void dispose() {
    _customNameController.dispose();
    _neededController.dispose();
    _pullController.dispose();
    for (final s in _splits) {
      s.dispose();
    }
    super.dispose();
  }

  JobLineQty get _previewQty {
    final requested = double.tryParse(_neededController.text.trim()) ?? 0;
    final shop = double.tryParse(_pullController.text.trim()) ?? 0;
    final supplierSplits = <JobSupplierSplit>[];
    for (final draft in _splits) {
      final qty = double.tryParse(draft.qtyController.text.trim());
      if (draft.supplierId == null || qty == null || qty <= 0) continue;
      String name = 'Supply';
      for (final s in _allSuppliers) {
        if (s.id == draft.supplierId) {
          name = s.name;
          break;
        }
      }
      supplierSplits.add(JobSupplierSplit(supplierName: name, qty: qty));
    }
    return JobLineQty(
      requested: requested,
      shop: shop,
      supplierSplits: supplierSplits,
    );
  }

  Future<void> _bootstrap() async {
    final parts = await _catalog.listParts(activeOnly: false);
    final brands = await _db.taxonomyDao.listBrands();
    final suppliers = await _db.taxonomyDao.listSuppliers();

    String? partId;
    String? brandVersionId;
    var useCustom = false;
    var needed = '1';
    var pull = '0';
    var customName = '';
    final splitDrafts = <_SplitDraft>[];

    if (widget.lineId != null) {
      final line = await _jobs.getJobLine(widget.lineId!);
      if (line != null) {
        partId = line.partId;
        brandVersionId = line.brandVersionId;
        useCustom = line.partId == null;
        customName = line.customName ?? '';
        needed = _qtyText(line.neededQty);
        pull = _qtyText(line.shopPullQty);
        final existing = await _jobs.orderSplitsForLine(line.id);
        for (final s in existing) {
          splitDrafts.add(
            _SplitDraft(supplierId: s.supplierId, qty: _qtyText(s.quantity)),
          );
        }
      }
    }

    if (splitDrafts.isEmpty) {
      splitDrafts.add(_SplitDraft());
    }

    List<BrandVersion> versions = [];
    if (partId != null) {
      versions = await _catalog.listBrandVersionsForPart(partId);
    }

    final tree = buildCatalogTree(
      await _catalog.loadTreeSnapshot(activeOnly: true),
    );

    if (!mounted) return;
    setState(() {
      _parts = parts;
      _brands = brands;
      _allSuppliers = suppliers;
      _tree = tree;
      _partId = partId;
      _brandVersionId = brandVersionId;
      _useCustom = useCustom;
      _customNameController.text = customName;
      _neededController.text = needed;
      _pullController.text = pull;
      _brandVersions = versions;
      _splits
        ..clear()
        ..addAll(splitDrafts);
      _loading = false;
    });
    _refreshPickLabel();
    await _refreshSupplierChoices();
  }

  void _refreshPickLabel() {
    if (_partId == null) {
      _pickLabel = 'Pick from catalog tree';
      return;
    }
    String name = 'Part';
    for (final p in _parts) {
      if (p.id == _partId) {
        name = p.name;
        break;
      }
    }
    if (_brandVersionId == null) {
      _pickLabel = name;
      return;
    }
    BrandVersion? version;
    for (final v in _brandVersions) {
      if (v.id == _brandVersionId) {
        version = v;
        break;
      }
    }
    if (version == null) {
      _pickLabel = name;
      return;
    }
    _pickLabel = '$name · ${_brandVersionLabel(version)}';
  }

  Future<void> _applyPick(CatalogTreePick pick) async {
    final versions = await _catalog.listBrandVersionsForPart(pick.partId);
    if (!mounted) return;
    setState(() {
      _useCustom = false;
      _partId = pick.partId;
      _brandVersionId = pick.brandVersionId;
      _brandVersions = versions;
    });
    _refreshPickLabel();
    await _refreshSupplierChoices();
  }

  Future<void> _pickFromTree() async {
    final pick = await pickFromCatalogTree(
      context,
      tree: _tree,
      selectedPartId: _partId,
      selectedBrandVersionId: _brandVersionId,
    );
    if (pick == null || !mounted) return;
    await _applyPick(pick);
  }

  Future<void> _refreshSupplierChoices() async {
    List<Supplier> choices;
    if (_brandVersionId != null) {
      // Brand version selected: only suppliers with listings on that version
      // (may be empty — do not fall back to all suppliers).
      final listings =
          await _catalog.listingsForBrandVersion(_brandVersionId!);
      final ids = listings.map((l) => l.supplierId).toSet();
      choices = _allSuppliers.where((s) => ids.contains(s.id)).toList();
    } else if (_partId != null) {
      final part = await _catalog.getPart(_partId!);
      final preferred = part?.defaultSupplierId;
      choices = List.of(_allSuppliers);
      if (preferred != null) {
        choices.sort((a, b) {
          if (a.id == preferred) return -1;
          if (b.id == preferred) return 1;
          return a.name.compareTo(b.name);
        });
      }
    } else {
      choices = List.of(_allSuppliers);
    }

    if (!mounted) return;
    setState(() {
      _supplierChoices = choices;
      final allowed = choices.map((s) => s.id).toSet();
      for (final split in _splits) {
        if (split.supplierId != null && !allowed.contains(split.supplierId)) {
          split.supplierId = null;
        }
      }
    });
  }

  void _addSplit() {
    setState(() => _splits.add(_SplitDraft()));
  }

  void _removeSplit(int index) {
    if (_splits.length <= 1) return;
    setState(() {
      _splits.removeAt(index).dispose();
    });
  }

  Future<void> _removeLine() async {
    if (!_isEditing || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove line?'),
        content: const Text('This removes the line from the job.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _jobs.removeLine(widget.lineId!);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      _toast('Remove failed: $e');
      setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final needed = double.tryParse(_neededController.text.trim());
    final pull = double.tryParse(_pullController.text.trim());
    if (needed == null || needed < 0) {
      _toast('Enter a valid requested quantity');
      return;
    }
    if (pull == null || pull < 0) {
      _toast('Enter a valid shop quantity');
      return;
    }

    String? partId;
    String? brandVersionId;
    String? customName;

    if (_useCustom) {
      customName = _customNameController.text.trim();
      if (customName.isEmpty) {
        _toast('Custom name is required');
        return;
      }
    } else {
      partId = _partId;
      if (partId == null) {
        _toast('Pick a catalog part or enter a custom name');
        return;
      }
      brandVersionId = _brandVersionId;
    }

    final splits = <({String supplierId, double qty})>[];
    for (final draft in _splits) {
      final qtyText = draft.qtyController.text.trim();
      if (draft.supplierId == null && qtyText.isEmpty) continue;
      if (draft.supplierId == null) {
        _toast('Each order split needs a supplier');
        return;
      }
      final qty = double.tryParse(qtyText);
      if (qty == null || qty <= 0) {
        _toast('Each order split needs a quantity > 0');
        return;
      }
      splits.add((supplierId: draft.supplierId!, qty: qty));
    }

    setState(() => _saving = true);
    try {
      late final String lineId;
      if (_isEditing) {
        lineId = widget.lineId!;
        await _jobs.updateLine(
          lineId: lineId,
          partId: partId,
          brandVersionId: brandVersionId,
          customName: customName,
          neededQty: needed,
          shopPullQty: pull,
        );
      } else {
        lineId = await _jobs.addLine(
          jobId: widget.jobId,
          partId: partId,
          brandVersionId: brandVersionId,
          customName: customName,
          neededQty: needed,
          shopPullQty: pull,
        );
      }
      await _jobs.replaceOrderSplits(lineId, splits);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      _toast('Save failed: $e');
      setState(() => _saving = false);
    }
  }

  Future<void> _promoteToCatalog() async {
    final name = _customNameController.text.trim();
    if (name.isEmpty) {
      _toast('Custom name is required');
      return;
    }
    final scope = AppScope.of(context);
    if (!await ensurePinUnlocked(context, scope.pin) || !mounted) return;

    final categories = await _db.taxonomyDao.listCategories();
    final styles = await _db.taxonomyDao.listStyles();
    final variants = await _db.taxonomyDao.listTypes();
    if (!mounted) return;

    String? categoryId;
    String? styleId;
    String? typeId;
    final nameController = TextEditingController(text: name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final typesForCat = styles
                .where((s) => categoryId != null && s.categoryId == categoryId)
                .toList();
            final variantsForType = variants
                .where((t) => styleId != null && t.styleId == styleId)
                .toList();
            return AlertDialog(
              title: const Text('Promote to catalog'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Part name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      // ignore: deprecated_member_use
                      value: categoryId,
                      decoration: const InputDecoration(
                        labelText: 'Category (folder)',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Unassigned'),
                        ),
                        for (final c in categories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => setLocal(() {
                        categoryId = v;
                        styleId = null;
                        typeId = null;
                      }),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      // ignore: deprecated_member_use
                      value: styleId,
                      decoration: const InputDecoration(
                        labelText: 'Type',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None'),
                        ),
                        for (final s in typesForCat)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: (v) => setLocal(() {
                        styleId = v;
                        typeId = null;
                      }),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      // ignore: deprecated_member_use
                      value: typeId,
                      decoration: const InputDecoration(
                        labelText: 'Variant',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None'),
                        ),
                        for (final t in variantsForType)
                          DropdownMenuItem(value: t.id, child: Text(t.name)),
                      ],
                      onChanged: (v) => setLocal(() => typeId = v),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (nameController.text.trim().isEmpty) return;
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('Promote'),
                ),
              ],
            );
          },
        );
      },
    );
    final partName = nameController.text.trim();
    nameController.dispose();
    if (ok != true || partName.isEmpty || !mounted) return;

    try {
      final partId = await _catalog.createGeneralPart(
        name: partName,
        categoryId: categoryId,
        styleId: styleId,
        typeId: typeId,
      );
      if (_isEditing) {
        await _jobs.attachCatalogPart(lineId: widget.lineId!, partId: partId);
      }
      final versions = await _catalog.listBrandVersionsForPart(partId);
      final parts = await _catalog.listParts(activeOnly: false);
      final tree = buildCatalogTree(
        await _catalog.loadTreeSnapshot(activeOnly: true),
      );
      if (!mounted) return;
      setState(() {
        _useCustom = false;
        _partId = partId;
        _brandVersionId = null;
        _brandVersions = versions;
        _parts = parts;
        _tree = tree;
        _customNameController.clear();
      });
      _refreshPickLabel();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PartDetailPage(partId: partId),
        ),
      );
    } on StateError catch (e) {
      _toast(e.message);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _brandVersionLabel(BrandVersion bv) {
    Brand? brand;
    for (final b in _brands) {
      if (b.id == bv.brandId) {
        brand = b;
        break;
      }
    }
    final brandName = brand?.name ?? 'Brand';
    return '$brandName · ${bv.mpn}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit line' : 'Add line'),
        actions: [
          if (_isEditing)
            TextButton(
              onPressed: _saving || _loading ? null : _removeLine,
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: _saving || _loading ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Catalog part')),
                    ButtonSegment(value: true, label: Text('Custom')),
                  ],
                  selected: {_useCustom},
                  onSelectionChanged: (sel) async {
                    final custom = sel.first;
                    setState(() {
                      _useCustom = custom;
                      if (custom) {
                        _partId = null;
                        _brandVersionId = null;
                        _brandVersions = [];
                      } else {
                        _customNameController.clear();
                      }
                    });
                    await _refreshSupplierChoices();
                  },
                ),
                const SizedBox(height: 16),
                if (_useCustom) ...[
                  TextField(
                    controller: _customNameController,
                    decoration: const InputDecoration(
                      labelText: 'Custom name',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _saving || _loading ? null : _promoteToCatalog,
                      icon: const Icon(Icons.upgrade),
                      label: const Text('Promote to catalog'),
                    ),
                  ),
                ] else
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Catalog part'),
                    subtitle: Text(_pickLabel),
                    trailing: const Icon(Icons.account_tree_outlined),
                    onTap: _pickFromTree,
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _neededController,
                        decoration: const InputDecoration(
                          labelText: 'Requested',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]'),
                          ),
                        ],
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _pullController,
                        decoration: const InputDecoration(
                          labelText: 'Shop',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]'),
                          ),
                        ],
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Left to Pull/Order ${formatQty(_previewQty.leftToPullOrder)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Split: ${_previewQty.splitSummary}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Text(
                      'Split — suppliers',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _addSplit,
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                    ),
                  ],
                ),
                const Text(
                  'Shop is the shop slice. Each row is one supplier (Supply A, Supply B, …).',
                ),
                const SizedBox(height: 8),
                ...List.generate(_splits.length, (index) {
                  final split = _splits[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            // ignore: deprecated_member_use
                            value: split.supplierId,
                            decoration: const InputDecoration(
                              labelText: 'Supplier',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: _supplierChoices
                                .map(
                                  (s) => DropdownMenuItem(
                                    value: s.id,
                                    child: Text(s.name),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              setState(() => split.supplierId = v);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: split.qtyController,
                            decoration: const InputDecoration(
                              labelText: 'Qty',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        IconButton(
                          onPressed: _splits.length <= 1
                              ? null
                              : () => _removeSplit(index),
                          icon: const Icon(Icons.remove_circle_outline),
                          tooltip: 'Remove split',
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 16),
                Text(
                  'Delivered and Brought to the Job — later.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }

  static String _qtyText(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }
}
