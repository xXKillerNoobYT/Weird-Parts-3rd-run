import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/catalog_tree.dart';
import '../catalog/catalog_tree_picker.dart';
import '../catalog/part_detail_page.dart';
import '../catalog/tree_edit_prompts.dart';
import '../maintenance/maintenance_repository.dart';
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
  late final MaintenanceRepository _maintenance;
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
  String? _lineId;

  bool get _isEditing => _lineId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _db = scope.db;
    _jobs = JobsRepository(scope.db, scope.deviceId);
    _catalog = CatalogRepository(scope.db, scope.pin, scope.deviceId);
    _maintenance = MaintenanceRepository(scope.db, scope.pin, scope.deviceId);
    _lineId = widget.lineId;
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

  Future<void> _addSupplierForSplit(_SplitDraft split) async {
    final scope = AppScope.of(context);
    if (!await ensurePinUnlocked(context, scope.pin) || !mounted) return;
    final name = await promptName(context, title: 'Add supplier');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await _maintenance.createSupplier(name);
      final suppliers = await _db.taxonomyDao.listSuppliers();
      if (!mounted) return;
      Supplier? created;
      for (final s in suppliers) {
        if (s.id == id) {
          created = s;
          break;
        }
      }
      if (created == null) return;
      final added = created;
      setState(() {
        _allSuppliers = suppliers;
        if (!_supplierChoices.any((s) => s.id == id)) {
          _supplierChoices = [..._supplierChoices, added];
        }
        split.supplierId = id;
      });
    } on StateError catch (e) {
      if (mounted) _toast(e.message);
    }
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
      await _jobs.removeLine(_lineId!);
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
        lineId = _lineId!;
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
    if (_saving || _loading) return;
    final name = _customNameController.text.trim();
    if (name.isEmpty) {
      _toast('Custom name is required');
      return;
    }

    final scope = AppScope.of(context);
    if (!await ensurePinUnlocked(context, scope.pin) || !mounted) return;

    final result = await showDialog<_PromoteResult>(
      context: context,
      builder: (ctx) => _PromoteDialog(
        initialName: name,
        maintenance: _maintenance,
      ),
    );
    if (result == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final partId = await _catalog.createGeneralPart(
        name: result.name,
        categoryId: result.categoryId,
        styleId: result.styleId,
        typeId: result.typeId,
      );
      final needed = double.tryParse(_neededController.text.trim()) ?? 1.0;
      final pull = double.tryParse(_pullController.text.trim()) ?? 0.0;
      final neededQty = needed < 0 ? 1.0 : needed;
      final shopPullQty = pull < 0 ? 0.0 : pull;
      final splits = _previewSplits();
      if (_lineId != null) {
        await _jobs.attachCatalogPart(
          lineId: _lineId!,
          partId: partId,
          neededQty: neededQty,
          shopPullQty: shopPullQty,
          splits: splits,
        );
      } else {
        _lineId = await _jobs.addLine(
          jobId: widget.jobId,
          partId: partId,
          neededQty: neededQty,
          shopPullQty: shopPullQty,
        );
        await _jobs.replaceOrderSplits(_lineId!, splits);
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
      await _refreshSupplierChoices();
      if (!mounted) return;
      _toast('On this job as a catalog part. Back out when you are done.');
    } on StateError catch (e) {
      if (mounted) _toast(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<({String supplierId, double qty})> _previewSplits() {
    final splits = <({String supplierId, double qty})>[];
    for (final draft in _splits) {
      final qty = double.tryParse(draft.qtyController.text.trim());
      if (draft.supplierId == null || qty == null || qty <= 0) continue;
      splits.add((supplierId: draft.supplierId!, qty: qty));
    }
    return splits;
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
                  onSelectionChanged: _saving
                      ? null
                      : (sel) async {
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
                  const Text(
                    'PIN required. Puts this name on the catalog tree and on this job.',
                  ),
                ] else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Catalog part'),
                    subtitle: Text(_pickLabel),
                    trailing: const Icon(Icons.account_tree_outlined),
                    onTap: _saving ? null : _pickFromTree,
                  ),
                  if (_partId != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: _saving
                            ? null
                            : () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        PartDetailPage(partId: _partId!),
                                  ),
                                );
                              },
                        child: const Text('Open catalog part'),
                      ),
                    ),
                ],
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
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Split — suppliers',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    TextButton.icon(
                      onPressed: _addSplit,
                      icon: const Icon(Icons.add),
                      label: const Text('Add split'),
                    ),
                  ],
                ),
                const Text(
                  'Shop is the shop slice. Each row is one supplier. Add a supplier on this row if it is not in the list. Empty is OK.',
                ),
                const SizedBox(height: 8),
                ...List.generate(_splits.length, (index) {
                  final split = _splits[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      children: [
                        TaxonomyPickField(
                          label: 'Supplier',
                          value: split.supplierId,
                          allowNone: true,
                          addLabel: 'Add supplier',
                          items: [
                            for (final s in _supplierChoices)
                              DropdownMenuItem(
                                value: s.id,
                                child: Text(s.name),
                              ),
                          ],
                          onChanged: (v) {
                            setState(() => split.supplierId = v);
                          },
                          onAdd: _saving
                              ? null
                              : () => _addSupplierForSplit(split),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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

class _PromoteResult {
  const _PromoteResult({
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

class _PromoteDialog extends StatefulWidget {
  const _PromoteDialog({
    required this.initialName,
    required this.maintenance,
  });

  final String initialName;
  final MaintenanceRepository maintenance;

  @override
  State<_PromoteDialog> createState() => _PromoteDialogState();
}

class _PromoteDialogState extends State<_PromoteDialog> {
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
      _PromoteResult(
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
      title: const Text('Promote to catalog'),
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
                    const Text(
                      'Turns this custom name into a catalog part and hangs it on the tree. Category is a folder, not a part.',
                    ),
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
          child: const Text('Promote'),
        ),
      ],
    );
  }
}
