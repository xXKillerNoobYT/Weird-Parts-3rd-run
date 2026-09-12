import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../catalog/catalog_repository.dart';
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

  String? _partId;
  String? _brandVersionId;
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

  Future<void> _bootstrap() async {
    final parts = await _catalog.listParts();
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

    if (!mounted) return;
    setState(() {
      _parts = parts;
      _brands = brands;
      _allSuppliers = suppliers;
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
    await _refreshSupplierChoices();
  }

  Future<void> _onPartChanged(String? partId) async {
    setState(() {
      _partId = partId;
      _brandVersionId = null;
      _useCustom = false;
      _brandVersions = [];
    });
    if (partId == null) {
      await _refreshSupplierChoices();
      return;
    }
    final versions = await _catalog.listBrandVersionsForPart(partId);
    if (!mounted) return;
    setState(() => _brandVersions = versions);
    await _refreshSupplierChoices();
  }

  Future<void> _onBrandVersionChanged(String? bvId) async {
    setState(() => _brandVersionId = bvId);
    await _refreshSupplierChoices();
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
      _toast('Enter a valid needed quantity');
      return;
    }
    if (pull == null || pull < 0) {
      _toast('Enter a valid shop pull quantity');
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
                if (_useCustom)
                  TextField(
                    controller: _customNameController,
                    decoration: const InputDecoration(
                      labelText: 'Custom name',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  )
                else ...[
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: _partId,
                    decoration: const InputDecoration(
                      labelText: 'Part',
                      border: OutlineInputBorder(),
                    ),
                    items: _parts
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: _onPartChanged,
                  ),
                  if (_brandVersions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      // ignore: deprecated_member_use
                      value: _brandVersionId,
                      decoration: const InputDecoration(
                        labelText: 'Brand version (optional)',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None'),
                        ),
                        ..._brandVersions.map(
                          (bv) => DropdownMenuItem<String?>(
                            value: bv.id,
                            child: Text(_brandVersionLabel(bv)),
                          ),
                        ),
                      ],
                      onChanged: _onBrandVersionChanged,
                    ),
                  ],
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _neededController,
                        decoration: const InputDecoration(
                          labelText: 'Needed qty',
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
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _pullController,
                        decoration: const InputDecoration(
                          labelText: 'Shop pull qty',
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
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Text(
                      'Order splits',
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
              ],
            ),
    );
  }

  static String _qtyText(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }
}
