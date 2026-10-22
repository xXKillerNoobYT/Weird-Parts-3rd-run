import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../installation/installation_security.dart';
import 'company_job_details_section.dart';
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
  List<CompanyJobView> _jobs = const [];
  final _editName = TextEditingController();
  CompanyJobView? _editing;
  RenameJob? _pendingRename;
  bool _renameAvailable = false;
  bool _detailsAvailable = false;
  Map<String, int> _confirmedPeers = const {};
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
    _editName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jobs = await widget.commands.listJobViews(
        ownerSession: widget.owner,
      );
      final renameAvailable = await widget.commands.canRenameJobs(widget.owner);
      final detailsAvailable = await widget.commands.canEditJobDetails(
        widget.owner,
      );
      final confirmed = await CompanyCreatedJobSync.confirmedPeerCounts(
        widget.commands.enrollment,
        widget.owner,
      );
      if (!mounted || !widget.owner.isValid) return;
      setState(() {
        _jobs = jobs;
        _renameAvailable = renameAvailable;
        _detailsAvailable = detailsAvailable;
        _confirmedPeers = confirmed;
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
      final jobs = await widget.commands.listJobViews(
        ownerSession: widget.owner,
      );
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

  void _edit(CompanyJobView job, [String? selected]) {
    if (_busy || _pendingRename != null) return;
    setState(() {
      _editing = job;
      _editName.text = selected ?? job.displayName;
      _error = null;
    });
  }

  Future<void> _saveName() async {
    if (_busy || _editing == null) return;
    try {
      final scope = widget.owner.identity;
      final job = _editing!;
      _pendingRename ??= RenameJob(
        companyId: scope.companyId,
        shopId: scope.shopId,
        jobId: job.baseJob.id,
        requestId: const Uuid().v4(),
        creationDigest: job.creationDigest,
        observedHeads: job.nameHeads,
        name: _editName.text,
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
      await widget.commands.renameJob(
        _pendingRename!,
        ownerSession: widget.owner,
      );
      final jobs = await widget.commands.listJobViews(
        ownerSession: widget.owner,
      );
      final confirmed = await CompanyCreatedJobSync.confirmedPeerCounts(
        widget.commands.enrollment,
        widget.owner,
      );
      if (!mounted || !widget.owner.isValid) return;
      setState(() {
        _jobs = jobs;
        _confirmedPeers = confirmed;
        _editing = null;
        _pendingRename = null;
        _editName.clear();
      });
    } on CompanyJobNameCapacityRefusal catch (error) {
      if (mounted) {
        setState(() {
          _pendingRename = null;
          _editing = null;
          _error = error.reason;
        });
        await _load();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'This name edit may already be saved. Retry the same edit to check its result.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _jobTile(CompanyJobView job) => Column(
    key: Key('company-job-view-${job.baseJob.id}'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        key: Key('company-job-${job.baseJob.id}'),
        title: Text(job.displayName),
        subtitle: Text(
          'Job ID: ${job.baseJob.id}\n${(_confirmedPeers[job.baseJob.id] ?? 0) > 0 ? 'Last confirmed by ${_confirmedPeers[job.baseJob.id]} retained peer(s)' : 'Peer delivery status unknown'}',
        ),
        trailing: !job.hasConflict && _renameAvailable
            ? TextButton(
                key: Key('company-job-edit-${job.baseJob.id}'),
                onPressed: _busy || _pendingRename != null
                    ? null
                    : () => _edit(job),
                child: const Text('Edit name'),
              )
            : null,
      ),
      if (job.hasConflict)
        Column(
          key: Key('company-job-name-conflict-${job.baseJob.id}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Competing names. Last agreed name: ${job.lastAgreedName}'),
            for (final candidate in job.candidates)
              ListTile(
                key: Key('company-job-name-candidate-${candidate.operationId}'),
                title: Text(candidate.name),
                subtitle: Text(
                  'User: ${candidate.originalUserId}\nDevice: ${candidate.originalDeviceId}\nOperation: ${candidate.operationId}',
                ),
                onTap: _renameAvailable && !_busy && _pendingRename == null
                    ? () => _edit(job, candidate.name)
                    : null,
              ),
            if (_renameAvailable)
              TextButton(
                key: Key('company-job-resolve-name-${job.baseJob.id}'),
                onPressed: _busy || _pendingRename != null
                    ? null
                    : () => _edit(job),
                child: const Text('Resolve competing names'),
              ),
          ],
        ),
      CompanyJobDetailsSection(
        key: Key('company-job-details-${job.baseJob.id}'),
        job: job,
        commands: widget.commands,
        owner: widget.owner,
        available: _detailsAvailable,
        onSaved: _load,
      ),
    ],
  );

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
            'Jobs are saved on this installation. Use Sync Now with a verified retained peer. Confirmations describe the last successful exchange.',
          ),
          if (!_renameAvailable)
            const Text(
              'Name editing requires an explicit company permission upgrade.',
            ),
          if (_editing != null) ...[
            Text(
              _editing!.hasConflict ? 'Resolve name conflict' : 'Edit Job name',
            ),
            TextField(
              key: const Key('company-job-edit-name'),
              controller: _editName,
              enabled: !_busy && _pendingRename == null,
              maxLength: kCompanyJobNameLimit,
              decoration: const InputDecoration(labelText: 'New Job name'),
            ),
            FilledButton(
              key: Key(
                _pendingRename == null
                    ? 'company-job-save-name'
                    : 'company-job-retry-name',
              ),
              onPressed: _busy ? null : _saveName,
              child: Text(
                _busy
                    ? 'Saving...'
                    : _pendingRename == null
                    ? 'Save name'
                    : 'Retry same name edit',
              ),
            ),
            if (_pendingRename == null)
              TextButton(
                onPressed: _busy ? null : () => setState(() => _editing = null),
                child: const Text('Cancel name edit'),
              ),
          ],
          if (_jobs.isEmpty) const Text('No company Jobs yet.'),
          Column(
            key: const Key('company-jobs-list'),
            children: [for (final job in _jobs) _jobTile(job)],
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
