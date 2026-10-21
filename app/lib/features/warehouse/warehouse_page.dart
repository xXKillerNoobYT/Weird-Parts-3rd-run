import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/new_id.dart';
import '../../data/app_database.dart';
import '../catalog/catalog_tree.dart';
import '../catalog/catalog_tree_picker.dart';
import '../edit_drafts/edit_drafts.dart';
import '../catalog/tree_edit_prompts.dart';
import '../pin/pin_gate.dart';
import 'warehouse_repository.dart';
import 'warehouse_count_dialog.dart';

class WarehousePage extends StatefulWidget {
  const WarehousePage({super.key});

  @override
  State<WarehousePage> createState() => _WarehousePageState();
}

class _WarehousePageState extends State<WarehousePage> {
  late WarehouseRepository _repo;
  Future<List<WarehouseLocation>>? _locations;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _repo = WarehouseRepository(scope.db, scope.pin, scope.deviceId);
    _locations ??= _repo.loadLocations();
  }

  Future<void> _add() async {
    if (!await ensurePinUnlocked(context, AppScope.of(context).pin)) return;
    if (!mounted) return;
    final name = await promptName(context, title: 'New warehouse');
    if (name == null) return;
    try {
      await _repo.createLocation(id: newId(), name: name);
      if (mounted) {
        setState(() {
          _locations = _repo.loadLocations();
        });
      }
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Inventory / Warehouses')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _add,
      icon: const Icon(Icons.add),
      label: const Text('New warehouse'),
    ),
    body: FutureBuilder<List<WarehouseLocation>>(
      future: _locations,
      builder: (context, snap) {
        if (snap.hasError) {
          return _loadError(
            () => setState(() {
              _locations = _repo.loadLocations();
            }),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.data!.isEmpty) {
          return const Center(
            child: Text('No warehouses yet. Add a location to start counting.'),
          );
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 90),
          children: [
            for (final row in snap.data!)
              ListTile(
                leading: const Icon(Icons.warehouse_outlined),
                title: Text(row.name),
                subtitle: const Text('Physical counts and history'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _LocationPage(location: row),
                    ),
                  );
                  if (mounted) {
                    setState(() {
                      _locations = _repo.loadLocations();
                    });
                  }
                },
              ),
          ],
        );
      },
    ),
  );
}

class _LocationPage extends StatefulWidget {
  const _LocationPage({required this.location});
  final WarehouseLocation location;

  @override
  State<_LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<_LocationPage> {
  late WarehouseLocation _location = widget.location;
  late WarehouseRepository _repo;
  Future<List<WarehouseStock>>? _stock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _repo = WarehouseRepository(scope.db, scope.pin, scope.deviceId);
    _stock ??= _repo.loadLatestCounts(_location.id);
  }

  void _reload() {
    final stock = _repo.loadLatestCounts(_location.id);
    stock.ignore();
    setState(() {
      _stock = stock;
    });
  }

  Future<void> _rename() async {
    if (!await ensurePinUnlocked(context, AppScope.of(context).pin)) return;
    if (!mounted) return;
    final name = await promptName(
      context,
      title: 'Rename warehouse',
      initial: _location.name,
    );
    if (name == null) return;
    try {
      await _repo.renameLocation(
        id: _location.id,
        expectedRevision: _location.revision,
        name: name,
      );
      if (!mounted) return;
      final changed = name.trim() != _location.name;
      setState(
        () => _location = _location.copyWith(
          name: name.trim(),
          revision: _location.revision + (changed ? 1 : 0),
        ),
      );
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  Future<void> _pickPart() async {
    try {
      final tree = buildCatalogTree(await _repo.loadPartChoices());
      if (!mounted) return;
      final pick = await pickFromCatalogTree(context, tree: tree);
      if (pick == null || !mounted) return;
      final part = await _repo.loadPart(pick.partId);
      if (part == null) throw StateError('Part is no longer in the catalog');
      await _count(part);
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  Future<void> _count(Part part) async {
    if (!await ensurePinUnlocked(context, AppScope.of(context).pin)) return;
    if (!mounted) return;
    try {
      final scope = AppScope.of(context);
      final edits = scope.edits;
      if (edits == null) {
        throw StateError('Unfinished edits are unavailable');
      }
      final head = await _repo.latestCount(_location.id, part.id);
      if (!mounted) return;
      final saved = await showDialog<WarehouseCountSaved>(
        context: context,
        barrierDismissible: false,
        builder: (_) => WarehouseCountDialog(
          edits: edits,
          locationId: _location.id,
          part: part,
          head: head,
        ),
      );
      if (!mounted) return;
      if (saved != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Count saved')),
        );
        _reload();
        await WidgetsBinding.instance.endOfFrame;
        try {
          await saved.acknowledge();
        } catch (error) {
          if (mounted) {
            _showError(
              context,
              'Count saved. Confirmation remains pending: $error',
            );
          }
        }
      }
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  Future<void> _history(WarehouseStock row) async {
    try {
      final history = await _repo.loadCountHistory(_location.id, row.part.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${row.part.name} count history'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final count in history)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Text(
                        '${_quantity(count.quantity)} ${count.uom}\n'
                        'Observed ${_stamp(count.observedAt)}\n'
                        'Recorded ${_stamp(count.recordedAt)}\n'
                        'Device ${count.originDeviceId}'
                        '${count.note.isEmpty ? '' : '\n${count.note}'}',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_location.name),
      actions: [
        IconButton(
          onPressed: _rename,
          tooltip: 'Rename warehouse',
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          onPressed: _reload,
          tooltip: 'Reload counts',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _pickPart,
      label: const Text('Count a part'),
      icon: const Icon(Icons.add),
    ),
    body: FutureBuilder<List<WarehouseStock>>(
      future: _stock,
      builder: (context, snap) {
        if (snap.hasError) return _loadError(_reload);
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.data!.isEmpty) {
          return const Center(
            child: Text(
              'Not counted. Choose a catalog part to record a physical count.',
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 90),
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Last physical observations. Counts do not reserve stock or change Jobs.',
              ),
            ),
            for (final row in snap.data!)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${row.part.name}${row.part.deletedAt == null ? '' : ' (removed from catalog)'}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text('${_quantity(row.count.quantity)} ${row.count.uom}'),
                      Text('Observed ${_stamp(row.count.observedAt)}'),
                      Text('Device ${row.count.originDeviceId}'),
                      if (row.needsRecount)
                        Text(
                          'Unit changed to ${row.part.uom}. Recount required; no conversion applied.',
                        ),
                      Wrap(
                        spacing: 12,
                        children: [
                          TextButton(
                            onPressed: () => _history(row),
                            child: const Text('History'),
                          ),
                          if (row.part.deletedAt == null)
                            TextButton(
                              onPressed: () => _count(row.part),
                              child: const Text('Recount'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

void _showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$error')));

Widget _loadError(VoidCallback retry) => Center(
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('Unable to load inventory. Retry to refresh.'),
      TextButton(onPressed: retry, child: const Text('Retry')),
    ],
  ),
);

String _quantity(double quantity) =>
    quantity.toString().replaceFirst(RegExp(r'\.0$'), '');
String _stamp(DateTime time) => time.toUtc().toIso8601String();
