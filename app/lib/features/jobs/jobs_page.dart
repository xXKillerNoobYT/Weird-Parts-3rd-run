import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/app_database.dart';
import '../edit_drafts/edit_drafts.dart';
import 'job_detail_page.dart';
import 'jobs_repository.dart';
import 'new_job_dialog.dart';

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
    if (!mounted) return;
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
    final edits = AppScope.of(context).edits;
    if (edits == null) {
      _showWriteRefusal(StateError('Unfinished edits are unavailable'));
      return;
    }
    final created = await showDialog<NewJobCreated>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => NewJobDialog(edits: edits),
    );
    if (created == null) return;
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    final detailRoute = Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => JobDetailPage(jobId: created.id)),
    );
    await WidgetsBinding.instance.endOfFrame;
    try {
      await created.acknowledge();
    } catch (_) {
      _showWriteRefusal(
        StateError('Job saved. Its completion confirmation is still pending.'),
      );
    }
    await detailRoute;
    await _reload();
  }

  Future<void> _archive(Job job) async {
    try {
      await _jobs.archiveJob(job.id);
    } on StateError catch (error) {
      _showWriteRefusal(error);
      return;
    }
    await _reload();
  }

  void _showWriteRefusal(StateError error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.message.toString())));
  }

  Future<void> _openJob(Job job) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => JobDetailPage(jobId: job.id)),
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
