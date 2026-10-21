import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/new_id.dart';
import '../../data/app_database.dart';
import '../catalog/catalog_tree.dart';
import '../catalog/catalog_tree_picker.dart';
import '../catalog/tree_edit_prompts.dart';
import '../pin/pin_gate.dart';
import 'warehouse_repository.dart';

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
    try {
      final head = await _repo.latestCount(_location.id, part.id);
      if (!mounted) return;
      final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CountDialog(
          repo: _repo,
          locationId: _location.id,
          part: part,
          head: head,
        ),
      );
      if (!mounted) return;
      if (saved == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Count saved')));
        _reload();
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

class _CountDialog extends StatefulWidget {
  const _CountDialog({
    required this.repo,
    required this.locationId,
    required this.part,
    required this.head,
  });
  final WarehouseRepository repo;
  final String locationId;
  final Part part;
  final WarehouseCount? head;

  @override
  State<_CountDialog> createState() => _CountDialogState();
}

class _CountDialogState extends State<_CountDialog> {
  final _quantityController = TextEditingController();
  final _noteController = TextEditingController();
  final _requestId = newId();
  var _observedAt = DateTime.now();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _quantityController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _chooseTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _observedAt,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_observedAt),
    );
    if (time == null || !mounted) return;
    setState(
      () => _observedAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  Future<void> _save() async {
    if (_busy) return;
    final quantity = double.tryParse(_quantityController.text.trim());
    if (quantity == null || !quantity.isFinite || quantity < 0) {
      setState(
        () => _error = 'Enter a finite, nonnegative quantity. Zero is a count.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repo.recordCount(
        WarehouseCountDraft(
          id: _requestId,
          locationId: widget.locationId,
          partId: widget.part.id,
          expectedPriorCountId: widget.head?.id,
          quantity: quantity,
          uom: widget.part.uom,
          observedAt: _observedAt,
          note: _noteController.text,
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text('Count ${widget.part.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.head == null
                    ? 'Not counted'
                    : 'Previous observation: ${_quantity(widget.head!.quantity)} ${widget.head!.uom}',
              ),
              Text(
                'Record the absolute physical quantity in ${widget.part.uom}. No conversion is applied.',
              ),
              TextField(
                controller: _quantityController,
                enabled: !_busy,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Count quantity'),
              ),
              TextButton(
                onPressed: _busy ? null : _chooseTime,
                child: Text('Observed ${_stamp(_observedAt)}'),
              ),
              TextField(
                controller: _noteController,
                enabled: !_busy,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Count note'),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save count'),
        ),
      ],
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
