import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../installation/installation_security.dart';
import '../job_line_commands/job_line_commands.dart';

const _detailLabels = {
  JobDetailField.customer: 'Customer',
  JobDetailField.location: 'Location',
  JobDetailField.jobNumber: 'Job number',
  JobDetailField.status: 'Status',
  JobDetailField.notes: 'Notes',
};

class CompanyJobDetailsSection extends StatefulWidget {
  const CompanyJobDetailsSection({
    required this.job,
    required this.commands,
    required this.owner,
    required this.available,
    required this.onSaved,
    super.key,
  });
  final CompanyJobView job;
  final CompanyJobCommands commands;
  final OwnerSession owner;
  final bool available;
  final Future<void> Function() onSaved;

  @override
  State<CompanyJobDetailsSection> createState() => _DetailsSectionState();
}

class _DetailsSectionState extends State<CompanyJobDetailsSection> {
  final _text = {
    for (final field in JobDetailField.values.where(
      (f) => f != JobDetailField.status,
    ))
      field: TextEditingController(),
  };
  final _dirty = <JobDetailField>{},
      _cleared = <JobDetailField>{},
      _resolving = <JobDetailField>{};
  CompanyJobView? _captured;
  PatchJobDetails? _pending;
  CompanyJobStatus _status = CompanyJobStatus.active;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  JobDetailValue<Object?> _value(CompanyJobView job, JobDetailField field) =>
      switch (field) {
        JobDetailField.customer => job.details.customer,
        JobDetailField.location => job.details.location,
        JobDetailField.jobNumber => job.details.jobNumber,
        JobDetailField.status => job.details.status,
        JobDetailField.notes => job.details.notes,
      };

  String _display(Object? value) => value == null
      ? '(not set)'
      : value is CompanyJobStatus
      ? value.name
      : value as String;

  void _edit([JobDetailField? resolve, Object? selected]) {
    if (_busy || _pending != null) return;
    setState(() {
      _captured = widget.job;
      _dirty.clear();
      _cleared.clear();
      _resolving.clear();
      for (final entry in _text.entries) {
        entry.value.text = _value(widget.job, entry.key).value as String? ?? '';
      }
      _status = widget.job.details.status.value;
      if (resolve != null) {
        _resolving.add(resolve);
        _dirty.add(resolve);
        if (resolve == JobDetailField.status) {
          _status = selected as CompanyJobStatus;
        } else if (selected == null) {
          _cleared.add(resolve);
          _text[resolve]!.clear();
        } else {
          _text[resolve]!.text = selected as String;
        }
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_busy || _captured == null || (_pending == null && _dirty.isEmpty)) {
      return;
    }
    try {
      final scope = widget.owner.identity;
      FieldPatch<String?> text(JobDetailField f) => !_dirty.contains(f)
          ? const Omitted()
          : SetField(_cleared.contains(f) ? null : _text[f]!.text);
      _pending ??= PatchJobDetails(
        companyId: scope.companyId,
        shopId: scope.shopId,
        jobId: _captured!.baseJob.id,
        requestId: const Uuid().v4(),
        creationDigest: _captured!.creationDigest,
        patch: JobDetailsPatch(
          customer: text(JobDetailField.customer),
          location: text(JobDetailField.location),
          jobNumber: text(JobDetailField.jobNumber),
          notes: text(JobDetailField.notes),
          status: _dirty.contains(JobDetailField.status)
              ? SetField(_status)
              : const Omitted(),
        ),
        observedHeads: {for (final f in _dirty) f: _value(_captured!, f).heads},
        observedLifecycleHeads: _captured!.lifecycle.lifecycleHeads,
        resolvingFields: _resolving,
      );
    } on JobLineRefusal catch (e) {
      setState(() => _error = e.reason);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.commands.patchJobDetails(
        _pending!,
        ownerSession: widget.owner,
      );
      await widget.onSaved();
      if (mounted) {
        setState(() {
          _captured = null;
          _pending = null;
        });
      }
    } on CompanyJobDetailsResolutionRefusal catch (e) {
      if (mounted) {
        setState(() {
          _pending = null;
          _captured = null;
          _error = e.reason;
        });
        await widget.onSaved();
      }
    } on CompanyJobDetailsCapacityRefusal catch (e) {
      if (mounted) {
        setState(() {
          _pending = null;
          _captured = null;
          _error = e.reason;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is JobLineRefusal ? e.reason : 'This details edit may already be saved. Retry the same edit to check its result.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final frozen = _busy || _pending != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in JobDetailField.values) ...[
          Text(
            '${_detailLabels[field]}: ${_display(_value(job, field).value)}',
            key: Key('company-job-detail-${field.name}-${job.baseJob.id}'),
          ),
          if (_value(job, field).hasConflict)
            Column(
              key: Key(
                'company-job-details-conflict-${field.name}-${job.baseJob.id}',
              ),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Competing ${_detailLabels[field]!.toLowerCase()} values. Last agreed: ${_display(_value(job, field).lastAgreedValue)}',
                ),
                for (final candidate in _value(job, field).candidates)
                  ListTile(
                    key: Key(
                      'company-job-details-candidate-${field.name}-${candidate.operationId}',
                    ),
                    title: Text(_display(candidate.value)),
                    subtitle: Text(
                      'User: ${candidate.originalUserId}\nDevice: ${candidate.originalDeviceId}\nOperation: ${candidate.operationId}',
                    ),
                    onTap: widget.available && !frozen
                        ? () => _edit(field, candidate.value)
                        : null,
                    trailing: const Text('Resolve with this value'),
                  ),
              ],
            ),
        ],
        if (!widget.available)
          Text(switch (job.lifecycle.state) {
            CompanyJobLifecycleState.deleted =>
              'Deleted Job history is read-only.',
            CompanyJobLifecycleState.deleteConflict =>
              'Resolve the deletion conflict before editing details.',
            CompanyJobLifecycleState.live =>
              'Details editing requires explicit company permission.',
          }),
        if (widget.available && _captured == null)
          TextButton(
            key: Key('company-job-edit-details-${job.baseJob.id}'),
            onPressed: frozen ? null : () => _edit(),
            child: const Text('Edit details'),
          ),
        if (_captured != null) ...[
          for (final field in JobDetailField.values) ...[
            if (_value(_captured!, field).hasConflict &&
                !_resolving.contains(field))
              Text(
                'Resolve competing ${_detailLabels[field]!.toLowerCase()} values above before changing this field.',
              ),
            if (field == JobDetailField.status)
              DropdownButtonFormField<CompanyJobStatus>(
                key: const Key('company-job-details-status'),
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  for (final value in CompanyJobStatus.values)
                    DropdownMenuItem(value: value, child: Text(value.name)),
                ],
                onChanged:
                    frozen ||
                        (_value(_captured!, field).hasConflict &&
                            !_resolving.contains(field))
                    ? null
                    : (value) => setState(() {
                        _status = value!;
                        _dirty.add(field);
                      }),
              )
            else ...[
              TextField(
                key: Key('company-job-details-${field.name}'),
                controller: _text[field],
                enabled:
                    !frozen &&
                    (!_value(_captured!, field).hasConflict ||
                        _resolving.contains(field)) &&
                    !_cleared.contains(field),
                maxLines: field == JobDetailField.notes ? 3 : 1,
                decoration: InputDecoration(labelText: _detailLabels[field]),
                onChanged: (_) => setState(() => _dirty.add(field)),
              ),
              CheckboxListTile(
                key: Key('company-job-details-clear-${field.name}'),
                title: Text('Clear ${_detailLabels[field]!.toLowerCase()}'),
                value: _cleared.contains(field),
                onChanged:
                    frozen ||
                        (_value(_captured!, field).hasConflict &&
                            !_resolving.contains(field))
                    ? null
                    : (value) => setState(() {
                        _dirty.add(field);
                        if (value!) {
                          _cleared.add(field);
                        } else {
                          _cleared.remove(field);
                        }
                      }),
              ),
            ],
          ],
          FilledButton(
            key: Key(
              _pending == null
                  ? 'company-job-save-details'
                  : 'company-job-retry-details',
            ),
            onPressed: _busy || (_dirty.isEmpty && _pending == null)
                ? null
                : _save,
            child: Text(
              _busy
                  ? 'Saving...'
                  : _pending == null
                  ? 'Save details'
                  : 'Retry same details edit',
            ),
          ),
          TextButton(
            key: const Key('company-job-reload-details'),
            onPressed: _busy || _pending != null
                ? null
                : () async {
                    await widget.onSaved();
                    if (mounted) {
                      setState(() {
                        _captured = null;
                        _pending = null;
                        _error = null;
                      });
                    }
                  },
            child: const Text('Close editor and reload details'),
          ),
        ],
        if (_error != null)
          Text(_error!, key: const Key('company-job-details-error')),
      ],
    );
  }
}
