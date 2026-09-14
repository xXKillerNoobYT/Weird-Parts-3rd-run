import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../maintenance/maintenance_repository.dart';
import '../pin/pin_gate.dart';
import 'catalog_repository.dart';
import 'part_photo_store.dart';
import 'tree_edit_prompts.dart';

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
  late final MaintenanceRepository _maintenance;
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
  String? _photoPath;
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
    _maintenance = MaintenanceRepository(scope.db, scope.pin, scope.deviceId);
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

    final photoPath = await _resolvedPhotoPath(part.photoPath);
    if (!mounted) return;
    setState(() {
      _nameController.text = part.name;
      _descriptionController.text = part.description;
      _uomController.text = part.uom;
      _defaultSupplierId = part.defaultSupplierId;
      _categoryId = part.categoryId;
      _styleId = part.styleId;
      _typeId = part.typeId;
      _photoPath = photoPath;
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

  bool get _photoFileExists =>
      _photoPath != null && File(_photoPath!).existsSync();

  bool get _canUseCamera => Platform.isAndroid || Platform.isIOS;

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<String?> _resolvedPhotoPath(String? stored) async {
    if (stored == null || stored.isEmpty) return null;
    final file = await const PartPhotoStore().resolveFile(stored);
    if (await file.exists()) return file.path;
    return stored;
  }

  /// Refresh only the photo preview so unsaved name/tree edits stay in the form.
  Future<void> _refreshPhotoPreview() async {
    final part = await _catalog.getPart(widget.partId);
    final path = await _resolvedPhotoPath(part?.photoPath);
    if (path != null) {
      await FileImage(File(path)).evict();
    }
    if (!mounted) return;
    setState(() => _photoPath = path);
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (!await _gate() || !mounted) return;
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: PartPhotoStore.maxEdge.toDouble(),
        maxHeight: PartPhotoStore.maxEdge.toDouble(),
        imageQuality: PartPhotoStore.jpegQuality,
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      await _catalog.attachPhoto(partId: widget.partId, bytes: bytes);
      await _refreshPhotoPreview();
      if (!mounted) return;
      _toast('Photo saved on this device');
    } on StateError catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } on FormatException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } catch (_) {
      if (!mounted) return;
      _toast(
        source == ImageSource.camera
            ? 'Camera is not available here. Use Choose photo.'
            : 'Could not open a photo. Try another file.',
      );
    }
  }

  Future<void> _removePhoto() async {
    if (!await _gate() || !mounted) return;
    try {
      await _catalog.clearPhoto(widget.partId);
      await _refreshPhotoPreview();
      if (!mounted) return;
      _toast('Photo removed');
    } on StateError catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  Future<void> _photoMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose photo'),
                subtitle: const Text('Windows / Mac: pick a file'),
                onTap: () => Navigator.pop(ctx, 'gallery'),
              ),
              if (_canUseCamera)
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take photo'),
                  onTap: () => Navigator.pop(ctx, 'camera'),
                ),
              if (_photoPath != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Remove photo'),
                  onTap: () => Navigator.pop(ctx, 'remove'),
                ),
            ],
          ),
        );
      },
    );
    if (choice == 'gallery') await _pickPhoto(ImageSource.gallery);
    if (choice == 'camera') await _pickPhoto(ImageSource.camera);
    if (choice == 'remove') await _removePhoto();
  }

  Widget _photoSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Photo', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Compressed and stored on this device. PIN required to change.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (_photoFileExists)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_photoPath!),
              key: ValueKey(_photoPath),
              height: 180,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          )
        else
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: _photoMenu,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    _photoPath == null
                        ? 'No photo yet — tap to add'
                        : 'Photo file missing — tap to replace',
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _photoMenu,
            icon: const Icon(Icons.add_a_photo_outlined),
            label: Text(_photoPath == null ? 'Add photo' : 'Change photo'),
          ),
        ),
      ],
    );
  }

  Future<void> _deletePart() async {
    if (_saving || !await _gate() || !mounted) return;
    final name = _nameController.text.trim().isEmpty
        ? 'this part'
        : '"${_nameController.text.trim()}"';
    final n = await _catalog.countJobLinesForPart(widget.partId);
    final extra = n > 0
        ? ' It is on $n job line(s); those lines stay on jobs.'
        : '';
    if (!mounted) return;
    final ok = await confirmAction(
      context,
      title: 'Remove part?',
      body: 'Remove $name from the catalog.$extra',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await _catalog.deletePart(widget.partId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on StateError catch (e) {
      if (!mounted) return;
      _toast(e.message);
      setState(() => _saving = false);
    }
  }

  Future<void> _refreshTaxonomyLists() async {
    final suppliers = await _db.taxonomyDao.listSuppliers();
    final brands = await _db.taxonomyDao.listBrands();
    final categories = await _db.taxonomyDao.listCategories();
    final styles = await _db.taxonomyDao.listStyles();
    final variants = await _db.taxonomyDao.listTypes();
    if (!mounted) return;
    setState(() {
      _suppliers = suppliers;
      _brands = brands;
      _categories = categories;
      _styles = styles;
      _variants = variants;
    });
  }

  Future<void> _addCategory() async {
    if (!await _gate() || !mounted) return;
    final name = await promptName(context, title: 'Add category');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await _maintenance.createCategory(name);
      await _refreshTaxonomyLists();
      if (!mounted) return;
      setState(() {
        _categoryId = id;
        _styleId = null;
        _typeId = null;
      });
    } on StateError catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  Future<void> _addType() async {
    if (_categoryId == null) {
      _toast('Set Category first');
      return;
    }
    if (!await _gate() || !mounted) return;
    final name = await promptName(context, title: 'Add type');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await _maintenance.createStyle(
        categoryId: _categoryId!,
        name: name,
      );
      await _refreshTaxonomyLists();
      if (!mounted) return;
      setState(() {
        _styleId = id;
        _typeId = null;
      });
    } on StateError catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  Future<void> _addVariant() async {
    if (_styleId == null) {
      _toast('Set Type first');
      return;
    }
    if (!await _gate() || !mounted) return;
    final name = await promptName(context, title: 'Add variant');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await _maintenance.createType(styleId: _styleId!, name: name);
      await _refreshTaxonomyLists();
      if (!mounted) return;
      setState(() => _typeId = id);
    } on StateError catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  Future<Brand?> _addBrandInPlace() async {
    if (!await _gate() || !mounted) return null;
    final name = await promptName(context, title: 'Add brand');
    if (name == null || name.isEmpty || !mounted) return null;
    try {
      final id = await _maintenance.createBrand(name);
      await _refreshTaxonomyLists();
      if (!mounted) return null;
      for (final b in _brands) {
        if (b.id == id) return b;
      }
      return null;
    } on StateError catch (e) {
      if (!mounted) return null;
      _toast(e.message);
      return null;
    }
  }

  Future<Supplier?> _addSupplierInPlace() async {
    if (!await _gate() || !mounted) return null;
    final name = await promptName(context, title: 'Add supplier');
    if (name == null || name.isEmpty || !mounted) return null;
    try {
      final id = await _maintenance.createSupplier(name);
      await _refreshTaxonomyLists();
      if (!mounted) return null;
      for (final s in _suppliers) {
        if (s.id == id) return s;
      }
      return null;
    } on StateError catch (e) {
      if (!mounted) return null;
      _toast(e.message);
      return null;
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required')),
      );
      return;
    }
    if (_categoryId == null || _styleId == null || _typeId == null) {
      _toast('Category, Type, and Variant are required');
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
    if (!await _gate() || !mounted) return;

    var selectedBrand = brandId;
    if (selectedBrand != null && !_brands.any((b) => b.id == selectedBrand)) {
      selectedBrand = null;
    }
    if (selectedBrand == null && _brands.isNotEmpty) {
      selectedBrand = _brands.first.id;
    }
    if (selectedBrand == null) {
      final created = await _addBrandInPlace();
      selectedBrand = created?.id;
      if (selectedBrand == null || !mounted) return;
    }

    final result = await showDialog<_VarianceDraft>(
      context: context,
      builder: (ctx) => _VarianceDialog(
        brands: List<Brand>.of(_brands),
        groups: _brandGroups,
        initialBrandId: selectedBrand,
        onAddBrand: _addBrandInPlace,
      ),
    );
    if (result == null || !mounted) return;

    try {
      await _catalog.createBrandVersion(
        partId: widget.partId,
        brandId: result.brandId,
        mpn: result.mpn,
        varianceName: result.varianceName,
        isMain: result.isMain,
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
    if (!await _gate() || !mounted) return;

    if (_suppliers.isEmpty) {
      final created = await _addSupplierInPlace();
      if (created == null || !mounted) return;
    }

    final result = await showDialog<_ListingDraft>(
      context: context,
      builder: (ctx) => _ListingDialog(
        suppliers: List<Supplier>.of(_suppliers),
        initialSupplierId: _defaultSupplierId ?? _suppliers.first.id,
        onAddSupplier: _addSupplierInPlace,
      ),
    );
    if (result == null || !mounted) return;

    try {
      await _catalog.createSupplierListing(
        brandVersionId: version.id,
        supplierId: result.supplierId,
        sku: result.sku,
      );
      await _reload();
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  Widget _treeField({
    required String label,
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    required VoidCallback? onAdd,
    bool enabled = true,
    bool allowNone = false,
  }) {
    final inItems = items.any((i) => i.value == value);
    final resolved = enabled && inItems ? value : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: allowNone
              ? DropdownButtonFormField<String?>(
                  // ignore: deprecated_member_use
                  value: resolved,
                  decoration: InputDecoration(
                    labelText: label,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    ...items.map(
                      (i) => DropdownMenuItem<String?>(
                        value: i.value,
                        child: i.child,
                      ),
                    ),
                  ],
                  onChanged: enabled ? onChanged : null,
                )
              : DropdownButtonFormField<String>(
                  // ignore: deprecated_member_use
                  value: resolved,
                  decoration: InputDecoration(
                    labelText: label,
                    border: const OutlineInputBorder(),
                  ),
                  hint: Text(enabled ? 'Select' : 'Set the parent first'),
                  items: items,
                  onChanged: enabled ? onChanged : null,
                ),
        ),
        IconButton(
          tooltip: 'Add $label',
          onPressed: onAdd,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Part'),
        actions: [
          if (!_loading)
            IconButton(
              tooltip: 'Remove part',
              onPressed: _saving ? null : _deletePart,
              icon: const Icon(Icons.delete_outline),
            ),
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
              cacheExtent: 4000,
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 16),
                Text(
                  'Tree location',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Required. Add missing folders here. Type stays under Category; Variant stays under Type.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                _treeField(
                  label: 'Category',
                  value: _categoryId,
                  items: [
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
                  onAdd: _saving ? null : _addCategory,
                ),
                const SizedBox(height: 12),
                _treeField(
                  label: 'Type',
                  value: _styleId,
                  enabled: _categoryId != null,
                  items: [
                    for (final s in _stylesForCategory)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _styleId = v;
                    if (_variantsForType.every((t) => t.id != _typeId)) {
                      _typeId = null;
                    }
                  }),
                  onAdd: _saving ? null : _addType,
                ),
                const SizedBox(height: 12),
                _treeField(
                  label: 'Variant',
                  value: _typeId,
                  enabled: _styleId != null,
                  items: [
                    for (final t in _variantsForType)
                      DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) => setState(() => _typeId = v),
                  onAdd: _saving ? null : _addVariant,
                ),
                const SizedBox(height: 16),
                _photoSection(),
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
                _treeField(
                  label: 'Default supplier',
                  value: _defaultSupplierId,
                  allowNone: true,
                  items: [
                    for (final s in _suppliers)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _defaultSupplierId = v),
                  onAdd: _saving
                      ? null
                      : () async {
                          final created = await _addSupplierInPlace();
                          if (created != null && mounted) {
                            setState(() => _defaultSupplierId = created.id);
                          }
                        },
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

class _VarianceDraft {
  const _VarianceDraft({
    required this.brandId,
    required this.varianceName,
    required this.mpn,
    required this.isMain,
  });

  final String brandId;
  final String varianceName;
  final String mpn;
  final bool isMain;
}

class _VarianceDialog extends StatefulWidget {
  const _VarianceDialog({
    required this.brands,
    required this.groups,
    required this.initialBrandId,
    required this.onAddBrand,
  });

  final List<Brand> brands;
  final List<_BrandGroup> groups;
  final String? initialBrandId;
  final Future<Brand?> Function() onAddBrand;

  @override
  State<_VarianceDialog> createState() => _VarianceDialogState();
}

class _VarianceDialogState extends State<_VarianceDialog> {
  late List<Brand> _brands;
  late String? _brandId;
  late bool _isMain;
  final _nameController = TextEditingController();
  final _mpnController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _brands = List<Brand>.of(widget.brands);
    _brandId = widget.initialBrandId ??
        (_brands.isEmpty ? null : _brands.first.id);
    _isMain = _existingForBrand(_brandId).isEmpty;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _mpnController.dispose();
    super.dispose();
  }

  Iterable<_VarianceRow> _existingForBrand(String? brandId) {
    if (brandId == null) return const [];
    return widget.groups
        .where((g) => g.brandId == brandId)
        .expand((g) => g.variances);
  }

  Future<void> _addBrand() async {
    final created = await widget.onAddBrand();
    if (created == null || !mounted) return;
    setState(() {
      if (!_brands.any((b) => b.id == created.id)) {
        _brands = [..._brands, created];
      }
      _brandId = created.id;
      _isMain = _existingForBrand(_brandId).isEmpty;
    });
  }

  void _submit() {
    final brandId = _brandId;
    final mpn = _mpnController.text.trim();
    if (brandId == null || mpn.isEmpty) return;
    Navigator.pop(
      context,
      _VarianceDraft(
        brandId: brandId,
        varianceName: _nameController.text.trim(),
        mpn: mpn,
        isMain: _isMain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add variance'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: _brandId != null && _brands.any((b) => b.id == _brandId)
                  ? _brandId
                  : null,
              decoration: const InputDecoration(labelText: 'Brand'),
              hint: const Text('Select or add'),
              items: [
                for (final b in _brands)
                  DropdownMenuItem(value: b.id, child: Text(b.name)),
              ],
              onChanged: (v) {
                setState(() {
                  _brandId = v;
                  _isMain = _existingForBrand(v).isEmpty;
                });
              },
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addBrand,
                icon: const Icon(Icons.add),
                label: const Text('Add brand'),
              ),
            ),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Variance (color / option)',
                hintText: 'White',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _mpnController,
              decoration: const InputDecoration(labelText: 'Part number'),
              autofocus: true,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Main'),
              subtitle: const Text('First pick; others are extra options'),
              value: _isMain,
              onChanged: (v) => setState(() => _isMain = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _ListingDraft {
  const _ListingDraft({required this.supplierId, required this.sku});

  final String supplierId;
  final String sku;
}

class _ListingDialog extends StatefulWidget {
  const _ListingDialog({
    required this.suppliers,
    required this.initialSupplierId,
    required this.onAddSupplier,
  });

  final List<Supplier> suppliers;
  final String? initialSupplierId;
  final Future<Supplier?> Function() onAddSupplier;

  @override
  State<_ListingDialog> createState() => _ListingDialogState();
}

class _ListingDialogState extends State<_ListingDialog> {
  late List<Supplier> _suppliers;
  late String? _supplierId;
  final _skuController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _suppliers = List<Supplier>.of(widget.suppliers);
    _supplierId = widget.initialSupplierId ??
        (_suppliers.isEmpty ? null : _suppliers.first.id);
  }

  @override
  void dispose() {
    _skuController.dispose();
    super.dispose();
  }

  Future<void> _addSupplier() async {
    final created = await widget.onAddSupplier();
    if (created == null || !mounted) return;
    setState(() {
      if (!_suppliers.any((s) => s.id == created.id)) {
        _suppliers = [..._suppliers, created];
      }
      _supplierId = created.id;
    });
  }

  void _submit() {
    final supplierId = _supplierId;
    final sku = _skuController.text.trim();
    if (supplierId == null || sku.isEmpty) return;
    Navigator.pop(context, _ListingDraft(supplierId: supplierId, sku: sku));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add supplier listing'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _supplierId != null &&
                    _suppliers.any((s) => s.id == _supplierId)
                ? _supplierId
                : null,
            decoration: const InputDecoration(labelText: 'Supplier'),
            hint: const Text('Select or add'),
            items: [
              for (final s in _suppliers)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) => setState(() => _supplierId = v),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addSupplier,
              icon: const Icon(Icons.add),
              label: const Text('Add supplier'),
            ),
          ),
          TextField(
            controller: _skuController,
            decoration: const InputDecoration(labelText: 'SKU'),
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

