import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import 'job_line_editor.dart';
import 'job_line_qty.dart';
import 'jobs_repository.dart';

class JobDetailPage extends StatefulWidget {
  const JobDetailPage({required this.jobId, super.key});

  final String jobId;

  @override
  State<JobDetailPage> createState() => _JobDetailPageState();
}

class _JobDetailPageState extends State<JobDetailPage> {
  late final JobsRepository _jobs;
  Job? _job;
  List<_LineRow> _rows = [];
  bool _loading = true;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _jobs = JobsRepository(scope.db, scope.deviceId);
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final scope = AppScope.of(context);
    final job = await _jobs.getJob(widget.jobId);
    final lines = await _jobs.listLinesForJob(widget.jobId);
    final parts = await scope.db.partsDao.listParts(
      activeOnly: false,
      includeDeleted: true,
    );
    final partNames = {for (final p in parts) p.id: p.name};

    final suppliers = await scope.db.taxonomyDao.listSuppliers();
    final supplierNames = {for (final s in suppliers) s.id: s.name};

    final rows = <_LineRow>[];
    for (final line in lines) {
      final splits = await _jobs.orderSplitsForLine(line.id);
      final label = line.customName?.trim().isNotEmpty == true
          ? line.customName!
          : (line.partId != null
              ? (partNames[line.partId!] ?? 'Unknown part')
              : 'Untitled line');
      rows.add(
        _LineRow(
          line: line,
          label: label,
          qty: JobLineQty(
            requested: line.neededQty,
            shop: line.shopPullQty,
            supplierSplits: [
              for (final s in splits)
                JobSupplierSplit(
                  supplierName: supplierNames[s.supplierId] ?? 'Supply',
                  qty: s.quantity,
                ),
            ],
          ),
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _job = job;
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _openEditor({String? lineId}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JobLineEditor(
          jobId: widget.jobId,
          lineId: lineId,
        ),
      ),
    );
    await _reload();
  }

  Future<void> _removeLine(_LineRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove line?'),
        content: Text('Remove "${row.label}" from this job?'),
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
    await _jobs.removeLine(row.line.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_job?.name ?? 'Job'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? const Center(child: Text('No parts on this job yet'))
              : ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    final line = row.line;
                    return ListTile(
                      title: Text(row.label),
                      isThreeLine: true,
                      subtitle: Text(row.qty.listSubtitle),
                      onTap: () => _openEditor(lineId: line.id),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove line',
                        onPressed: () => _removeLine(row),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'job-detail-fab',
        onPressed: () => _openEditor(),
        tooltip: 'Add line',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _LineRow {
  _LineRow({
    required this.line,
    required this.label,
    required this.qty,
  });

  final JobLine line;
  final String label;
  final JobLineQty qty;
}
