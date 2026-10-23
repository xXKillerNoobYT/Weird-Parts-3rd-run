import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../maintenance/maintenance_repository.dart';
import '../edit_drafts/edit_drafts.dart';
import '../edit_drafts/edit_draft_widgets.dart';
import '../pin/pin_gate.dart';
import 'catalog_name_dialog.dart';
import 'tree_edit_prompts.dart';

class PartDetails {
  const PartDetails({
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

Future<NewPartCreated?> showNewPartDialog(
  BuildContext context, {
  required MaintenanceRepository maintenance,
  String? initialCategoryId,
  String? initialStyleId,
  String? initialTypeId,
}) {
  final edits = AppScope.of(context).edits;
  if (edits == null) throw StateError('Unfinished edits are unavailable');
  return showDialog<NewPartCreated>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PartDetailsDialog._newPart(
      maintenance: maintenance,
      edits: edits,
      initialCategoryId: initialCategoryId,
      initialStyleId: initialStyleId,
      initialTypeId: initialTypeId,
    ),
  );
}

final class _NewPartPurpose {
  const _NewPartPurpose(this.edits);
  final EditDrafts edits;
}

class PartDetailsDialog extends StatefulWidget {
  const PartDetailsDialog({
    this.initialName = '',
    this.initialCategoryId,
    this.initialStyleId,
    this.initialTypeId,
    this.title = 'New part',
    this.submitLabel = 'Save',
    this.introduction =
        'Choose a Category, Type, and Variant before saving the part.',
    required this.maintenance,
    super.key,
  }) : _newPart = null;

  PartDetailsDialog._newPart({
    required this.maintenance,
    required EditDrafts edits,
    this.initialCategoryId,
    this.initialStyleId,
    this.initialTypeId,
  }) : initialName = '',
       title = 'New part',
       submitLabel = 'Save',
       introduction =
           'Choose a Category, Type, and Variant before saving the part.',
       _newPart = _NewPartPurpose(edits);

  final _NewPartPurpose? _newPart;
  final String initialName;
  final String? initialCategoryId;
  final String? initialStyleId;
  final String? initialTypeId;
  final String title;
  final String submitLabel;
  final String introduction;
  final MaintenanceRepository maintenance;

  @override
  State<PartDetailsDialog> createState() => _PartDetailsDialogState();
}

class _PartDetailsDialogState extends State<PartDetailsDialog> {
  late final TextEditingController _name;
  List<Category> _categories = [];
  List<Style> _styles = [];
  List<Type> _variants = [];
  String? _categoryId;
  String? _styleId;
  String? _typeId;
  String? _error;
  String? _notice;
  bool _loading = true;
  bool _busy = false;
  bool _allowPop = false;
  bool _applyingInput = false;
  NewPartEditSession? _session;
  EditOpening<NewPartEditSession>? _opening;
  NewPartCreated? _saved;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _categoryId = widget.initialCategoryId;
    _styleId = widget.initialStyleId;
    _typeId = widget.initialTypeId;
    _name.addListener(_capture);
    if (widget._newPart != null) {
      _openDraft();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _name.removeListener(_capture);
    final session = _session;
    if (session != null) {
      unawaited(session.leave(LeaveIntent.back).catchError((Object _) {}));
    }
    _name.dispose();
    super.dispose();
  }

  void _capture() {
    if (_applyingInput) return;
    _session?.replace(
      NewPartInput(
        nameText: _name.text,
        categoryId: _categoryId,
        styleId: _styleId,
        typeId: _typeId,
      ),
    );
  }

  Future<void> _openDraft() async {
    setState(() => _loading = true);
    try {
      final opening = await widget._newPart!.edits.openNewPart(
        initialCategoryId: widget.initialCategoryId,
        initialStyleId: widget.initialStyleId,
        initialTypeId: widget.initialTypeId,
      );
      if (!mounted) {
        if (opening is FreshEdit<NewPartEditSession>) {
          await opening.session.leave(LeaveIntent.back);
        }
        return;
      }
      if (opening is FreshEdit<NewPartEditSession>) {
        await _useSession(opening.session);
      } else if (opening is NewPartCreated) {
        setState(() => _saved = opening);
      } else {
        setState(() => _opening = opening);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is StateError ? error.message : '$error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useSession(NewPartEditSession session) async {
    if (!mounted) {
      await session.leave(LeaveIntent.back);
      return;
    }
    _applyingInput = true;
    setState(() {
      _session = session;
      _opening = null;
      _saved = null;
      _name.text = session.initial.nameText;
      _categoryId = session.initial.categoryId;
      _styleId = session.initial.styleId;
      _typeId = session.initial.typeId;
    });
    _applyingInput = false;
    await _load();
  }

  Future<void> _discardRecovery() async {
    switch (_opening) {
      case RecoverableEdit<NewPartEditSession> opening:
        await opening.discard();
      case BlockedEdit<NewPartEditSession> opening:
        await opening.discard();
      default:
        return;
    }
    if (!mounted) return;
    setState(() => _opening = null);
    await _openDraft();
  }

  Future<void> _leave(LeaveIntent intent) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_session case final session?) {
        await session.leave(intent);
      } else if (intent == LeaveIntent.discard && _saved == null) {
        switch (_opening) {
          case RecoverableEdit<NewPartEditSession> opening:
            await opening.discard();
          case BlockedEdit<NewPartEditSession> opening:
            await opening.discard();
          default:
            break;
        }
      }
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is StateError ? error.message : '$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish(NewPartCreated saved) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop<NewPartCreated>(saved);
  }

  String? get _hierarchyError {
    if (_categoryId != null && !_categories.any((c) => c.id == _categoryId)) {
      return 'The selected Category is unavailable. Your selection is preserved.';
    }
    if (_styleId != null && !_typesForCat.any((s) => s.id == _styleId)) {
      return 'The selected Type is unavailable or belongs to another Category. Your selection is preserved.';
    }
    if (_typeId != null && !_variantsForType.any((t) => t.id == _typeId)) {
      return 'The selected Variant is unavailable or belongs to another Type. Your selection is preserved.';
    }
    return null;
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
      if (widget._newPart == null) {
        if (!cats.any((c) => c.id == _categoryId)) _categoryId = null;
        if (!styles.any(
          (s) => s.id == _styleId && s.categoryId == _categoryId,
        )) {
          _styleId = null;
        }
        if (!variants.any((t) => t.id == _typeId && t.styleId == _styleId)) {
          _typeId = null;
        }
      }
      _loading = false;
    });
  }

  Future<void> _addCategory() async {
    if (!await _gate() || !mounted) return;
    await _editTaxonomyName(CatalogNameTarget.newCategory(), 'Add category');
  }

  Future<void> _addType() async {
    if (_categoryId == null) {
      setState(() => _error = 'Set Category first');
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
      setState(() => _error = 'Set Type first');
      return;
    }
    if (!await _gate() || !mounted) return;
    await _editTaxonomyName(
      CatalogNameTarget.newVariant(_styleId!),
      'Add variant',
    );
  }

  Future<void> _editTaxonomyName(CatalogNameTarget target, String title) async {
    try {
      await showCatalogNameDialog(
        context,
        target: target,
        title: title,
        onSaved: (saved) async {
          if (saved.kind == CatalogNameKind.brand ||
              saved.kind == CatalogNameKind.supplier) {
            throw StateError(
              'A brand or supplier cannot change the part taxonomy',
            );
          }
          await _load();
          if (!mounted) {
            throw StateError('Part details are no longer available');
          }
          setState(() {
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
            _error = null;
          });
          _capture();
          await _session?.flush();
        },
        onNotice: (message) {
          if (mounted) setState(() => _notice = message);
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is StateError ? error.message : '$error');
      }
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    _capture();
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Part name is required');
      return;
    }
    if (_categoryId == null || _styleId == null || _typeId == null) {
      setState(() => _error = 'Category, Type, and Variant are required');
      return;
    }
    if (widget._newPart != null) {
      final session = _session;
      if (session == null) return;
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        _finish(await session.save());
      } catch (error) {
        if (mounted) {
          setState(
            () => _error = error is StateError ? error.message : '$error',
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    Navigator.pop(
      context,
      PartDetails(
        name: name,
        categoryId: _categoryId!,
        styleId: _styleId!,
        typeId: _typeId!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: widget._newPart == null || _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(LeaveIntent.back);
      },
      child: AlertDialog(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _notice!,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: _loading
              ? const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                )
              : _opening != null
              ? SizedBox(
                  height: 260,
                  child: EditOpeningPanel<NewPartEditSession>(
                    opening: _opening!,
                    onResume: _useSession,
                    onDiscard: _discardRecovery,
                  ),
                )
              : _saved != null
              ? Text('Part saved: ${_saved!.name}')
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_session case final session?)
                        EditStatusBanner(status: session.status),
                      Text(widget.introduction),
                      if (widget._newPart != null && _hierarchyError != null)
                        Text(_hierarchyError!),
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
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Part name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TaxonomyPickField(
                        label: 'Category',
                        value: _categoryId,
                        enabled: !_busy,
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
                          _capture();
                        }),
                        onAdd: _busy ? null : _addCategory,
                      ),
                      TaxonomyPickField(
                        label: 'Type',
                        value: _styleId,
                        enabled:
                            !_busy &&
                            _categories.any((c) => c.id == _categoryId),
                        addLabel: 'Add Type',
                        items: [
                          for (final s in _typesForCat)
                            DropdownMenuItem(value: s.id, child: Text(s.name)),
                        ],
                        onChanged: (v) => setState(() {
                          _styleId = v;
                          _typeId = null;
                          _error = null;
                          _capture();
                        }),
                        onAdd: _busy ? null : _addType,
                      ),
                      TaxonomyPickField(
                        label: 'Variant',
                        value: _typeId,
                        enabled:
                            !_busy && _typesForCat.any((s) => s.id == _styleId),
                        addLabel: 'Add Variant',
                        items: [
                          for (final t in _variantsForType)
                            DropdownMenuItem(value: t.id, child: Text(t.name)),
                        ],
                        onChanged: (v) => setState(() {
                          _typeId = v;
                          _error = null;
                          _capture();
                        }),
                        onAdd: _busy ? null : _addVariant,
                      ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: _busy || _loading
                ? null
                : widget._newPart == null
                ? () => Navigator.pop(context)
                : () => _leave(
                    _saved == null ? LeaveIntent.discard : LeaveIntent.back,
                  ),
            child: Text(_saved == null ? 'Cancel' : 'Close'),
          ),
          if (_saved case final saved?)
            FilledButton(
              onPressed: _busy ? null : () => _finish(saved),
              child: const Text('Done'),
            )
          else if (_opening == null)
            FilledButton(
              onPressed:
                  _loading ||
                      _busy ||
                      (widget._newPart != null && _session == null)
                  ? null
                  : _submit,
              child: Text(widget.submitLabel),
            ),
        ],
      ),
    );
  }
}
