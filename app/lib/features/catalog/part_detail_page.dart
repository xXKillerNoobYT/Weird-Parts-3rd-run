import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../pin/pin_gate.dart';
import 'catalog_repository.dart';

class PartDetailPage extends StatefulWidget {
  const PartDetailPage({required this.partId, super.key});

  final String partId;

  @override
  State<PartDetailPage> createState() => _PartDetailPageState();
}

class _BrandVersionRow {
  _BrandVersionRow({
    required this.version,
    required this.brandName,
    required this.listings,
  });

  final BrandVersion version;
  final String brandName;
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
  List<_BrandVersionRow> _versions = [];

  String? _defaultSupplierId;
  bool _active = true;
  bool _loading = true;
  bool _saving = false;
  bool _initialized = false;

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
    final brandNames = {for (final b in brands) b.id: b.name};
    final supplierNames = {for (final s in suppliers) s.id: s.name};
    final versions = await _catalog.listBrandVersionsForPart(widget.partId);

    final rows = <_BrandVersionRow>[];
    for (final v in versions) {
      final listings = await _catalog.listingsForBrandVersion(v.id);
      rows.add(
        _BrandVersionRow(
          version: v,
          brandName: brandNames[v.brandId] ?? 'Unknown brand',
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
      _active = part.active;
      _suppliers = suppliers;
      _brands = brands;
      _versions = rows;
      _loading = false;
    });
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

  Future<void> _addBrandVersion() async {
    if (_brands.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a brand in Maintenance first')),
      );
      return;
    }
    if (!await _gate() || !mounted) return;

    String? brandId = _brands.first.id;
    final mpnController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Add brand version'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: brandId,
                    decoration: const InputDecoration(labelText: 'Brand'),
                    items: [
                      for (final b in _brands)
                        DropdownMenuItem(value: b.id, child: Text(b.name)),
                    ],
                    onChanged: (v) => setLocal(() => brandId = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: mpnController,
                    decoration: const InputDecoration(labelText: 'MPN'),
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
                    if (brandId == null || mpnController.text.trim().isEmpty) {
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
    mpnController.dispose();
    if (ok != true || brandId == null || mpn.isEmpty) return;

    try {
      await _catalog.createBrandVersion(
        partId: widget.partId,
        brandId: brandId!,
        mpn: mpn,
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
                      'Brand versions',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _addBrandVersion,
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                    ),
                  ],
                ),
                if (_versions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No brand versions yet'),
                  )
                else
                  for (final row in _versions)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ExpansionTile(
                        title: Text('${row.brandName} · ${row.version.mpn}'),
                        children: [
                          for (final listing in row.listings)
                            ListTile(
                              dense: true,
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
                      ),
                    ),
              ],
            ),
    );
  }
}
