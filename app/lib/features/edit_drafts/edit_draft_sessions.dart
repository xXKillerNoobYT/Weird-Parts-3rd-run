part of 'edit_drafts.dart';

abstract class _EditSession {
  _EditSession(this._owner, this._record)
    : _statusValue = ValueNotifier(
        EditStatus(
          _record.sequence == 0 ? EditPhase.unpersisted : EditPhase.durable,
          latestSequence: _record.sequence,
          durableSequence: _record.sequence == 0 ? null : _record.sequence,
        ),
      );
  final EditDrafts _owner;
  final _DraftRecord _record;
  final ValueNotifier<EditStatus> _statusValue;
  ValueListenable<EditStatus> get status => _statusValue;
  bool _admitted = false;
  bool _sealed = false;
  Object? _lastError;
  String? _operation;
  Map<String, String>? _committed;
  bool get _live => !_owner._closed && _owner._active[_record.slot] == this;
  void _status(EditPhase phase, {int? durableSequence, Object? error}) {
    _statusValue.value = EditStatus(
      phase,
      latestSequence: _record.sequence,
      durableSequence: durableSequence,
      error: error,
    );
  }

  void _close() {
    _sealed = true;
    _status(EditPhase.closed);
  }

  void _replace(Object input) {
    if (!_live || _sealed || _owner._quiescing) return;
    if (_digest(_inputJson(input)) == _digest(_inputJson(_record.input))) {
      return;
    }
    _record.input = input;
    _record.sequence++;
    _status(EditPhase.writing);
    unawaited(
      _owner._queue(_persist).catchError((Object e) {
        _lastError = e;
        if (_live && !_sealed) _status(EditPhase.storageFailed, error: e);
      }),
    );
  }

  Future<void> _persist() async {
    if (!_live || (_sealed && _operation == null)) return;
    if (_record.sequence == 0) return;
    final sequence = _record.sequence;
    final input = _record.input;
    if (input case JobLineInput j when j.splits.length > _splitLimit) {
      throw StateError(
        'There are too many unfinished supplier splits. Your input remains in the form.',
      );
    }
    final refs = await _owner._references(input);
    _record.references.removeWhere((key, _) => !refs.containsKey(key));
    for (final e in refs.entries) {
      _record.references.putIfAbsent(e.key, () => e.value);
    }
    _encoded(_record.toJson());
    var committed = false;
    await _owner._db.transaction(() async {
      if (!_live || (_sealed && _operation == null)) return;
      final origin = _owner._origin();
      if (!_admitted && _record.origin['mode'] == 'unavailable') {
        _record.origin
          ..clear()
          ..addAll(origin);
      }
      if (_digest(origin) != _digest(_record.origin)) {
        throw StateError(
          'Installation identity changed. Your input remains in this form.',
        );
      }
      final encoded = _encoded(_record.toJson());
      if (!_admitted) {
        final existing = await _owner._read(_record.inputKey);
        if (existing != null) {
          throw StateError('Another unfinished edit already exists');
        }
        await _owner._set(_record.controlKey, {
          'phase': 'editing',
          'token': _record.token,
        });
        await _owner._db.settingsDao.setSetting(_record.inputKey, encoded);
      } else {
        final control = _map(
          jsonDecode(await _owner._read(_record.controlKey) ?? 'null'),
        );
        if (control['phase'] != 'editing' ||
            control['token'] != _record.token) {
          throw StateError('This unfinished editing session was replaced');
        }
        final changed = await _owner._db.customUpdate(
          'UPDATE app_settings SET value = ? WHERE key = ?',
          variables: [Variable(encoded), Variable(_record.inputKey)],
        );
        if (changed != 1) {
          throw StateError('This unfinished editing session was removed');
        }
      }
      committed = true;
    });
    if (!committed) return;
    _admitted = true;
    _lastError = null;
    if (_live && !_sealed && sequence == _record.sequence) {
      _status(EditPhase.durable, durableSequence: sequence);
    }
  }

  Future<void> flush() async {
    if (!_live || (_sealed && _operation == null)) return;
    try {
      await _owner._queue(_persist);
      if (_lastError != null) throw _lastError!;
    } catch (e) {
      _lastError = e;
      if (_live && !_sealed) _status(EditPhase.storageFailed, error: e);
      rethrow;
    }
  }

  Future<void> leave(LeaveIntent intent) {
    if (intent == LeaveIntent.back) {
      return flush().then((_) {
        if (_live) {
          _owner._active.remove(_record.slot);
          _close();
        }
      });
    }
    if (!_live || _sealed) return Future.value();
    _sealed = true;
    _operation = null;
    _status(EditPhase.closed);
    return _owner._queue(() async {
      try {
        if (_admitted) {
          await _owner._db.transaction(() async {
            final control = _map(
              jsonDecode(await _owner._read(_record.controlKey) ?? 'null'),
            );
            if (control['phase'] != 'editing' ||
                control['token'] != _record.token) {
              throw StateError('Unfinished edits changed before Discard');
            }
            await _owner._delete(_record.inputKey);
            await _owner._delete(_record.controlKey);
          });
        }
        if (_owner._active[_record.slot] == this) {
          _owner._active.remove(_record.slot);
        }
      } catch (e) {
        _sealed = false;
        _status(EditPhase.storageFailed, error: e);
        rethrow;
      }
    });
  }

  Future<Map<String, String>> _settle(
    String operation,
    Future<Map<String, String>> Function() mutate,
  ) async {
    if (_operation != null && _operation != operation) {
      throw StateError('This session already performed a different action');
    }
    if (_committed != null) {
      final raw = await _owner._read(_record.controlKey);
      final receipt = raw == null ? <String, Object?>{} : _control(raw);
      if (receipt['phase'] == 'committed' &&
          receipt['token'] == _record.token &&
          receipt['command'] == operation &&
          _digest(_owner._origin()) == _digest(receipt['origin']) &&
          _digest(_strings(receipt['result'])) == _digest(_committed)) {
        return _committed!;
      }
      throw StateError('A newer edit replaced this committed action');
    }
    if (!_live || _sealed || _owner._quiescing) {
      throw StateError('This editor is no longer active');
    }
    _sealed = true;
    _operation = operation;
    if (_record.sequence == 0) _record.sequence = 1;
    _status(EditPhase.saving);
    var inputPersisted = false;
    try {
      final result = await _owner._queue(() async {
        await _persist();
        inputPersisted = true;
        return legacyBusinessWrite(_owner._db, () async {
          await _owner._check(_record);
          await _owner._requireReferences(_record);
          final control = _map(
            jsonDecode(await _owner._read(_record.controlKey) ?? 'null'),
          );
          if (control['phase'] != 'editing' ||
              control['token'] != _record.token) {
            throw StateError('Unfinished edit session changed before Save');
          }
          final result = await mutate();
          await _owner._delete(_record.inputKey);
          await _owner._set(_record.controlKey, {
            'phase': 'committed',
            'token': _record.token,
            'command': operation,
            'result': result,
            'origin': _record.origin,
          });
          return result;
        });
      });
      _committed = result;
      _owner._active.remove(_record.slot);
      _close();
      return result;
    } catch (e) {
      _sealed = false;
      _operation = null;
      if (!inputPersisted) _lastError = e;
      _status(
        inputPersisted ? EditPhase.saveFailed : EditPhase.storageFailed,
        durableSequence: inputPersisted ? _record.sequence : null,
        error: e,
      );
      rethrow;
    }
  }
}

class WarehouseCountEditSession extends _EditSession {
  WarehouseCountEditSession._(super.owner, super.record);
  WarehouseCountInput get initial => _record.input as WarehouseCountInput;
  String get countId => _record.target['reserved']!;
  void replace(WarehouseCountInput input) => _replace(input);

  Future<WarehouseCountSaved> save() async {
    final result = await _settle('warehouse-count-save', () async {
      final quantity = double.tryParse(initial.quantityText.trim());
      if (quantity == null) {
        throw StateError(
          'Enter a finite, nonnegative quantity. Zero is a count.',
        );
      }
      final target = _record.target;
      final count =
          await WarehouseRepository(
            _owner._db,
            _owner._pin,
            _owner._deviceId,
          ).recordCount(
            WarehouseCountDraft(
              id: countId,
              locationId: target['location']!,
              partId: target['part']!,
              expectedPriorCountId: target['prior'],
              quantity: quantity,
              uom: target['uom']!,
              observedAt: initial.observedAt,
              note: initial.noteText,
            ),
          );
      return {
        'count': count.id,
        'location': count.locationId,
        'part': count.partId,
        'row': _digest(count.toJson()),
      };
    });
    final raw = await _owner._read(_record.controlKey);
    if (raw == null) throw StateError('Saved count receipt is unavailable');
    final control = _control(raw);
    if (control['token'] != _record.token ||
        _digest(_strings(control['result'])) != _digest(result)) {
      throw StateError('A newer count edit replaced this receipt');
    }
    return _owner._savedWarehouseCount(
      raw,
      _record.target['location']!,
      _record.target['part']!,
    );
  }
}

class NewJobEditSession extends _EditSession {
  NewJobEditSession._(super.owner, super.record);
  NewJobInput get initial => _record.input as NewJobInput;
  void replace(NewJobInput input) => _replace(input);

  Future<NewJobCreated> save() async {
    final result = await _settle('job-create', () async {
      final name = initial.nameText.trim();
      final id = await JobsRepository(
        _owner._db,
        _owner._deviceId,
      ).createJob(name, reservedJobId: _record.target['reserved']!);
      return {'job': id, 'name': name};
    });
    final raw = await _owner._read(_record.controlKey);
    if (raw == null) throw StateError('Created Job receipt is unavailable');
    final control = _control(raw);
    if (control['token'] != _record.token ||
        _digest(_strings(control['result'])) != _digest(result)) {
      throw StateError('A newer Job edit replaced this receipt');
    }
    return _owner._createdJob(raw);
  }
}

class PartEditSession extends _EditSession {
  PartEditSession._(super.owner, super.record);
  PartInput get initial => _record.input as PartInput;
  void replace(PartInput input) => _replace(input);
  PartSaved? _saved;
  Future<PartSaved> save() async {
    await _settle('part-save', () async {
      final p = initial;
      if (p.nameText.trim().isEmpty) throw StateError('Name is required');
      await CatalogRepository(
        _owner._db,
        _owner._pin,
        _owner._deviceId,
      ).updatePart(
        partId: _record.target['id']!,
        name: p.nameText.trim(),
        description: p.descriptionText.trim(),
        specs: p.specsText,
        uom: p.uomText.trim().isEmpty ? 'ea' : p.uomText.trim(),
        categoryId: p.categoryId,
        styleId: p.styleId,
        typeId: p.typeId,
        defaultSupplierId: p.defaultSupplierId,
        active: p.active,
      );
      return {'part': _record.target['id']!};
    });
    if (_saved case final saved?) return saved;
    final next = await _owner.openPart(_record.target['id']!);
    if (next is! FreshEdit<PartEditSession>) {
      throw StateError('Part saved. Reopen the Part to continue editing.');
    }
    return _saved = PartSaved(next.session);
  }

  Future<String> attachPhoto({
    required Uint8List bytes,
    PartPhotoStore store = const PartPhotoStore(),
    Directory? root,
  }) async {
    if (!_live || _sealed || _owner._quiescing) {
      throw StateError('This editor is no longer active');
    }
    await flush();
    return CatalogRepository(
      _owner._db,
      _owner._pin,
      _owner._deviceId,
    ).attachPhoto(
      partId: _record.target['id']!,
      bytes: bytes,
      store: store,
      root: root,
      companion: _PhotoCompanion(this),
    );
  }

  Future<void> clearPhoto({
    PartPhotoStore store = const PartPhotoStore(),
    Directory? root,
  }) async {
    if (!_live || _sealed || _owner._quiescing) {
      throw StateError('This editor is no longer active');
    }
    await flush();
    await CatalogRepository(
      _owner._db,
      _owner._pin,
      _owner._deviceId,
    ).clearPhoto(
      _record.target['id']!,
      store: store,
      root: root,
      companion: _PhotoCompanion(this),
    );
  }
}

class _PhotoCompanion implements PartWriteCompanion {
  _PhotoCompanion(this.session);
  final PartEditSession session;
  Map<String, Object?>? _before;
  Map<String, String>? _pendingBase;
  @override
  void photoReferenceCommitted() {
    if (_pendingBase case final next?) session._record.base = next;
    _pendingBase = null;
  }

  @override
  void validatePhotoOperation() {
    if (!session._live || session._sealed || session._owner._quiescing) {
      throw StateError('This photo editor generation is closed');
    }
  }

  @override
  Future<void> beforePhotoReferenceWrite(AppDatabase db, String partId) async {
    if (!session._live ||
        session._sealed ||
        session._owner._quiescing ||
        db != session._owner._db ||
        partId != session._record.target['id']) {
      throw StateError('This photo editor generation is closed');
    }
    await session._owner._check(session._record);
    _before = await session._owner._row('parts', partId);
  }

  @override
  Future<void> afterPhotoReferenceWrite(AppDatabase db, String partId) async {
    final after = await session._owner._row('parts', partId);
    final before = _before;
    if (before == null ||
        after == null ||
        after['revision'] != (before['revision'] as int) + 1) {
      throw StateError('Photo reference changed unexpectedly');
    }
    Map<String, Object?> scalar(Map<String, Object?> row) => Map.of(row)
      ..remove('photo_path')
      ..remove('modified_at')
      ..remove('revision');
    if (_digest(scalar(before)) != _digest(scalar(after))) {
      throw StateError('Part changed during photo update');
    }
    final next = await session._owner._base(session._record.target);
    if (session._admitted) {
      final control = _map(
        jsonDecode(
          await session._owner._read(session._record.controlKey) ?? 'null',
        ),
      );
      if (control['token'] != session._record.token ||
          control['phase'] != 'editing') {
        throw StateError('Photo editing session changed');
      }
      await session._owner._set(session._record.inputKey, {
        ...session._record.toJson(),
        'base': next,
      });
    }
    _pendingBase = next;
  }
}

class JobLineEditSession extends _EditSession {
  JobLineEditSession._(super.owner, super.record);
  JobLineInput get initial => _record.input as JobLineInput;
  void replace(JobLineInput input) => _replace(input);
  ({double needed, double pull, List<({String supplierId, double qty})> splits})
  _quantities() {
    double number(String raw, String label, {bool positive = false}) {
      final value = double.tryParse(raw.trim());
      if (value == null ||
          !value.isFinite ||
          (positive ? value <= 0 : value < 0)) {
        throw StateError(
          '$label must be ${positive ? 'greater than zero' : 'nonnegative'}',
        );
      }
      return value;
    }

    final p = initial;
    final splits = <({String supplierId, double qty})>[];
    for (final split in p.splits) {
      if (split.supplierId == null && split.quantityText.trim().isEmpty) {
        continue;
      }
      if (split.supplierId == null) {
        throw StateError('Each order split needs a supplier');
      }
      splits.add((
        supplierId: split.supplierId!,
        qty: number(split.quantityText, 'Split quantity', positive: true),
      ));
    }
    return (
      needed: number(p.neededText, 'Requested quantity'),
      pull: number(p.pullText, 'Shop quantity'),
      splits: splits,
    );
  }

  Future<String> save() async {
    final result = await _settle('line-save', () async {
      final p = initial;
      final q = _quantities();
      if (p.useCustom ? p.customNameText.trim().isEmpty : p.partId == null) {
        throw StateError(
          p.useCustom
              ? 'Custom name is required'
              : 'Pick a catalog Part or enter a custom name',
        );
      }
      final jobs = JobsRepository(_owner._db, _owner._deviceId);
      final line = _record.target['line'];
      if (line != null) {
        await jobs.updateLine(
          lineId: line,
          partId: p.useCustom ? null : p.partId,
          brandVersionId: p.useCustom ? null : p.brandVersionId,
          customName: p.useCustom ? p.customNameText.trim() : null,
          customNotes: p.customNotes,
          uom: p.uom,
          notes: p.notes,
          neededQty: q.needed,
          shopPullQty: q.pull,
          splits: q.splits,
        );
      } else {
        await jobs.addLine(
          jobId: _record.target['job']!,
          reservedLineId: _record.target['reserved'],
          partId: p.useCustom ? null : p.partId,
          brandVersionId: p.useCustom ? null : p.brandVersionId,
          customName: p.useCustom ? p.customNameText.trim() : null,
          customNotes: p.customNotes,
          uom: p.uom,
          notes: p.notes,
          neededQty: q.needed,
          shopPullQty: q.pull,
          splits: q.splits,
        );
      }
      return {'line': _record.target['reserved']!};
    });
    return result['line']!;
  }

  JobLinePromoted? _promoted;
  Future<JobLinePromoted> promote(PartDetails details) async {
    final result = await _settle(
      'line-promote/${_digest([details.name, details.categoryId, details.styleId, details.typeId])}',
      () async {
        final q = _quantities();
        final promoted =
            await CatalogPromotion(
              _owner._db,
              _owner._pin,
              _owner._deviceId,
            ).promote(
              jobId: _record.target['job']!,
              lineId: _record.target['line'],
              reservedNewLineId: _record.target.containsKey('line')
                  ? null
                  : _record.target['reserved'],
              name: details.name,
              categoryId: details.categoryId,
              styleId: details.styleId,
              typeId: details.typeId,
              neededQty: q.needed,
              shopPullQty: q.pull,
              splits: q.splits,
            );
        return {'part': promoted.partId, 'line': promoted.lineId};
      },
    );
    if (_promoted case final saved?) return saved;
    final next = await _owner.openJobLine(
      _record.target['job']!,
      lineId: result['line']!,
    );
    if (next is! FreshEdit<JobLineEditSession>) {
      throw StateError('Part promoted. Reopen the line to continue editing.');
    }
    return _promoted = JobLinePromoted(
      partId: result['part']!,
      lineId: result['line']!,
      session: next.session,
    );
  }

  Future<void> remove() async {
    if (!_record.target.containsKey('line')) {
      throw StateError('There is no saved line to remove');
    }
    await _settle('line-remove', () async {
      await JobsRepository(
        _owner._db,
        _owner._deviceId,
      ).removeLine(_record.target['line']!);
      return {'line': _record.target['line']!};
    });
  }
}
