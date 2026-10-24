part of 'job_line_commands.dart';

/// Honest legacy baseline: this commitment attributes the copied state to no
/// human. A signed company fact must bind it before this command can adopt it.
String jobLineLegacyBaselineCommitment({
  required String companyId,
  required String shopId,
  required JobLine row,
}) => _digest({
  'company': companyId,
  'shop': shopId,
  'line': row.id,
  'row': row.toJson(),
});

void _validateReceiptPayload(
  Map<String, Object?> value,
  JobLineReceipt receipt,
  _Operation operation,
  InstallationIdentity identity,
  String store, {
  required bool sealed,
}) {
  _keys(value, {
    'v',
    'key',
    'parent',
    'operation',
    'command',
    'status',
    'bytes',
    'receiver',
    'store',
    if (sealed) 'seal',
  });
  final base = _digest({
    'company': operation.company,
    'origin': operation.generation,
    'request': operation.id,
    'receiver': identity.id.value,
    'store': store,
  });
  final status = value['status'];
  final parent = value['parent'];
  if (value['v'] != 2 ||
      !['applied', 'conflict', 'deferred'].contains(status) ||
      receipt.companyId != operation.company ||
      receipt.operationCommitment != operation.commitment ||
      receipt.commandCommitment != operation.commandCommitment ||
      value['key'] != receipt.receiptKey ||
      value['operation'] != operation.commitment ||
      value['command'] != operation.commandCommitment ||
      value['receiver'] != identity.id.value ||
      value['store'] != store ||
      value['bytes'] != base64Encode(utf8.encode(operation.bytes)) ||
      operation.commandCommitment !=
          _commandFromOperation(operation).commitment ||
      (parent == null
          ? receipt.receiptKey != base
          : parent != base ||
                status == 'deferred' ||
                receipt.receiptKey !=
                    _digest({'parent': base, 'transition': status}))) {
    throw const JobLineRefusal('receipt does not cover exact operation');
  }
}

class JobLineCommands {
  JobLineCommands({
    required this.authorization,
    this.beforeCommit,
    this.afterCommit,
  });
  final JobLineAuthorization authorization;
  final Future<void> Function()? beforeCommit;
  final Future<void> Function()? afterCommit;
  AppDatabase get _db => authorization.db;
  InstallationSecurity get _installation => authorization.installation;

  Future<List<String>> observedHeads(VerifiedJobLineSession session) async {
    await authorization._verify(session.command, session._proof);
    final operations = await _operations(
      session.command.companyId,
      session.command.lineId,
    );
    final referenced = operations.expand((o) => o.parents).toSet();
    return operations
        .where((o) => !referenced.contains(o.key))
        .map((o) => o.key)
        .toList()
      ..sort();
  }

  Future<JobLineCommandReceipt> patchJobLine(
    VerifiedJobLineSession session,
    JobLineCommand command, {
    OwnerSession? ownerSession,
  }) async {
    if (session._assertion['v'] == 2) {
      if (ownerSession == null) {
        throw const JobLineRefusal('Live administrator session required');
      }
      return ownerSession.runLocalCommand(
        () => _patchJobLine(session, command, ownerSession: ownerSession),
      );
    }
    return _patchJobLine(session, command);
  }

  Future<JobLineCommandReceipt> _patchJobLine(
    VerifiedJobLineSession session,
    JobLineCommand command, {
    OwnerSession? ownerSession,
  }) async {
    if (_db.hasCallerTransaction) {
      throw const JobLineRefusal('command must own its top-level transaction');
    }
    if (session.command.commitment != command.commitment) {
      throw const JobLineRefusal('verified session does not cover command');
    }
    final verified = await authorization._verify(command, session._proof);
    final assertion = verified._assertion;
    _validateLocalOwner(verified, ownerSession);
    final identity = _installation.identity;
    if (identity == null ||
        assertion['installation'] != identity.id.value ||
        assertion['generation'] != identity.generation.value ||
        base64Encode(verified._publicKey.bytes) !=
            base64Encode(identity.publicKey)) {
      throw const JobLineRefusal('local command is not this installation');
    }
    final existing =
        await (_db.select(_db.jobLineOperations)..where(
              (t) =>
                  t.companyId.equals(command.companyId) &
                  t.originGeneration.equals(identity.generation.value) &
                  t.requestId.equals(command.requestId),
            ))
            .getSingleOrNull();
    if (existing != null) {
      final original = _Operation.parse(
        Uint8List.fromList(utf8.encode(existing.operationBytes)),
      );
      for (final key in [
        'company',
        'shop',
        'line',
        'request',
        'generation',
        'installation',
        'device',
        'user',
        'command',
      ]) {
        if (original.body[key] != assertion[key]) {
          throw const JobLineRefusal(
            'local retry differs from original actor or command',
          );
        }
      }
      return _apply(
        original,
        local: true,
        resume: false,
        localSession: verified,
        localOwner: ownerSession,
      );
    }
    final binding = verified._facts.entity(
      'jobLine',
      command.lineId,
      shop: command.shopId,
    );
    final body = <String, Object?>{
      'v': 1,
      'contract': 'job.line.patch@1',
      'company': command.companyId,
      'shop': command.shopId,
      'line': command.lineId,
      'request': command.requestId,
      'generation': assertion['generation'],
      'installation': assertion['installation'],
      'device': assertion['device'],
      'user': assertion['user'],
      'parents': command.observedHeads,
      'baseline': _string(binding, 'baseline'),
      'units': command.mutation._units(),
      'command': command.commitment,
      'facts': verified._trust.factsCommitment,
    };
    final signature = await _installation.signCompanyOperation(
      _db,
      verified,
      Uint8List.fromList(utf8.encode(_canonical(body))),
      ownerSession: ownerSession,
    );
    final bytes = _canonical({
      'body': body,
      'authorization': verified._proof,
      'signature': base64Encode(signature.bytes),
    });
    return _apply(
      _Operation(body, verified._proof, base64Encode(signature.bytes), bytes),
      local: true,
      resume: false,
      localSession: verified,
      localOwner: ownerSession,
    );
  }

  void _validateLocalOwner(
    VerifiedJobLineSession verified,
    OwnerSession? owner,
  ) {
    verified.validateLiveOwner(owner);
  }

  Future<JobLineCommandReceipt> applyIncoming(
    Uint8List canonicalOperation,
  ) async =>
      _apply(_Operation.parse(canonicalOperation), local: false, resume: false);

  /// Deferral receipts remain immutable. A semantic transition gets a linked
  /// receipt; replay of the original submission still returns its exact reply.
  Future<JobLineCommandReceipt> retryDeferred({
    required String companyId,
    required String originGeneration,
    required String requestId,
  }) async {
    final row =
        await (_db.select(_db.jobLineOperations)..where(
              (t) =>
                  t.companyId.equals(companyId) &
                  t.originGeneration.equals(originGeneration) &
                  t.requestId.equals(requestId),
            ))
            .getSingleOrNull();
    if (row == null) throw const JobLineRefusal('deferred operation missing');
    return _apply(
      _Operation.parse(Uint8List.fromList(utf8.encode(row.operationBytes))),
      local: false,
      resume: true,
    );
  }

  Future<List<_Operation>> _operations(String company, String line) async {
    final rows =
        await (_db.select(_db.jobLineOperations)
              ..where(
                (t) => t.companyId.equals(company) & t.lineId.equals(line),
              )
              ..limit(_maximumOperations + 1))
            .get();
    if (rows.length > _maximumOperations) {
      throw const JobLineRefusal('causal history capacity reached');
    }
    return rows
        .where((r) => r.admitted)
        .map(
          (r) => _Operation.parse(
            Uint8List.fromList(utf8.encode(r.operationBytes)),
          ),
        )
        .toList();
  }

  Future<JobLineCommandReceipt> _verifySavedReceipt(
    JobLineReceipt saved,
    _Operation operation, {
    JobLineReceipt? parent,
  }) async {
    final value = decodeJobLineReceipt(saved.receiptBytes);
    _validateReceiptPayload(
      value,
      saved,
      operation,
      _installation.identity!,
      _installation.receivingStoreGeneration!.value,
      sealed: true,
    );
    await JobLineCommandReceipt.verifyAdmissionSeal(
      saved.receiptBytes,
      _installation.identity!,
      _installation.receivingStoreGeneration!.value,
      expectedFamily: CompanyCommandFamily.jobLinePatch,
    );
    if (value['parent'] != null) {
      if (parent == null || parent.receiptKey != value['parent']) {
        throw const JobLineRefusal('linked receipt parent missing');
      }
      final original = await _verifySavedReceipt(parent, operation);
      if (original.status != 'deferred') {
        throw const JobLineRefusal('linked receipt parent was not deferred');
      }
    }
    return JobLineCommandReceipt._decode(saved.receiptBytes);
  }

  Future<JobLineCommandReceipt> _apply(
    _Operation operation, {
    required bool local,
    required bool resume,
    VerifiedJobLineSession? localSession,
    OwnerSession? localOwner,
  }) async {
    if (_db.hasCallerTransaction) {
      throw const JobLineRefusal('command must own its top-level transaction');
    }
    final command = _commandFromOperation(operation);
    await authorization._verifyCurrentReceiver(command);
    CompanyCommandIntent? intent;
    JobLineCommandReceipt? result;
    try {
      result = await _db.transaction(() async {
        try {
          // Obtain SQLite's write lock before the protected CAS. Recovery uses
          // this same lock, so it cannot clear a still-running command's intent.
          await _db.customStatement(
            'UPDATE app_settings SET value = value WHERE key = ?',
            [kInstallationBindingKey],
          );
          await authorization._verifyCurrentReceiver(command);
          if (local) {
            if (localSession == null ||
                localSession.command.commitment != command.commitment) {
              throw const JobLineRefusal(
                'current local retry authorization missing',
              );
            }
            final fresh = await authorization._verify(
              localSession.command,
              localSession._proof,
            );
            _validateLocalOwner(fresh, localOwner);
            for (final key in [
              'company',
              'shop',
              'line',
              'request',
              'generation',
              'installation',
              'device',
              'user',
              'command',
            ]) {
              if (operation.body[key] != fresh._assertion[key]) {
                throw const JobLineRefusal(
                  'local retry differs from current actor or command',
                );
              }
            }
          }
          final generation = _installation.receivingStoreGeneration;
          if (generation == null) {
            throw const JobLineRefusal('receiving generation missing');
          }
          final baseReceiptKey = _digest({
            'company': operation.company,
            'origin': operation.generation,
            'request': operation.id,
            'receiver': _installation.identity!.id.value,
            'store': generation.value,
          });
          final saved =
              await (_db.select(_db.jobLineReceipts)
                    ..where((t) => t.receiptKey.equals(baseReceiptKey)))
                  .getSingleOrNull();
          final existing =
              await (_db.select(_db.jobLineOperations)..where(
                    (t) =>
                        t.companyId.equals(operation.company) &
                        t.originGeneration.equals(operation.generation) &
                        t.requestId.equals(operation.id),
                  ))
                  .getSingleOrNull();
          if (existing != null &&
              (existing.commitment != operation.commitment ||
                  existing.operationBytes != operation.bytes)) {
            throw const JobLineRefusal(
              'operation ID reused with different bytes or actor',
            );
          }
          if (saved != null) {
            if (saved.operationCommitment != operation.commitment ||
                saved.commandCommitment != operation.commandCommitment) {
              throw const JobLineRefusal('receipt commitment collision');
            }
            if (existing == null) {
              throw const JobLineRefusal('receipt operation missing');
            }
            final original = await _verifySavedReceipt(saved, operation);
            if (!resume || original.status != 'deferred') return original;
            final transitions = <JobLineReceipt>[];
            for (final status in ['applied', 'conflict']) {
              final linked =
                  await (_db.select(_db.jobLineReceipts)..where(
                        (t) => t.receiptKey.equals(
                          _digest({
                            'parent': baseReceiptKey,
                            'transition': status,
                          }),
                        ),
                      ))
                      .getSingleOrNull();
              if (linked != null) transitions.add(linked);
            }
            if (transitions.length > 1) {
              throw const JobLineRefusal(
                'multiple semantic receipt transitions',
              );
            }
            if (transitions.isNotEmpty) {
              return await _verifySavedReceipt(
                transitions.single,
                operation,
                parent: saved,
              );
            }
            final known = (await _operations(
              operation.company,
              operation.line,
            )).map((o) => o.key).toSet();
            if (operation.parents.any((p) => !known.contains(p))) {
              return original;
            }
          }
          final verified = await authorization._verify(
            command,
            operation.authorization,
          );
          for (final key in [
            'company',
            'shop',
            'line',
            'request',
            'generation',
            'installation',
            'device',
            'user',
            'command',
            'facts',
          ]) {
            if (operation.body[key] != verified._assertion[key]) {
              throw const JobLineRefusal(
                'operation author or assertion differs',
              );
            }
          }
          await _verifySignature(
            operation.body,
            operation.signature,
            verified._publicKey,
            domain: 'wiredpart.job.line.operation@1:',
          );
          final signedBinding = verified._facts.entity(
            'jobLine',
            operation.line,
            shop: operation.shop,
          );
          if (signedBinding['baseline'] != operation.baseline) {
            throw const JobLineRefusal('unsigned or differing baseline');
          }
          final row = await (_db.select(
            _db.jobLines,
          )..where((t) => t.id.equals(operation.line))).getSingleOrNull();
          if (row == null) throw const JobLineRefusal('job line missing');
          final scopes = await (_db.select(
            _db.jobLineBaselines,
          )..where((t) => t.lineId.equals(operation.line))).get();
          if (scopes.any(
            (b) =>
                b.companyId != operation.company || b.shopId != operation.shop,
          )) {
            throw const JobLineRefusal(
              'job line already belongs to another scope',
            );
          }
          final stored = scopes.isEmpty ? null : scopes.single;
          if (stored != null &&
              (stored.baselineId != operation.baseline ||
                  stored.projectionBytes != _canonical(row.toJson()))) {
            throw const JobLineRefusal(
              'legacy writer changed managed projection',
            );
          }
          if (stored == null &&
              jobLineLegacyBaselineCommitment(
                    companyId: operation.company,
                    shopId: operation.shop,
                    row: row,
                  ) !=
                  operation.baseline) {
            throw const JobLineRefusal(
              'legacy baseline is not the signed state',
            );
          }
          final baseline = stored == null
              ? _LineState.fromRow(row)
              : _LineState(
                  _object(_object(jsonDecode(stored.baselineBytes))['state']),
                );
          final baselineRow = stored == null
              ? row.toJson()
              : _object(_object(jsonDecode(stored.baselineBytes))['row']);
          await _validateReferences(
            verified._facts,
            operation,
            row,
            _LineState({..._LineState.fromRow(row).units, ...operation.units}),
            requireActiveIdentity: operation.units.containsKey('identity'),
          );
          final operations = await _operations(
            operation.company,
            operation.line,
          );
          final storedCount =
              await (_db.select(_db.jobLineOperations)..where(
                    (t) =>
                        t.companyId.equals(operation.company) &
                        t.lineId.equals(operation.line),
                  ))
                  .get();
          if (existing == null && storedCount.length >= _maximumOperations) {
            throw const JobLineRefusal('operation storage capacity reached');
          }
          final storedGraph = {
            for (final r in storedCount)
              '${r.originGeneration}/${r.requestId}': _Operation.parse(
                Uint8List.fromList(utf8.encode(r.operationBytes)),
              ),
            operation.key: operation,
          };
          final visited = <String>{};
          void validateGraph(String key, Set<String> path) {
            if (path.contains(key)) throw const JobLineRefusal('causal cycle');
            if (visited.contains(key)) return;
            final node = storedGraph[key];
            if (node == null) return;
            for (final parent in node.parents) {
              validateGraph(parent, {...path, key});
            }
            visited.add(key);
          }

          validateGraph(operation.key, {});
          final known = operations.map((o) => o.key).toSet();
          if (operation.parents.contains(operation.key)) {
            throw const JobLineRefusal('operation depends on itself');
          }
          final missing = operation.parents.any((p) => !known.contains(p));
          if (local && missing) {
            throw const JobLineRefusal(
              'local command has an unobserved causal parent',
            );
          }
          if (missing && resume && saved != null) {
            return JobLineCommandReceipt._decode(saved.receiptBytes);
          }
          if (local && row.deletedAt != null) {
            throw const JobLineRefusal(
              'ordinary edit cannot restore deleted row',
            );
          }
          final observed = <String>{};
          void observe(String key) {
            if (!observed.add(key)) return;
            for (final parent in storedGraph[key]?.parents ?? <String>[]) {
              observe(parent);
            }
          }

          for (final parent in operation.parents) {
            observe(parent);
          }
          if (operations.any(
            (o) => o.units.containsKey('lifecycle') && observed.contains(o.key),
          )) {
            throw const JobLineRefusal('edit descends from deletion barrier');
          }
          final all = [
            ...operations.where((o) => o.key != operation.key),
            if (!missing) operation,
          ];
          final reduction = missing
              ? _Reduction(_LineState.fromRow(row), [])
              : _reduce(baseline, all);
          if (!missing) {
            await _validateReferences(
              verified._facts,
              operation,
              row,
              reduction.state,
              requireActiveIdentity: false,
            );
          }
          final status = missing
              ? 'deferred'
              : reduction.conflicts.isEmpty
              ? 'applied'
              : 'conflict';
          final receiptKey = resume && saved != null
              ? _digest({'parent': baseReceiptKey, 'transition': status})
              : baseReceiptKey;
          final transition = await (_db.select(
            _db.jobLineReceipts,
          )..where((t) => t.receiptKey.equals(receiptKey))).getSingleOrNull();
          if (transition != null) {
            return await _verifySavedReceipt(
              transition,
              operation,
              parent: saved,
            );
          }
          intent = CompanyCommandIntent(
            receiptKey: receiptKey,
            operationCommitment: operation.commitment,
            commandCommitment: operation.commandCommitment,
            storeGeneration: generation.value,
            companyId: operation.company,
            lineId: operation.line,
            originGeneration: operation.generation,
            requestId: operation.id,
          );
          intent = await _installation.beginCompanyCommand(
            _db,
            intent!,
            expectedTrust: verified._trust,
            expectedFloors: verified._floors,
          );
          if (stored == null) {
            await _db
                .into(_db.jobLineBaselines)
                .insert(
                  JobLineBaselinesCompanion.insert(
                    companyId: operation.company,
                    lineId: operation.line,
                    shopId: operation.shop,
                    baselineId: operation.baseline,
                    baselineBytes: _canonical({
                      'state': baseline.units,
                      'row': baselineRow,
                    }),
                    projectionBytes: _canonical(row.toJson()),
                  ),
                );
          }
          if (existing == null) {
            await _db
                .into(_db.jobLineOperations)
                .insert(
                  JobLineOperationsCompanion.insert(
                    companyId: operation.company,
                    originGeneration: operation.generation,
                    requestId: operation.id,
                    lineId: operation.line,
                    commitment: operation.commitment,
                    operationBytes: operation.bytes,
                    admitted: !missing,
                  ),
                );
          } else if (!missing && !existing.admitted) {
            await (_db.update(_db.jobLineOperations)..where(
                  (t) =>
                      t.companyId.equals(operation.company) &
                      t.originGeneration.equals(operation.generation) &
                      t.requestId.equals(operation.id),
                ))
                .write(const JobLineOperationsCompanion(admitted: Value(true)));
          }
          if (!missing) {
            await _writeProjection(
              row,
              reduction.state,
              (baselineRow['revision'] as num).toInt() + all.length,
            );
            final projected = await (_db.select(
              _db.jobLines,
            )..where((t) => t.id.equals(row.id))).getSingle();
            await (_db.update(
              _db.jobLineBaselines,
            )..where((t) => t.lineId.equals(row.id))).write(
              JobLineBaselinesCompanion(
                projectionBytes: Value(_canonical(projected.toJson())),
              ),
            );
            for (final conflict in reduction.conflicts) {
              final alternatives = _canonical({
                'candidates': conflict.candidates,
                'frontier': conflict.frontier.isEmpty
                    ? [operation.baseline]
                    : conflict.frontier,
              });
              final conflictId = _digest({
                'company': operation.company,
                'line': operation.line,
                'unit': conflict.unit,
                'alternatives': jsonDecode(alternatives),
              });
              await _db
                  .into(_db.jobLineConflicts)
                  .insert(
                    JobLineConflictsCompanion.insert(
                      conflictId: conflictId,
                      companyId: operation.company,
                      lineId: operation.line,
                      unit: conflict.unit,
                      alternativesBytes: alternatives,
                    ),
                    mode: InsertMode.insertOrIgnore,
                  );
            }
          }
          if (local && !missing) {
            await _db
                .into(_db.jobLineOutgoing)
                .insert(
                  JobLineOutgoingCompanion.insert(
                    companyId: operation.company,
                    originGeneration: operation.generation,
                    requestId: operation.id,
                    operationCommitment: operation.commitment,
                  ),
                  mode: InsertMode.insertOrIgnore,
                );
          }
          var receiptBytes = _canonicalReceipt({
            'v': 2,
            'key': receiptKey,
            'parent': resume && saved != null ? baseReceiptKey : null,
            'operation': operation.commitment,
            'command': operation.commandCommitment,
            'status': status,
            'bytes': base64Encode(utf8.encode(operation.bytes)),
            'receiver': _installation.identity!.id.value,
            'store': generation.value,
          });
          await _db
              .into(_db.jobLineReceipts)
              .insert(
                JobLineReceiptsCompanion.insert(
                  receiptKey: receiptKey,
                  companyId: operation.company,
                  operationCommitment: operation.commitment,
                  commandCommitment: operation.commandCommitment,
                  receiptBytes: receiptBytes,
                ),
              );
          await _db
              .into(_db.jobLineAudits)
              .insert(
                JobLineAuditsCompanion.insert(
                  receiptKey: receiptKey,
                  auditBytes: _canonical({
                    'operation': operation.commitment,
                    'originalUser': operation.body['user'],
                    'originalDevice': operation.body['device'],
                    'status': status,
                    'receipt': receiptKey,
                    'outgoing': local && !missing,
                  }),
                ),
              );
          final admission = VerifiedJobLineReceiptAdmission._(
            _db,
            receiptBytes,
            operation,
            verified,
            intent!,
          );
          final seal = await _installation.signCompanyReceipt(_db, admission);
          receiptBytes = _canonicalReceipt({
            ...decodeJobLineReceipt(receiptBytes, requireSeal: false),
            'seal': base64Encode(seal.bytes),
          });
          await (_db.update(
            _db.jobLineReceipts,
          )..where((t) => t.receiptKey.equals(receiptKey))).write(
            JobLineReceiptsCompanion(receiptBytes: Value(receiptBytes)),
          );
          intent = await _installation.sealCompanyCommand(_db, intent!);
          await beforeCommit?.call();
          await _installation.validateHeldCompanyCommand(
            _db,
            intent!,
            expectedTrust: verified._trust,
            expectedFloors: verified._floors,
          );
          return JobLineCommandReceipt._decode(receiptBytes);
        } finally {
          if (local && localSession?._assertion['v'] == 2) {
            _validateLocalOwner(localSession!, localOwner);
          }
        }
      });
    } catch (_) {
      if (intent != null) await _installation.reconcile(_db);
      rethrow;
    }
    if (intent != null) {
      await afterCommit?.call();
      try {
        await _installation.completeCompanyCommand(_db, intent!);
      } catch (_) {
        // The receipt is already durable. Keep protected recovery held and
        // return the original result, rather than inviting a new operation ID.
      }
    }
    return result!;
  }

  Future<void> _validateReferences(
    _CompanyFacts facts,
    _Operation operation,
    JobLine row,
    _LineState state, {
    required bool requireActiveIdentity,
  }) async {
    final job = await (_db.select(
      _db.jobs,
    )..where((t) => t.id.equals(row.jobId))).getSingleOrNull();
    if (job == null || job.deletedAt != null || job.status != 'active') {
      throw const JobLineRefusal('parent job is not active');
    }
    facts.entity('job', row.jobId, shop: operation.shop);
    final identity = _object(state.units['identity']);
    _validateUnits({
      'identity': identity,
      'quantities': state.units['quantities'],
      'notes': state.units['notes'],
      'customNotes': state.units['customNotes'],
    });
    if (identity['part'] case final String partId) {
      facts.entity('part', partId);
      final part = await (_db.select(
        _db.parts,
      )..where((t) => t.id.equals(partId))).getSingleOrNull();
      if (part == null ||
          (requireActiveIdentity && (part.deletedAt != null || !part.active))) {
        throw const JobLineRefusal('catalog part is not active');
      }
      if (identity['version'] case final String versionId) {
        facts.entity('brandVersion', versionId);
        final version = await (_db.select(
          _db.brandVersions,
        )..where((t) => t.id.equals(versionId))).getSingleOrNull();
        if (version == null ||
            version.partId != partId ||
            (requireActiveIdentity && version.deletedAt != null)) {
          throw const JobLineRefusal(
            'catalog version parent differs or is inactive',
          );
        }
      }
    }
  }

  Future<void> _writeProjection(
    JobLine row,
    _LineState state,
    int revision,
  ) async {
    final identity = _object(state.units['identity']);
    final quantities = _object(state.units['quantities']);
    final now = DateTime.now().toUtc();
    final deletedAt = state.deleted ? row.deletedAt ?? now : null;
    if (state.deleted) {
      await (_db.update(
        _db.orderSplits,
      )..where((t) => t.jobLineId.equals(row.id) & t.deletedAt.isNull())).write(
        OrderSplitsCompanion.custom(
          deletedAt: Variable(deletedAt),
          modifiedAt: Variable(now),
          revision: _db.orderSplits.revision + const Constant(1),
        ),
      );
    }
    await (_db.update(_db.jobLines)..where((t) => t.id.equals(row.id))).write(
      JobLinesCompanion(
        partId: Value(identity['part'] as String?),
        brandVersionId: Value(identity['version'] as String?),
        customName: Value(identity['custom'] as String?),
        customNotes: Value(state.units['customNotes'] as String?),
        neededQty: Value((quantities['needed'] as num).toDouble()),
        shopPullQty: Value((quantities['pull'] as num).toDouble()),
        uom: Value(quantities['unit'] as String?),
        notes: Value(state.units['notes'] as String?),
        revision: Value(revision),
        modifiedAt: Value(now),
        deletedAt: Value(deletedAt),
      ),
    );
  }
}
