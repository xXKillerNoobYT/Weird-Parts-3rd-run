import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../pin/pin_gate.dart';
import 'catalog_repository.dart';

class PartDetailPage extends StatefulWidget {
  const PartDetailPage({
    required this.partId,
    this.focusBrandId,
    super.key,
  });

  final String partId;
  final String? focusBrandId;

  @override
  State<PartDetailPage> createState() => _PartDetailPageState();
}

class _BrandGroup {
  _BrandGroup({required this.brandId, required this.brandName});

  final String brandId;
  final String brandName;
  final List<_VarianceRow> variances = [];
}

class _VarianceRow {
  _VarianceRow({
    required this.version,
    required this.listings,
  });

  final BrandVersion version;
  final List<_ListingRow> listings;
}

class _ListingRow {
  _ListingRow({required this.listing, required this.supplierName});

  final SupplierListing listing;
  final String supplierName;
}

class _PartDetailPageState extends State<PartDetailPage> {
  late final CatalogRepository _catalog;
  late final AppDatabase _db;

  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _uomController = TextEditingController();

  List<Supplier> _suppliers = [];
  List<Brand> _brands = [];
  List<Category> _categories = [];
  List<Style> _styles = [];
  List<Type> _variants = [];
  List<_BrandGroup> _brandGroups = [];

  String? _defaultSupplierId;
  String? _categoryId;
  String? _styleId;
  String? _typeId;
  bool _active = true;
  bool _loading = true;
  bool _saving = false;
  bool _initialized = false;
  bool _openedFocus = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _db = scope.db;
    _catalog = CatalogRepository(scope.db, scope.pin, scope.deviceId);
    _reload();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _uomController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final part = await _catalog.getPart(widget.partId);
    if (part == null) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }

    final suppliers = await _db.taxonomyDao.listSuppliers();
    final brands = await _db.taxonomyDao.listBrands();
    final categories = await _db.taxonomyDao.listCategories();
    final styles = await _db.taxonomyDao.listStyles();
    final variants = await _db.taxonomyDao.listTypes();
    final brandNames = {for (final b in brands) b.id: b.name};
    final supplierNames = {for (final s in suppliers) s.id: s.name};
    final versions = await _catalog.listBrandVersionsForPart(widget.partId);

    final groups = <String, _BrandGroup>{};
    for (final v in versions) {
      final group = groups.putIfAbsent(
        v.brandId,
        () => _BrandGroup(
          brandId: v.brandId,
          brandName: brandNames[v.brandId] ?? 'Unknown brand',
        ),
      );
      final listings = await _catalog.listingsForBrandVersion(v.id);
      group.variances.add(
        _VarianceRow(
          version: v,
          listings: [
            for (final l in listings)
              _ListingRow(
                listing: l,
                supplierName: supplierNames[l.supplierId] ?? 'Unknown',
              ),
          ],
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _nameController.text = part.name;
      _descriptionController.text = part.description;
      _uomController.text = part.uom;
      _defaultSupplierId = part.defaultSupplierId;
      _categoryId = part.categoryId;
      _styleId = part.styleId;
      _typeId = part.typeId;
      _active = part.active;
      _suppliers = suppliers;
      _brands = brands;
      _categories = categories;
      _styles = styles;
      _variants = variants;
      _brandGroups = groups.values.toList()
        ..sort((a, b) => a.brandName.compareTo(b.brandName));
      _loading = false;
    });

    if (!_openedFocus && widget.focusBrandId != null) {
      _openedFocus = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _addVariance(brandId: widget.focusBrandId);
      });
    }
  }

  List<Style> get _stylesForCategory {
    if (_categoryId == null) return const [];
    return _styles.where((s) => s.categoryId == _categoryId).toList();
  }

  List<Type> get _variantsForType {
    if (_styleId == null) return const [];
    return _variants.where((t) => t.styleId == _styleId).toList();
  }

  Future<bool> _gate() async {
    final scope = AppScope.of(context);
    return ensurePinUnlocked(context, scope.pin);
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required')),
      );
      return;
    }
    if (!await _gate() || !mounted) return;

    setState(() => _saving = true);
    try {
      await _catalog.updatePart(
        partId: widget.partId,
        name: name,
        description: _descriptionController.text.trim(),
        uom: _uomController.text.trim().isEmpty
            ? 'ea'
            : _uomController.text.trim(),
        defaultSupplierId: _defaultSupplierId,
        active: _active,
        categoryId: _categoryId,
        styleId: _styleId,
        typeId: _typeId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addVariance({String? brandId}) async {
    if (_brands.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a brand in Maintenance first')),
      );
      return;
    }
    if (!await _gate() || !mounted) return;

    String? selectedBrand = brandId ??
        (_brands.any((b) => b.id == brandId) ? brandId : _brands.first.id);
    selectedBrand ??= _brands.first.id;
    final nameController = TextEditingController();
    final mpnController = TextEditingController();
    final existingForBrand = _brandGroups
        .where((g) => g.brandId == selectedBrand)
        .expand((g) => g.variances);
    var isMain = existingForBrand.isEmpty;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Add variance'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value: selectedBrand,
                      decoration: const InputDecoration(labelText: 'Brand'),
                      items: [
                        for (final b in _brands)
                          DropdownMenuItem(value: b.id, child: Text(b.name)),
                      ],
                      onChanged: (v) {
                        setLocal(() {
                          selectedBrand = v;
                          final has = _brandGroups
                              .where((g) => g.brandId == v)
                              .expand((g) => g.variances)
                              .isNotEmpty;
                          isMain = !has;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Variance (color / option)',
                        hintText: 'White',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: mpnController,
                      decoration: const InputDecoration(labelText: 'Part number'),
                      autofocus: true,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Main'),
                      subtitle: const Text('First pick; others are extra options'),
                      value: isMain,
                      onChanged: (v) => setLocal(() => isMain = v),
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
                    if (selectedBrand == null ||
                        mpnController.text.trim().isEmpty) {
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
    final mpn = mpnController.text.trim();
    final varianceName = nameController.text.trim();
    nameController.dispose();
    mpnController.dispose();
    if (ok != true || selectedBrand == null || mpn.isEmpty) return;

    try {
      await _catalog.createBrandVersion(
        partId: widget.partId,
        brandId: selectedBrand!,
        mpn: mpn,
        varianceName: varianceName,
        isMain: isMain,
      );
      await _reload();
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  Future<void> _addListing(BrandVersion version) async {
    if (_suppliers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a supplier in Maintenance first')),
      );
      return;
    }
    if (!await _gate() || !mounted) return;

    String? supplierId = _defaultSupplierId ?? _suppliers.first.id;
    final skuController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Add supplier listing'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: supplierId,
                    decoration: const InputDecoration(labelText: 'Supplier'),
                    items: [
                      for (final s in _suppliers)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (v) => setLocal(() => supplierId = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: skuController,
                    decoration: const InputDecoration(labelText: 'SKU'),
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
                    if (supplierId == null ||
                        skuController.text.trim().isEmpty) {
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
    final sku = skuController.text.trim();
    skuController.dispose();
    if (ok != true || supplierId == null || sku.isEmpty) return;

    try {
      await _catalog.createSupplierListing(
        brandVersionId: version.id,
        supplierId: supplierId!,
        sku: sku,
      );
      await _reload();
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Part'),
        actions: [
          if (!_loading)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
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
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _uomController,
                  decoration: const InputDecoration(
                    labelText: 'Unit of measure',
                    border: OutlineInputBorder(),
                    hintText: 'ea',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Tree location',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  // ignore: deprecated_member_use
                  value: _categoryId,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final c in _categories)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _categoryId = v;
                    if (_stylesForCategory.every((s) => s.id != _styleId)) {
                      _styleId = null;
                      _typeId = null;
                    }
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  // ignore: deprecated_member_use
                  value: _styleId,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final s in _stylesForCategory)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _styleId = v;
                    if (_variantsForType.every((t) => t.id != _typeId)) {
                      _typeId = null;
                    }
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  // ignore: deprecated_member_use
                  value: _typeId,
                  decoration: const InputDecoration(
                    labelText: 'Variant',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final t in _variantsForType)
                      DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) => setState(() => _typeId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  // ignore: deprecated_member_use
                  value: _defaultSupplierId,
                  decoration: const InputDecoration(
                    labelText: 'Default supplier',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final s in _suppliers)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _defaultSupplierId = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'Brands',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _addVariance,
                      icon: const Icon(Icons.add),
                      label: const Text('Add variance'),
                    ),
                  ],
                ),
                const Text(
                  'Variance lives under a brand. Each color / option has its own part number.',
                ),
                const SizedBox(height: 8),
                if (_brandGroups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No brand — this is a general part'),
                  )
                else
                  for (final group in _brandGroups)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ExpansionTile(
                        initiallyExpanded: true,
                        title: Text(group.brandName),
                        subtitle: const Text('Variance'),
                        children: [
                          for (final row in group.variances) ...[
                            ListTile(
                              dense: true,
                              title: Text(
                                row.version.varianceName.trim().isEmpty
                                    ? row.version.mpn
                                    : '${row.version.varianceName} · ${row.version.mpn}',
                              ),
                              subtitle: Text(
                                row.version.isMain ? 'Main' : 'Option',
                              ),
                            ),
                            for (final listing in row.listings)
                              ListTile(
                                dense: true,
                                contentPadding:
                                    const EdgeInsets.only(left: 32, right: 16),
                                title: Text(listing.supplierName),
                                subtitle: Text('SKU ${listing.listing.sku}'),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => _addListing(row.version),
                                icon: const Icon(Icons.add),
                                label: const Text('Add listing'),
                              ),
                            ),
                          ],
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () =>
                                  _addVariance(brandId: group.brandId),
                              icon: const Icon(Icons.add),
                              label: const Text('Add variance'),
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }
}
