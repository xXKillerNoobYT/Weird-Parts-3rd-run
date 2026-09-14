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
        .where((j) => j.name.toLowerCase().contains(q))
        .toList(growable: false);
  }

  Future<void> _createJob() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('New job'),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Job name',
            ),
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) {
              final v = nameController.text.trim();
              if (v.isNotEmpty) Navigator.of(ctx).pop(v);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final v = nameController.text.trim();
                if (v.isEmpty) return;
                Navigator.of(ctx).pop(v);
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    nameController.dispose();
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
                    ? const Center(child: Text('No active jobs'))
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
