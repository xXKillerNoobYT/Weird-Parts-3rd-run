import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import 'job_detail_page.dart';
import 'jobs_repository.dart';

class JobsPage extends StatefulWidget {
  const JobsPage({super.key});

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  final _searchController = TextEditingController();
  late final JobsRepository _jobs;
  List<Job> _jobsList = [];
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final all = await _jobs.listActiveJobs();
    if (!mounted) return;
    setState(() {
      _jobsList = all;
      _loading = false;
    });
  }

  List<Job> get _filtered {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _jobsList;
    return _jobsList
        .where(
          (j) =>
              j.name.toLowerCase().contains(q) ||
              (j.jobNumber?.toLowerCase().contains(q) ?? false),
        )
        .toList(growable: false);
  }

  Future<void> _createJob() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _NewJobNameDialog(),
    );
    if (name == null || name.isEmpty) return;

    final id = await _jobs.createJob(name);
    await _reload();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JobDetailPage(jobId: id),
      ),
    );
    await _reload();
  }

  Future<void> _archive(Job job) async {
    await _jobs.archiveJob(job.id);
    await _reload();
  }

  Future<void> _openJob(Job job) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JobDetailPage(jobId: job.id),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(title: const Text('Jobs')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search jobs',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? Center(
                        child: Text(
                          _searchController.text.trim().isEmpty
                              ? 'No active jobs'
                              : 'No jobs match your search',
                        ),
                      )
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final job = items[index];
                          return Dismissible(
                            key: ValueKey(job.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              color: Theme.of(context).colorScheme.error,
                              child: Icon(
                                Icons.archive,
                                color: Theme.of(context).colorScheme.onError,
                              ),
                            ),
                            confirmDismiss: (_) async {
                              await _archive(job);
                              return false;
                            },
                            child: ListTile(
                              title: Text(job.name),
                              subtitle: job.jobNumber != null
                                  ? Text(job.jobNumber!)
                                  : null,
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'archive') _archive(job);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'archive',
                                    child: Text('Archive'),
                                  ),
                                ],
                              ),
                              onTap: () => _openJob(job),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'jobs-fab',
        onPressed: _createJob,
        tooltip: 'New job',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Owns its [TextEditingController] so it is not disposed while the dialog
/// route is still animating out (that corrupts overlays / job detail chrome).
class _NewJobNameDialog extends StatefulWidget {
  const _NewJobNameDialog();

  @override
  State<_NewJobNameDialog> createState() => _NewJobNameDialogState();
}

class _NewJobNameDialogState extends State<_NewJobNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (v.isEmpty) return;
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New job'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'Job name',
        ),
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
