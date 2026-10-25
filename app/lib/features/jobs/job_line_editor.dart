import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/catalog_name_dialog.dart';
import '../catalog/catalog_tree.dart';
import '../catalog/catalog_tree_picker.dart';
import '../catalog/part_detail_page.dart';
import '../catalog/part_details_dialog.dart';
import '../catalog/tree_edit_prompts.dart';
import '../maintenance/maintenance_repository.dart';
import '../edit_drafts/edit_drafts.dart';
import '../edit_drafts/edit_draft_widgets.dart';
import '../pin/pin_gate.dart';
import 'job_line_qty.dart';
import 'jobs_repository.dart';

class JobLineEditor extends StatefulWidget {
  const JobLineEditor({required this.jobId, this.lineId, super.key});

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
  String? _customNotes;
  String? _uom;
  String? _notes;
  String _pickLabel = 'Pick from catalog tree';
  final List<_SplitDraft> _splits = [];

  bool _useCustom = false;
  bool _catalogPartMissing = false;
  bool _loading = true;
  bool _saving = false;
  bool _initialized = false;
  String? _lineId;

  EditDrafts? _edits;
  JobLineEditSession? _session;
  EditOpening<JobLineEditSession>? _opening;
  JobLinePromoted? _promotionReceipt;
  bool _applyingInput = false;
  bool _allowPop = false;
  String? _catalogNameNotice;

  bool get _isEditing => _lineId != null;

  void _capture() {
    if (_loading || _applyingInput) return;
    _session?.replace(
      JobLineInput(
        useCustom: _useCustom,
        partId: _partId,
        brandVersionId: _brandVersionId,
        customNameText: _customNameController.text,
        neededText: _neededController.text,
        pullText: _pullController.text,
        customNotes: _customNotes,
        uom: _uom,
        notes: _notes,
        splits: [
          for (final split in _splits)
            SplitInput(
              supplierId: split.supplierId,
              quantityText: split.qtyController.text,
            ),
        ],
      ),
    );
  }

  void _change(VoidCallback change) {
    setState(change);
    _capture();
  }

  _SplitDraft _watchSplit(_SplitDraft split) {
    split.qtyController.addListener(_capture);
    return split;
  }

  Future<void> _useSession(JobLineEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    final input = session.initial;
    setState(() {
      _session = session;
      _opening = null;
    });
    _applyRaw(input);
    final partId = input.partId;
    final storedPart = partId == null
        ? null
        : await _catalog.getPart(partId, includeDeleted: true);
    final versions = partId == null
        ? <BrandVersion>[]
        : await _catalog.listBrandVersionsForPart(
            partId,
            includeDeleted: storedPart?.deletedAt != null,
          );
    if (!mounted) return;
    setState(() {
      _brandVersions = versions;
      _catalogPartMissing =
          partId != null &&
          (storedPart == null || storedPart.deletedAt != null);
      _refreshPickLabel();
    });
    await _refreshSupplierChoices(preserveExistingSplits: true);
  }

  void _applyRaw(JobLineInput input) {
    _applyingInput = true;
    setState(() {
      _useCustom = input.useCustom;
      _partId = input.partId;
      _brandVersionId = input.brandVersionId;
      _customNameController.text = input.customNameText;
      _neededController.text = input.neededText;
      _pullController.text = input.pullText;
      _customNotes = input.customNotes;
      _uom = input.uom;
      _notes = input.notes;
      for (final split in _splits) {
        split.dispose();
      }
      _splits
        ..clear()
        ..addAll(
          input.splits.map(
            (split) => _watchSplit(
              _SplitDraft(
                supplierId: split.supplierId,
                qty: split.quantityText,
              ),
            ),
          ),
        );
    });
    _applyingInput = false;
  }

  Future<void> _presentPromotion(JobLinePromoted receipt) async {
    if (!mounted) return;
    setState(() {
      _saving = true;
      _loading = false;
      _session = null;
      _opening = null;
      _promotionReceipt = receipt;
      _lineId = receipt.lineId;
      _pickLabel = receipt.name;
    });
    _applyRaw(receipt.continuation);
    try {
      final parts = await _catalog.listParts(
        activeOnly: false,
        includeDeleted: true,
      );
      final tree = buildCatalogTree(
        await _catalog.loadTreeSnapshot(activeOnly: true),
      );
      if (!mounted) return;
      setState(() {
        _parts = parts;
        _tree = tree;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final session = await receipt.acknowledgeAndContinue();
      if (!mounted) {
        await session.leave(LeaveIntent.back);
        return;
      }
      await _useSession(session);
      if (mounted) {
        setState(() => _promotionReceipt = null);
        _toast('On this job as a catalog part. Back out when you are done.');
      }
    } catch (error) {
      if (mounted) _toast('Part saved. Could not continue editing. $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openDraft() async {
    final edits = _edits;
    if (edits == null) return;
    if (mounted) setState(() => _loading = true);
    final opening = await edits.openJobLine(widget.jobId, lineId: _lineId);
    if (!mounted) {
      if (opening is FreshEdit<JobLineEditSession>) {
        await opening.session.leave(LeaveIntent.back);
      }
      return;
    }
    if (opening is FreshEdit<JobLineEditSession>) {
      await _useSession(opening.session);
    } else if (opening is JobLinePromoted) {
      await _presentPromotion(opening);
    } else {
      setState(() => _opening = opening);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<JobLineEditSession> opening:
        await opening.discard();
      case BlockedEdit<JobLineEditSession> opening:
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
      _customNameController,
      _neededController,
      _pullController,
    ]) {
      controller.addListener(_capture);
    }
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
    final parts = await _catalog.listParts(
      activeOnly: false,
      includeDeleted: true,
    );
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
        _customNotes = line.customNotes;
        _uom = line.uom;
        _notes = line.notes;
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
    Part? storedPart;
    if (partId != null) {
      storedPart = await _catalog.getPart(partId, includeDeleted: true);
      versions = await _catalog.listBrandVersionsForPart(
        partId,
        includeDeleted: storedPart?.deletedAt != null,
      );
    }
    final catalogPartMissing =
        partId != null && (storedPart == null || storedPart.deletedAt != null);

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
      _catalogPartMissing = catalogPartMissing;
      _customNameController.text = customName;
      _neededController.text = needed;
      _pullController.text = pull;
      _brandVersions = versions;
      _splits
        ..clear()
        ..addAll(splitDrafts.map(_watchSplit));
      _loading = _edits != null;
    });
    _refreshPickLabel();
    await _refreshSupplierChoices(preserveExistingSplits: true);
    await _openDraft();
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
    String? versionLabel;
    if (_brandVersionId != null) {
      BrandVersion? version;
      for (final v in _brandVersions) {
        if (v.id == _brandVersionId) {
          version = v;
          break;
        }
      }
      if (version != null) {
        versionLabel = _brandVersionLabel(version);
      }
    }
    _pickLabel = jobLineCatalogPickLabel(
      name: name,
      brandVersionLabel: versionLabel,
      removedFromCatalog: _catalogPartMissing,
    );
  }

  Future<void> _applyPick(CatalogTreePick pick) async {
    final versions = await _catalog.listBrandVersionsForPart(pick.partId);
    if (!mounted) return;
    _change(() {
      _useCustom = false;
      _partId = pick.partId;
      _brandVersionId = pick.brandVersionId;
      _brandVersions = versions;
      _catalogPartMissing = false;
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

  Future<void> _refreshSupplierChoices({
    bool preserveExistingSplits = false,
  }) async {
    final keepSplits =
        _edits != null || preserveExistingSplits || _catalogPartMissing;
    List<Supplier> choices;
    if (_catalogPartMissing) {
      choices = List.of(_allSuppliers);
    } else if (_brandVersionId != null) {
      final listings = await _catalog.listingsForBrandVersion(_brandVersionId!);
      final ids = jobLineEditorSupplierIds(
        listingSupplierIds: listings.map((l) => l.supplierId),
        existingSplitSupplierIds: _splits.map((s) => s.supplierId),
        preserveExistingSplits: keepSplits,
      );
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
      if (keepSplits) return;
      final allowed = choices.map((s) => s.id).toSet();
      for (final split in _splits) {
        if (split.supplierId != null && !allowed.contains(split.supplierId)) {
          split.supplierId = null;
        }
      }
    });
  }

  void _addSplit() {
    _change(() => _splits.add(_watchSplit(_SplitDraft())));
  }

  Future<void> _addSupplierForSplit(_SplitDraft split) async {
    final scope = AppScope.of(context);
    if (!await ensurePinUnlocked(context, scope.pin) || !mounted) return;
    final session = _session;
    final partId = _partId;
    final versionId = _brandVersionId;
    final useCustom = _useCustom;
    final partMissing = _catalogPartMissing;
    final lineId = _lineId;
    void requireConsumer() {
      if (!mounted ||
          _loading ||
          _saving ||
          _opening != null ||
          session == null ||
          !identical(_session, session) ||
          session.status.value.phase == EditPhase.closed ||
          !_splits.contains(split) ||
          _partId != partId ||
          _brandVersionId != versionId ||
          _useCustom != useCustom ||
          _catalogPartMissing != partMissing ||
          _lineId != lineId) {
        throw StateError(
          'The supplier split consumer changed or is unavailable',
        );
      }
    }

    try {
      requireConsumer();
      setState(() => _catalogNameNotice = null);
      await showCatalogNameDialog(
        context,
        target: !useCustom && versionId != null && !partMissing
            ? CatalogNameTarget.newSupplierForVersion(versionId)
            : CatalogNameTarget.newSupplier(),
        title: 'Add supplier',
        onSaved: (saved) async {
          requireConsumer();
          final activeSession = session!;
          final suppliers = await _db.taxonomyDao.listSuppliers();
          requireConsumer();
          if (saved.kind != CatalogNameKind.supplier ||
              !suppliers.any(
                (supplier) =>
                    supplier.id == saved.id && supplier.name == saved.name,
              )) {
            throw StateError('The saved supplier is not in the refreshed list');
          }
          _allSuppliers = suppliers;
          await _refreshSupplierChoices();
          requireConsumer();
          if (!_supplierChoices.any(
            (supplier) =>
                supplier.id == saved.id && supplier.name == saved.name,
          )) {
            throw StateError(
              'The saved supplier is not selectable for this split',
            );
          }
          _change(() => split.supplierId = saved.id);
          final index = _splits.indexOf(split);
          if (activeSession.initial.splits.length != _splits.length ||
              activeSession.initial.splits[index].supplierId != saved.id) {
            throw StateError('The supplier selection was not captured');
          }
          await activeSession.flush();
          requireConsumer();
          final status = activeSession.status.value;
          if (status.phase != EditPhase.durable ||
              status.durableSequence != status.latestSequence ||
              activeSession.initial.splits[index].supplierId != saved.id) {
            throw StateError('The supplier split selection is not durable yet');
          }
        },
        onNotice: (message) {
          if (mounted) setState(() => _catalogNameNotice = message);
        },
      );
    } catch (error) {
      if (mounted) setState(() => _catalogNameNotice = '$error');
    }
  }

  void _removeSplit(int index) {
    if (_splits.length <= 1) return;
    _change(() {
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
      final session = _session;
      if (session == null) {
        await _jobs.removeLine(_lineId!);
      } else {
        await session.remove();
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      _toast('Remove failed: $e');
      setState(() => _saving = false);
    }
  }

  ({
    double neededQty,
    double shopPullQty,
    List<({String supplierId, double qty})> splits,
  })?
  _validatedQuantities() {
    final needed = double.tryParse(_neededController.text.trim());
    final pull = double.tryParse(_pullController.text.trim());
    if (needed == null || !needed.isFinite || needed < 0) {
      _toast('Enter a valid requested quantity');
      return null;
    }
    if (pull == null || !pull.isFinite || pull < 0) {
      _toast('Enter a valid shop quantity');
      return null;
    }

    final splits = <({String supplierId, double qty})>[];
    for (final draft in _splits) {
      final qtyText = draft.qtyController.text.trim();
      if (draft.supplierId == null && qtyText.isEmpty) continue;
      if (draft.supplierId == null) {
        _toast('Each order split needs a supplier');
        return null;
      }
      final qty = double.tryParse(qtyText);
      if (qty == null || !qty.isFinite || qty <= 0) {
        _toast('Each order split needs a quantity > 0');
        return null;
      }
      splits.add((supplierId: draft.supplierId!, qty: qty));
    }

    return (neededQty: needed, shopPullQty: pull, splits: splits);
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    final quantities = _validatedQuantities();
    if (quantities == null) return;

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

    setState(() => _saving = true);
    try {
      final session = _session;
      if (session != null) {
        _lineId = await session.save();
      } else if (_isEditing) {
        await _jobs.updateLine(
          lineId: _lineId!,
          partId: partId,
          brandVersionId: brandVersionId,
          customName: customName,
          customNotes: _customNotes,
          uom: _uom,
          notes: _notes,
          neededQty: quantities.neededQty,
          shopPullQty: quantities.shopPullQty,
          splits: quantities.splits,
        );
      } else {
        await _jobs.addLine(
          jobId: widget.jobId,
          partId: partId,
          brandVersionId: brandVersionId,
          customName: customName,
          neededQty: quantities.neededQty,
          shopPullQty: quantities.shopPullQty,
          splits: quantities.splits,
        );
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      _toast('Save failed: $e');
      setState(() => _saving = false);
    }
  }

  Future<void> _promoteToCatalog() async {
    if (_saving || _loading) return;
    _capture();
    if (_customNameController.text.trim().isEmpty) {
      _toast('Custom name is required');
      return;
    }
    if (_validatedQuantities() == null) return;
    final session = _session;
    if (session == null) {
      _toast(
        'Unfinished edits are unavailable. Your input remains in this form.',
      );
      return;
    }
    final scope = AppScope.of(context);
    if (!await ensurePinUnlocked(context, scope.pin) || !mounted) return;
    try {
      final promotion = await session.openPromotion();
      if (!mounted) return;
      final result = await showJobLinePromotionDialog(
        context,
        promotion: promotion,
        maintenance: _maintenance,
      );
      if (result != null && mounted) await _presentPromotion(result);
    } catch (error) {
      if (mounted) _toast('Could not open promotion. $error');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
          title: Text(_isEditing ? 'Edit line' : 'Add line'),
          actions: [
            if (_session != null)
              TextButton(
                onPressed: _saving ? null : () => _leave(LeaveIntent.discard),
                child: const Text('Discard'),
              ),
            if (_isEditing && _opening == null && _promotionReceipt == null)
              TextButton(
                onPressed: _saving || _loading ? null : _removeLine,
                child: const Text('Remove'),
              ),
            if (_opening == null && _promotionReceipt == null)
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
            : _opening != null
            ? EditOpeningPanel<JobLineEditSession>(
                opening: _opening!,
                onResume: _useSession,
                onDiscard: _discardRecovery,
              )
            : _promotionReceipt != null
            ? Column(
                children: [
                  Text('Part saved: ${_promotionReceipt!.name}'),
                  Text(
                    'Requested: ${_neededController.text}, From shop: ${_pullController.text}',
                  ),
                  FilledButton(
                    onPressed: _saving
                        ? null
                        : () => _presentPromotion(_promotionReceipt!),
                    child: const Text('Continue editing'),
                  ),
                ],
              )
            : AbsorbPointer(
                absorbing: _saving,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_session case final session?)
                      EditStatusBanner(status: session.status),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('Catalog part'),
                        ),
                        ButtonSegment(value: true, label: Text('Custom')),
                      ],
                      selected: {_useCustom},
                      onSelectionChanged: _saving
                          ? null
                          : (sel) async {
                              final custom = sel.first;
                              _change(() {
                                _useCustom = custom;
                                if (custom) {
                                  _partId = null;
                                  _brandVersionId = null;
                                  _brandVersions = [];
                                  _catalogPartMissing = false;
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
                          onPressed: _saving || _loading
                              ? null
                              : _promoteToCatalog,
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
                      if (_partId != null && !_catalogPartMissing)
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
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.-]'),
                              ),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Requested',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _pullController,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.-]'),
                              ),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Shop',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
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
                                if (split.supplierId != null &&
                                    !_supplierChoices.any(
                                      (s) => s.id == split.supplierId,
                                    ))
                                  DropdownMenuItem(
                                    value: split.supplierId,
                                    child: Text(
                                      'Unavailable supplier (${split.supplierId})',
                                    ),
                                  ),
                                for (final s in _supplierChoices)
                                  DropdownMenuItem(
                                    value: s.id,
                                    child: Text(s.name),
                                  ),
                              ],
                              onChanged: (v) {
                                _change(() => split.supplierId = v);
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
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'[0-9.-]'),
                                      ),
                                    ],
                                    decoration: const InputDecoration(
                                      labelText: 'Qty',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
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
              ),
      ),
    );
  }

  static String _qtyText(double v) => formatQty(v);
}
