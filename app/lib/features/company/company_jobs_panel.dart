import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/app_database.dart';
import '../installation/installation_security.dart';
import '../job_line_commands/job_line_commands.dart';

class CompanyJobsPanel extends StatefulWidget {
  const CompanyJobsPanel({
    required this.commands,
    required this.owner,
    super.key,
  });
  final CompanyJobCommands commands;
  final OwnerSession owner;

  @override
  State<CompanyJobsPanel> createState() => _CompanyJobsPanelState();
}

class _CompanyJobsPanelState extends State<CompanyJobsPanel> {
  final _name = TextEditingController();
  List<Job> _jobs = const [];
  CreateJob? _pending;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _available = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jobs = await widget.commands.listJobs(ownerSession: widget.owner);
      if (!mounted || !widget.owner.isValid) return;
      setState(() {
        _jobs = jobs;
        _available = true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _jobs = const [];
        _available = false;
        _loading = false;
        _error = error is JobLineRefusal
            ? error.reason
            : 'Company Jobs are locked. Sign in again to verify authority.';
      });
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    try {
      final scope = widget.owner.identity;
      _pending ??= CreateJob(
        companyId: scope.companyId,
        shopId: scope.shopId,
        jobId: const Uuid().v4(),
        requestId: const Uuid().v4(),
        name: _name.text,
      );
    } on JobLineRefusal catch (error) {
      setState(() => _error = error.reason);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.commands.createJob(_pending!, ownerSession: widget.owner);
      final jobs = await widget.commands.listJobs(ownerSession: widget.owner);
      if (!mounted || !widget.owner.isValid) return;
      setState(() {
        _jobs = jobs;
        _pending = null;
        _name.clear();
      });
    } on CompanyJobCapacityRefusal catch (error) {
      if (mounted) {
        setState(() {
          _pending = null;
          _error = error.reason;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'This Job may already be saved. Retry to check its result.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.owner.isValid) {
      return const Text('Company Jobs are locked.');
    }
    if (_loading) {
      return const Text('Loading company Jobs...');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Company Jobs', style: TextStyle(fontSize: 20)),
        if (_available) ...[
          TextField(
            key: const Key('company-job-name'),
            controller: _name,
            enabled: !_busy && _pending == null,
            maxLength: kCompanyJobNameLimit,
            decoration: const InputDecoration(labelText: 'Job name'),
          ),
          FilledButton(
            key: const Key('company-create-job'),
            onPressed: _busy ? null : _create,
            child: Text(
              _busy
                  ? 'Saving…'
                  : _pending == null
                  ? 'Create Job'
                  : 'Retry same Job',
            ),
          ),
          const Text(
            'Jobs stay on this installation. Outgoing operations are prepared locally; delivery is pending.',
          ),
          if (_jobs.isEmpty) const Text('No company Jobs yet.'),
          Column(
            key: const Key('company-jobs-list'),
            children: [
              for (final job in _jobs)
                ListTile(
                  key: Key('company-job-${job.id}'),
                  title: Text(job.name),
                  subtitle: Text(
                    'Job ID: ${job.id}\nPrepared locally, delivery pending',
                  ),
                ),
            ],
          ),
        ],
        if (_error != null)
          Text(
            _error!,
            key: const Key('company-job-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
