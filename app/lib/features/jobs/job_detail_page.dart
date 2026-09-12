import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import 'job_line_editor.dart';
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
    final parts = await scope.db.partsDao.listParts();
    final partNames = {for (final p in parts) p.id: p.name};

    final rows = <_LineRow>[];
    for (final line in lines) {
      final splits = await _jobs.orderSplitsForLine(line.id);
      final ordered = splits.fold<double>(0, (a, s) => a + s.quantity);
      final label = line.customName?.trim().isNotEmpty == true
          ? line.customName!
          : (line.partId != null
              ? (partNames[line.partId!] ?? 'Unknown part')
              : 'Untitled line');
      rows.add(
        _LineRow(
          line: line,
          label: label,
          orderedQty: ordered,
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
                      subtitle: Text(
                        'Needed ${_fmt(line.neededQty)}'
                        ' · Pull ${_fmt(line.shopPullQty)}'
                        ' · Ordered ${_fmt(row.orderedQty)}',
                      ),
                      onTap: () => _openEditor(lineId: line.id),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        tooltip: 'Add line',
        child: const Icon(Icons.add),
      ),
    );
  }

  static String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }
}

class _LineRow {
  _LineRow({
    required this.line,
    required this.label,
    required this.orderedQty,
  });

  final JobLine line;
  final String label;
  final double orderedQty;
}
