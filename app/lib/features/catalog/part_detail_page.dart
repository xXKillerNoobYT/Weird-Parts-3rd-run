import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../edit_drafts/edit_drafts.dart';
import '../edit_drafts/edit_draft_widgets.dart';
import '../pin/pin_gate.dart';
import 'catalog_repository.dart';
import 'catalog_name_dialog.dart';
import 'part_photo_store.dart';
import 'tree_edit_prompts.dart';

class PartDetailPage extends StatefulWidget {
  const PartDetailPage({required this.partId, this.focusBrandId, super.key});

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
  _VarianceRow({required this.version, required this.listings});

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
  final _specsController = TextEditingController();
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
  EditDrafts? _edits;
  PartEditSession? _session;
  EditOpening<PartEditSession>? _opening;
  bool _applyingInput = false;
  bool _allowPop = false;
  String? _catalogNameNotice;

  void _capture() {
    if (_loading || _applyingInput) return;
    _session?.replace(
      PartInput(
        nameText: _nameController.text,
        descriptionText: _descriptionController.text,
        specsText: _specsController.text,
        uomText: _uomController.text,
        categoryId: _categoryId,
        styleId: _styleId,
        typeId: _typeId,
        defaultSupplierId: _defaultSupplierId,
        active: _active,
      ),
    );
  }

  void _change(VoidCallback change) {
    setState(change);
    _capture();
  }

  Future<void> _useSession(PartEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    _applyingInput = true;
    final input = session.initial;
    setState(() {
      _session = session;
      _opening = null;
      _nameController.text = input.nameText;
      _descriptionController.text = input.descriptionText;
      _specsController.text = input.specsText;
      _uomController.text = input.uomText;
      _categoryId = input.categoryId;
      _styleId = input.styleId;
      _typeId = input.typeId;
      _defaultSupplierId = input.defaultSupplierId;
      _active = input.active;
    });
    _applyingInput = false;
  }

  Future<void> _openDraft() async {
    final edits = _edits;
    if (edits == null) return;
    if (mounted) setState(() => _loading = true);
    final opening = await edits.openPart(widget.partId);
    if (!mounted) {
      if (opening is FreshEdit<PartEditSession>) {
        await opening.session.leave(LeaveIntent.back);
      }
      return;
    }
    if (opening is FreshEdit<PartEditSession>) {
      await _useSession(opening.session);
    } else {
      setState(() => _opening = opening);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<PartEditSession> opening:
        await opening.discard();
      case BlockedEdit<PartEditSession> opening:
        await opening.discard();
      default:
        return;
    }
    await _openDraft();
  }

  Future<void> _leave(LeaveIntent intent) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _session?.leave(intent);
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) _toast('Could not leave. $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _edits = scope.edits;
    for (final controller in [
      _nameController,
      _descriptionController,
      _specsController,
      _uomController,
    ]) {
      controller.addListener(_capture);
    }
    _db = scope.db;
    _catalog = CatalogRepository(scope.db, scope.pin, scope.deviceId);
    _reload();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _specsController.dispose();
    _uomController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final part = await _catalog.getPart(widget.partId);
    if (part == null) {
      if (!mounted) return;
      if (_edits == null) setState(() => _loading = false);
      await _openDraft();
      return;
    }

    final suppliers = await _db.taxonomyDao.listSuppliers();
    final brands = await _db.taxonomyDao.listBrands();
    final categories = await _db.taxonomyDao.listCategories();
    final styles = await _db.taxonomyDao.listStyles();
    final variants = await _db.taxonomyDao.listTypes();
    final groups = await _loadBrandGroups(brands: brands, suppliers: suppliers);

    final photoPath = await _resolvedPhotoPath(part.photoPath);
    if (!mounted) return;
    setState(() {
      _nameController.text = part.name;
      _descriptionController.text = part.description;
      _specsController.text = part.specs;
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
      _brandGroups = groups;
      _loading = _edits != null;
    });

    await _openDraft();
    if (!_openedFocus && widget.focusBrandId != null && _opening == null) {
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
      final session = _session;
      if (session == null) {
        await _catalog.attachPhoto(partId: widget.partId, bytes: bytes);
      } else {
        await session.attachPhoto(bytes: bytes);
      }
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
      final session = _session;
      if (session == null) {
        await _catalog.clearPhoto(widget.partId);
      } else {
        await session.clearPhoto();
      }
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
      await _session?.leave(LeaveIntent.back);
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } on StateError catch (e) {
      if (!mounted) return;
      _toast(e.message);
      setState(() => _saving = false);
    }
  }

  Future<List<_BrandGroup>> _loadBrandGroups({
    required List<Brand> brands,
    required List<Supplier> suppliers,
  }) async {
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
    return groups.values.toList()
      ..sort((a, b) => a.brandName.compareTo(b.brandName));
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

  /// Reloads brands, listings, and taxonomy chips without touching unsaved
  /// name / tree / supplier fields (a full [_reload] would restore null IDs).
  Future<void> _refreshBrandGroups() async {
    await _refreshTaxonomyLists();
    if (!mounted) return;
    final groups = await _loadBrandGroups(
      brands: _brands,
      suppliers: _suppliers,
    );
    if (!mounted) return;
    setState(() => _brandGroups = groups);
  }

  Future<void> _addCategory() async {
    if (!await _gate() || !mounted) return;
    await _editTaxonomyName(CatalogNameTarget.newCategory(), 'Add category');
  }

  Future<void> _addType() async {
    if (_categoryId == null) {
      _toast('Set Category first');
      return;
    }
    if (!await _gate() || !mounted) return;
    await _editTaxonomyName(
      CatalogNameTarget.newType(_categoryId!),
      'Add type',
    );
  }

  Future<void> _addVariant() async {
    if (_styleId == null) {
      _toast('Set Type first');
      return;
    }
    if (!await _gate() || !mounted) return;
    await _editTaxonomyName(
      CatalogNameTarget.newVariant(_styleId!),
      'Add variant',
    );
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
          if (saved.kind == CatalogNameKind.brand ||
              saved.kind == CatalogNameKind.supplier) {
            throw StateError(
              'A brand or supplier cannot change the part taxonomy',
            );
          }
          await _refreshTaxonomyLists();
          if (!mounted) return;
          _change(() {
            switch (saved.kind) {
              case CatalogNameKind.category:
                _categoryId = saved.id;
                _styleId = null;
                _typeId = null;
              case CatalogNameKind.type:
                _styleId = saved.id;
                _typeId = null;
              case CatalogNameKind.variant:
                _typeId = saved.id;
              case CatalogNameKind.brand:
              case CatalogNameKind.supplier:
                throw StateError(
                  'A brand or supplier cannot change the part taxonomy',
                );
            }
          });
          await _session?.flush();
        },
      );
    } catch (error) {
      if (mounted) _toast('$error');
    }
  }

  Future<Brand?> _addBrandInPlace({
    BuildContext? consumerContext,
    required Future<void> Function(Brand) onAdopt,
    ValueChanged<String>? onNotice,
  }) async {
    final consumer = consumerContext ?? context;
    if (!consumer.mounted || !await _gate() || !mounted || !consumer.mounted) {
      return null;
    }
    setState(() => _catalogNameNotice = null);
    Brand? created;
    void notice(String message) {
      if (!consumer.mounted) return;
      if (mounted) setState(() => _catalogNameNotice = message);
      onNotice?.call(message);
    }

    try {
      await showCatalogNameDialog(
        consumer,
        target: CatalogNameTarget.newBrand(),
        title: 'Add brand',
        onSaved: (saved) async {
          await _refreshTaxonomyLists();
          if (!mounted || !consumer.mounted) {
            throw StateError('The brand consumer is no longer available');
          }
          final matching = _brands.where(
            (brand) => brand.id == saved.id && brand.name == saved.name,
          );
          if (saved.kind != CatalogNameKind.brand || matching.isEmpty) {
            throw StateError(
              'The saved brand is not available in the refreshed list',
            );
          }
          final brand = matching.first;
          await onAdopt(brand);
          if (!mounted || !consumer.mounted) {
            throw StateError('The brand consumer is no longer available');
          }
          created = brand;
        },
        onNotice: notice,
      );
    } catch (error) {
      notice('$error');
    }
    return created;
  }

  Future<Supplier?> _addSupplierInPlace({
    BuildContext? consumerContext,
    required Future<void> Function(Supplier) onAdopt,
    ValueChanged<String>? onNotice,
  }) async {
    final consumer = consumerContext ?? context;
    if (!consumer.mounted || !await _gate() || !mounted || !consumer.mounted) {
      return null;
    }
    setState(() => _catalogNameNotice = null);
    Supplier? created;
    void notice(String message) {
      if (!consumer.mounted) return;
      if (mounted) setState(() => _catalogNameNotice = message);
      onNotice?.call(message);
    }

    try {
      await showCatalogNameDialog(
        consumer,
        target: CatalogNameTarget.newSupplier(),
        title: 'Add supplier',
        onSaved: (saved) async {
          await _refreshTaxonomyLists();
          if (!mounted || !consumer.mounted) {
            throw StateError('The supplier consumer is no longer available');
          }
          final matching = _suppliers.where(
            (supplier) =>
                supplier.id == saved.id && supplier.name == saved.name,
          );
          if (saved.kind != CatalogNameKind.supplier || matching.isEmpty) {
            throw StateError(
              'The saved supplier is not available in the refreshed list',
            );
          }
          final supplier = matching.first;
          await onAdopt(supplier);
          if (!mounted || !consumer.mounted) {
            throw StateError('The supplier consumer is no longer available');
          }
          created = supplier;
        },
        onNotice: notice,
      );
    } catch (error) {
      notice('$error');
    }
    return created;
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name is required')));
      return;
    }
    if (_categoryId == null || _styleId == null || _typeId == null) {
      _toast('Category, Type, and Variant are required');
      return;
    }
    if (!await _gate() || !mounted) return;

    setState(() => _saving = true);
    try {
      final session = _session;
      if (session != null) {
        final saved = await session.save();
        if (!mounted) return;
        await _useSession(saved.session);
      } else {
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
          specs: _specsController.text,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (error) {
      if (mounted) _toast('Save failed. $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addVariance({String? brandId}) async {
    if (!await _gate() || !mounted) return;
    final edits = _edits;
    if (edits == null) {
      _toast('Unfinished edits are unavailable');
      return;
    }
    var selectedBrand = brandId;
    selectedBrand ??= _brands.isEmpty ? null : _brands.first.id;
    final result = await showDialog<VarianceCreated>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _VarianceDialog(
        edits: edits,
        partId: widget.partId,
        brands: List<Brand>.of(_brands),
        groups: _brandGroups,
        initialBrandId: selectedBrand,
        onAddBrand: (consumer, onAdopt, onNotice) => _addBrandInPlace(
          consumerContext: consumer,
          onAdopt: onAdopt,
          onNotice: onNotice,
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      await _refreshTaxonomyLists();
      await _refreshBrandGroups();
      if (!mounted) return;
      final saved = _brandGroups
          .expand((group) => group.variances)
          .where((row) => result.identifies(row.version));
      final part = await _db.partsDao.getPart(result.partId);
      if (!mounted) return;
      if (saved.isEmpty ||
          part == null ||
          !_brands.any((brand) => brand.id == result.brandId)) {
        throw StateError(
          'The saved variance is unavailable in the refreshed list',
        );
      }
      _toast('Variance saved');
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await result.acknowledge();
    } catch (error) {
      if (mounted) _toast('Variance saved. Confirmation pending. $error');
    }
  }

  Future<void> _addListing(BrandVersion version) async {
    if (!await _gate() || !mounted) return;
    final edits = _edits;
    if (edits == null) {
      _toast('Unfinished edits are unavailable');
      return;
    }
    final result = await showDialog<SupplierListingSaved>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ListingDialog(
        edits: edits,
        partId: widget.partId,
        brandVersionId: version.id,
        suppliers: List<Supplier>.of(_suppliers),
        initialSupplierId:
            _defaultSupplierId ??
            (_suppliers.isEmpty ? null : _suppliers.first.id),
        onAddSupplier: (consumer, onAdopt, onNotice) => _addSupplierInPlace(
          consumerContext: consumer,
          onAdopt: onAdopt,
          onNotice: onNotice,
        ),
      ),
    );
    if (result == null || !mounted) return;

    try {
      await _refreshBrandGroups();
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await result.acknowledge();
    } catch (error) {
      if (mounted) _toast('Supplier listing saved. Refresh pending: $error');
    }
  }

  Widget _treeField({
    required String label,
    required String addLabel,
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    required VoidCallback? onAdd,
    bool enabled = true,
    bool allowNone = false,
  }) {
    return TaxonomyPickField(
      label: label,
      addLabel: addLabel,
      value: value,
      items: [
        if (value != null && !items.any((item) => item.value == value))
          DropdownMenuItem(
            value: value,
            child: Text('Unavailable $label ($value)'),
          ),
        ...items,
      ],
      onChanged: onChanged,
      onAdd: onAdd,
      enabled: enabled,
      allowNone: allowNone,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: _edits == null || _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(LeaveIntent.back);
      },
      child: Scaffold(
        bottomNavigationBar: _catalogNameNotice == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_catalogNameNotice!),
                  ),
                ),
              ),
        appBar: AppBar(
          title: const Text('Part'),
          actions: [
            if (_session != null)
              TextButton(
                onPressed: _saving ? null : () => _leave(LeaveIntent.discard),
                child: const Text('Discard'),
              ),
            if (!_loading && _opening == null)
              IconButton(
                tooltip: 'Remove part',
                onPressed: _saving ? null : _deletePart,
                icon: const Icon(Icons.delete_outline),
              ),
            if (!_loading && _opening == null)
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
            : _opening != null
            ? EditOpeningPanel<PartEditSession>(
                opening: _opening!,
                onResume: _useSession,
                onDiscard: _discardRecovery,
              )
            : AbsorbPointer(
                absorbing: _saving,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  // ignore: deprecated_member_use
                  cacheExtent: 4000, // keep Add Category/Type/Variant mounted
                  children: [
                    if (_session case final session?)
                      EditStatusBanner(status: session.status),
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
                      addLabel: 'Add Category',
                      value: _categoryId,
                      items: [
                        for (final c in _categories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => _change(() {
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
                      addLabel: 'Add Type',
                      value: _styleId,
                      enabled: _categoryId != null,
                      items: [
                        for (final s in _stylesForCategory)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: (v) => _change(() {
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
                      addLabel: 'Add Variant',
                      value: _typeId,
                      enabled: _styleId != null,
                      items: [
                        for (final t in _variantsForType)
                          DropdownMenuItem(value: t.id, child: Text(t.name)),
                      ],
                      onChanged: (v) => _change(() => _typeId = v),
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
                      controller: _specsController,
                      decoration: const InputDecoration(
                        labelText: 'Specifications',
                        border: OutlineInputBorder(),
                      ),
                      minLines: 3,
                      maxLines: 6,
                      textAlignVertical: TextAlignVertical.top,
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
                      addLabel: 'Add supplier',
                      value: _defaultSupplierId,
                      allowNone: true,
                      items: [
                        for (final s in _suppliers)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: (v) => _change(() => _defaultSupplierId = v),
                      onAdd: _saving
                          ? null
                          : () async {
                              final session = _session;
                              await _addSupplierInPlace(
                                onAdopt: (supplier) async {
                                  if (!mounted ||
                                      _loading ||
                                      _saving ||
                                      _opening != null ||
                                      session == null ||
                                      !identical(_session, session) ||
                                      session.status.value.phase ==
                                          EditPhase.closed) {
                                    throw StateError(
                                      'The part editor is no longer available',
                                    );
                                  }
                                  _change(
                                    () => _defaultSupplierId = supplier.id,
                                  );
                                  if (session.initial.defaultSupplierId !=
                                      supplier.id) {
                                    throw StateError(
                                      'The supplier selection was not captured',
                                    );
                                  }
                                  await session.flush();
                                  if (!mounted ||
                                      _loading ||
                                      _saving ||
                                      _opening != null ||
                                      !identical(_session, session) ||
                                      session.status.value.phase ==
                                          EditPhase.closed) {
                                    throw StateError(
                                      'The part editor is no longer available',
                                    );
                                  }
                                  final status = session.status.value;
                                  if (status.phase != EditPhase.durable ||
                                      status.durableSequence !=
                                          status.latestSequence ||
                                      session.initial.defaultSupplierId !=
                                          supplier.id) {
                                    throw StateError(
                                      'The default supplier selection is not durable yet',
                                    );
                                  }
                                },
                              );
                            },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      value: _active,
                      onChanged: (v) => _change(() => _active = v),
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
                                    contentPadding: const EdgeInsets.only(
                                      left: 32,
                                      right: 16,
                                    ),
                                    title: Text(listing.supplierName),
                                    subtitle: Text(
                                      listing.listing.sku.trim().isEmpty
                                          ? 'No SKU'
                                          : 'SKU ${listing.listing.sku}',
                                    ),
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
              ),
      ),
    );
  }
}

class _VarianceDialog extends StatefulWidget {
  const _VarianceDialog({
    required this.edits,
    required this.partId,
    required this.brands,
    required this.groups,
    required this.initialBrandId,
    required this.onAddBrand,
  });

  final EditDrafts edits;
  final String partId;
  final List<Brand> brands;
  final List<_BrandGroup> groups;
  final String? initialBrandId;
  final Future<Brand?> Function(
    BuildContext consumer,
    Future<void> Function(Brand) onAdopt,
    ValueChanged<String> onNotice,
  )
  onAddBrand;

  @override
  State<_VarianceDialog> createState() => _VarianceDialogState();
}

class _VarianceDialogState extends State<_VarianceDialog> {
  late List<Brand> _brands;
  late String? _brandId;
  final _mpnController = TextEditingController();
  final _nameController = TextEditingController();
  late bool _isMain;
  String? _notice;
  String? _error;
  NewVarianceEditSession? _session;
  EditOpening<NewVarianceEditSession>? _opening;
  VarianceCreated? _saved;
  bool _loading = true;
  bool _busy = false;
  bool _applyingInput = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    _brands = List<Brand>.of(widget.brands);
    _brandId =
        widget.initialBrandId ?? (_brands.isEmpty ? null : _brands.first.id);
    _isMain = _existingForBrand(_brandId).isEmpty;
    _mpnController.addListener(_capture);
    _nameController.addListener(_capture);
    _openDraft();
  }

  @override
  void dispose() {
    _mpnController.removeListener(_capture);
    _nameController.removeListener(_capture);
    final session = _session;
    if (session != null) {
      unawaited(session.leave(LeaveIntent.back).catchError((Object _) {}));
    }
    _mpnController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _capture() {
    if (_applyingInput) return;
    _session?.replace(
      VarianceInput(
        brandId: _brandId,
        mpnText: _mpnController.text,
        varianceNameText: _nameController.text,
        isMain: _isMain,
      ),
    );
  }

  Future<void> _openDraft() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final opening = await widget.edits.openNewVariance(
        partId: widget.partId,
        initial: VarianceInput(
          brandId: _brandId,
          mpnText: '',
          varianceNameText: '',
          isMain: _isMain,
        ),
      );
      if (!mounted) {
        if (opening is FreshEdit<NewVarianceEditSession>) {
          await opening.session.leave(LeaveIntent.back);
        }
        return;
      }
      if (opening is FreshEdit<NewVarianceEditSession>) {
        await _useSession(opening.session);
      } else if (opening is VarianceCreated) {
        setState(() {
          _saved = opening;
          _opening = null;
        });
      } else {
        setState(() => _opening = opening);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useSession(NewVarianceEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    _applyingInput = true;
    setState(() {
      _session = session;
      _opening = null;
      _saved = null;
      _brandId = session.initial.brandId;
      _mpnController.text = session.initial.mpnText;
      _nameController.text = session.initial.varianceNameText;
      _isMain = session.initial.isMain;
    });
    _applyingInput = false;
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<NewVarianceEditSession> opening:
        await opening.discard();
      case BlockedEdit<NewVarianceEditSession> opening:
        await opening.discard();
      default:
        return;
    }
    if (!mounted) return;
    setState(() => _opening = null);
    await _openDraft();
  }

  Iterable<_VarianceRow> _existingForBrand(String? brandId) => widget.groups
      .where((group) => group.brandId == brandId)
      .expand((group) => group.variances);

  Future<void> _addBrand() async {
    final session = _session;
    if (_busy || session == null) return;
    setState(() {
      _notice = null;
      _busy = true;
      _error = null;
    });
    try {
      _capture();
      await session.flush();
      if (!mounted) return;
      await widget.onAddBrand(
        context,
        (brand) async {
          if (!mounted) {
            throw StateError('The variance dialog is no longer available');
          }
          setState(() {
            _brands = [
              for (final existing in _brands)
                if (existing.id != brand.id) existing,
              brand,
            ];
            _brandId = brand.id;
            _isMain = _existingForBrand(brand.id).isEmpty;
          });
          _capture();
          await session.flush();
          final status = session.status.value;
          if (!mounted ||
              _session != session ||
              status.phase != EditPhase.durable ||
              status.durableSequence != status.latestSequence ||
              session.initial.brandId != brand.id) {
            throw StateError('The variance dialog is no longer available');
          }
        },
        (message) {
          if (mounted) setState(() => _notice = message);
        },
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final session = _session;
    if (_busy || session == null) return;
    _capture();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _finish(await session.save());
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish(VarianceCreated saved) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop<VarianceCreated>(saved);
  }

  Future<void> _leave(LeaveIntent intent) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_session case final session?) {
        _capture();
        await session.leave(intent);
      } else if (intent == LeaveIntent.discard) {
        switch (_opening) {
          case RecoverableEdit<NewVarianceEditSession> opening:
            await opening.discard();
          case BlockedEdit<NewVarianceEditSession> opening:
            await opening.discard();
          default:
            break;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop<VarianceCreated>();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<VarianceCreated>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(LeaveIntent.back);
      },
      child: AlertDialog(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add variance'),
            if (_notice != null) ...[
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(_notice!)),
            ],
          ],
        ),
        content: SizedBox(
          width: 420,
          height: _opening != null ? 260 : 390,
          child: Column(
            children: [
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _opening != null
                    ? EditOpeningPanel<NewVarianceEditSession>(
                        opening: _opening!,
                        onResume: _useSession,
                        onDiscard: _discardRecovery,
                      )
                    : _saved != null
                    ? const Text('Variance saved')
                    : ListView(
                        children: [
                          if (_session case final session?)
                            EditStatusBanner(status: session.status),
                          if (_session == null)
                            TextButton(
                              onPressed: _openDraft,
                              child: const Text('Retry'),
                            ),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            key: ValueKey(_brandId),
                            initialValue:
                                _brandId != null &&
                                    _brands.any((s) => s.id == _brandId)
                                ? _brandId
                                : null,
                            decoration: const InputDecoration(
                              labelText: 'Brand',
                            ),
                            hint: const Text('Select or add'),
                            items: [
                              for (final s in _brands)
                                DropdownMenuItem(
                                  value: s.id,
                                  child: Text(s.name),
                                ),
                            ],
                            onChanged: _busy || _session == null
                                ? null
                                : (v) {
                                    setState(() {
                                      _brandId = v;
                                      _isMain = _existingForBrand(v).isEmpty;
                                    });
                                    _capture();
                                  },
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _busy || _session == null
                                  ? null
                                  : _addBrand,
                              icon: const Icon(Icons.add),
                              label: const Text('Add brand'),
                            ),
                          ),
                          TextField(
                            controller: _nameController,
                            enabled: !_busy && _session != null,
                            decoration: const InputDecoration(
                              labelText: 'Variance (color / option)',
                              hintText: 'White',
                            ),
                          ),
                          TextField(
                            controller: _mpnController,
                            enabled: !_busy && _session != null,
                            decoration: const InputDecoration(
                              labelText: 'Part number',
                            ),
                            autofocus: true,
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Main'),
                            subtitle: const Text(
                              'First pick; others are extra options',
                            ),
                            value: _isMain,
                            onChanged: _busy || _session == null
                                ? null
                                : (value) {
                                    setState(() => _isMain = value);
                                    _capture();
                                  },
                          ),
                        ],
                      ),
              ),
              if (_error != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 100),
                  child: SingleChildScrollView(child: Text(_error!)),
                ),
            ],
          ),
        ),
        actions: [
          if (_saved != null)
            TextButton(
              onPressed: () => _leave(LeaveIntent.back),
              child: const Text('Close'),
            ),
          if (_saved case final saved?)
            FilledButton(
              onPressed: () => _finish(saved),
              child: const Text('Done'),
            )
          else ...[
            TextButton(
              onPressed: _busy || _loading
                  ? null
                  : () => _leave(LeaveIntent.back),
              child: const Text('Back'),
            ),
            TextButton(
              onPressed: _busy || _loading
                  ? null
                  : () => _leave(LeaveIntent.discard),
              child: const Text('Cancel'),
            ),
            if (_session != null && _opening == null)
              FilledButton(
                onPressed: _busy || _loading ? null : _submit,
                child: const Text('Add'),
              ),
          ],
        ],
      ),
    );
  }
}

class _ListingDialog extends StatefulWidget {
  const _ListingDialog({
    required this.edits,
    required this.partId,
    required this.brandVersionId,
    required this.suppliers,
    required this.initialSupplierId,
    required this.onAddSupplier,
  });

  final EditDrafts edits;
  final String partId, brandVersionId;
  final List<Supplier> suppliers;
  final String? initialSupplierId;
  final Future<Supplier?> Function(
    BuildContext consumer,
    Future<void> Function(Supplier) onAdopt,
    ValueChanged<String> onNotice,
  )
  onAddSupplier;

  @override
  State<_ListingDialog> createState() => _ListingDialogState();
}

class _ListingDialogState extends State<_ListingDialog> {
  late List<Supplier> _suppliers;
  late String? _supplierId;
  final _skuController = TextEditingController();
  String? _notice;
  String? _error;
  SupplierListingEditSession? _session;
  EditOpening<SupplierListingEditSession>? _opening;
  SupplierListingSaved? _saved;
  bool _loading = true;
  bool _busy = false;
  bool _applyingInput = false;
  bool _allowPop = false;

  @override
  void initState() {
    super.initState();
    _suppliers = List<Supplier>.of(widget.suppliers);
    _supplierId =
        widget.initialSupplierId ??
        (_suppliers.isEmpty ? null : _suppliers.first.id);
    _skuController.addListener(_capture);
    _openDraft();
  }

  @override
  void dispose() {
    _skuController.removeListener(_capture);
    final session = _session;
    if (session != null) {
      unawaited(session.leave(LeaveIntent.back).catchError((Object _) {}));
    }
    _skuController.dispose();
    super.dispose();
  }

  void _capture() {
    if (_applyingInput) return;
    _session?.replace(
      SupplierListingInput(
        supplierId: _supplierId,
        skuText: _skuController.text,
      ),
    );
  }

  Future<void> _openDraft() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    var bootstrap = false;
    try {
      final opening = await widget.edits.openSupplierListing(
        brandVersionId: widget.brandVersionId,
        partId: widget.partId,
        initial: SupplierListingInput(supplierId: _supplierId, skuText: ''),
      );
      if (!mounted) {
        if (opening is FreshEdit<SupplierListingEditSession>) {
          await opening.session.leave(LeaveIntent.back);
        }
        return;
      }
      if (opening is FreshEdit<SupplierListingEditSession>) {
        await _useSession(opening.session);
        bootstrap = _suppliers.isEmpty;
      } else if (opening is SupplierListingSaved) {
        setState(() {
          _saved = opening;
          _opening = null;
        });
      } else {
        setState(() => _opening = opening);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (mounted && bootstrap) await _addSupplier();
  }

  Future<void> _useSession(SupplierListingEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    _applyingInput = true;
    setState(() {
      _session = session;
      _opening = null;
      _saved = null;
      _supplierId = session.initial.supplierId;
      _skuController.text = session.initial.skuText;
    });
    _applyingInput = false;
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<SupplierListingEditSession> opening:
        await opening.discard();
      case BlockedEdit<SupplierListingEditSession> opening:
        await opening.discard();
      default:
        return;
    }
    if (!mounted) return;
    setState(() => _opening = null);
    await _openDraft();
  }

  Future<void> _addSupplier() async {
    final session = _session;
    if (_busy || session == null) return;
    setState(() {
      _notice = null;
      _busy = true;
      _error = null;
    });
    try {
      _capture();
      await session.flush();
      if (!mounted) return;
      await widget.onAddSupplier(
        context,
        (supplier) async {
          if (!mounted) {
            throw StateError('The listing dialog is no longer available');
          }
          setState(() {
            _suppliers = [
              for (final existing in _suppliers)
                if (existing.id != supplier.id) existing,
              supplier,
            ];
            _supplierId = supplier.id;
          });
          _capture();
          await session.flush();
          if (!mounted || session.status.value.phase == EditPhase.closed) {
            throw StateError('The listing dialog is no longer available');
          }
        },
        (message) {
          if (mounted) setState(() => _notice = message);
        },
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final session = _session;
    if (_busy || session == null) return;
    _capture();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _finish(await session.save());
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish(SupplierListingSaved saved) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop<SupplierListingSaved>(saved);
  }

  Future<void> _leave(LeaveIntent intent) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_session case final session?) {
        _capture();
        await session.leave(intent);
      } else if (intent == LeaveIntent.discard) {
        switch (_opening) {
          case RecoverableEdit<SupplierListingEditSession> opening:
            await opening.discard();
          case BlockedEdit<SupplierListingEditSession> opening:
            await opening.discard();
          default:
            break;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop<SupplierListingSaved>();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<SupplierListingSaved>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(LeaveIntent.back);
      },
      child: AlertDialog(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add supplier listing'),
            if (_notice != null) ...[
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(_notice!)),
            ],
          ],
        ),
        content: SizedBox(
          width: 420,
          height: _opening != null ? 260 : 330,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _opening != null
              ? EditOpeningPanel<SupplierListingEditSession>(
                  opening: _opening!,
                  onResume: _useSession,
                  onDiscard: _discardRecovery,
                )
              : _saved != null
              ? const Text('Supplier listing saved')
              : ListView(
                  children: [
                    if (_session case final session?)
                      EditStatusBanner(status: session.status),
                    if (_session == null)
                      TextButton(
                        onPressed: _openDraft,
                        child: const Text('Retry'),
                      ),
                    DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value:
                          _supplierId != null &&
                              _suppliers.any((s) => s.id == _supplierId)
                          ? _supplierId
                          : null,
                      decoration: const InputDecoration(labelText: 'Supplier'),
                      hint: const Text('Select or add'),
                      items: [
                        for (final s in _suppliers)
                          DropdownMenuItem(value: s.id, child: Text(s.name)),
                      ],
                      onChanged: _busy || _session == null
                          ? null
                          : (v) {
                              setState(() => _supplierId = v);
                              _capture();
                            },
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _busy || _session == null
                            ? null
                            : _addSupplier,
                        icon: const Icon(Icons.add),
                        label: const Text('Add supplier'),
                      ),
                    ),
                    TextField(
                      controller: _skuController,
                      enabled: !_busy && _session != null,
                      decoration: const InputDecoration(
                        labelText: 'SKU (optional)',
                        hintText: 'Leave blank if you do not have one',
                      ),
                      autofocus: true,
                    ),
                    if (_error != null) Text(_error!),
                  ],
                ),
        ),
        actions: [
          if (_saved case final saved?)
            FilledButton(
              onPressed: () => _finish(saved),
              child: const Text('Done'),
            )
          else ...[
            TextButton(
              onPressed: _busy || _loading
                  ? null
                  : () => _leave(LeaveIntent.back),
              child: const Text('Back'),
            ),
            TextButton(
              onPressed: _busy || _loading
                  ? null
                  : () => _leave(LeaveIntent.discard),
              child: const Text('Cancel'),
            ),
            if (_session != null && _opening == null)
              FilledButton(
                onPressed: _busy || _loading ? null : _submit,
                child: const Text('Add'),
              ),
          ],
        ],
      ),
    );
  }
}
