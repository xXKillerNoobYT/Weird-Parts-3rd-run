import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;

import '../../core/new_id.dart';

import '../../data/app_database.dart';
import '../catalog/part_details_dialog.dart';
import '../catalog/part_photo_store.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/part_write_companion.dart';
import '../company/company_store_markers.dart';
import '../jobs/jobs_repository.dart';
import '../jobs/catalog_promotion.dart';
import '../installation/installation_security.dart';
import '../pin/pin_service.dart';
import '../warehouse/warehouse_repository.dart';

part 'edit_draft_storage.dart';
part 'edit_draft_sessions.dart';

const editDraftPrefix = 'local_edit_v1/';

enum EditPhase {
  unpersisted,
  writing,
  durable,
  storageFailed,
  recoveryBlocked,
  saving,
  saveFailed,
  closed,
}

enum LeaveIntent { back, discard }

enum StorageChange { exit, replacement, reset }

final class EditStatus {
  const EditStatus(
    this.phase, {
    this.latestSequence = 0,
    this.durableSequence,
    this.error,
  });
  final EditPhase phase;
  final int latestSequence;
  final int? durableSequence;
  final Object? error;
}

final class NewJobInput {
  const NewJobInput({required this.nameText});
  final String nameText;
}

final class WarehouseCountInput {
  const WarehouseCountInput({
    required this.quantityText,
    required this.noteText,
    required this.observedAt,
  });
  final String quantityText, noteText;
  final DateTime observedAt;
}

final class PartInput {
  const PartInput({
    required this.nameText,
    required this.descriptionText,
    required this.specsText,
    required this.uomText,
    required this.categoryId,
    required this.styleId,
    required this.typeId,
    required this.defaultSupplierId,
    required this.active,
  });
  final String nameText, descriptionText, specsText, uomText;
  final String? categoryId, styleId, typeId, defaultSupplierId;
  final bool active;
}

final class SplitInput {
  const SplitInput({required this.supplierId, required this.quantityText});
  final String? supplierId;
  final String quantityText;
}

final class JobLineInput {
  JobLineInput({
    required this.useCustom,
    required this.partId,
    required this.brandVersionId,
    required this.customNameText,
    required this.neededText,
    required this.pullText,
    required this.customNotes,
    required this.uom,
    required this.notes,
    required List<SplitInput> splits,
  }) : splits = List.unmodifiable(splits);
  final bool useCustom;
  final String? partId, brandVersionId;
  final String customNameText, neededText, pullText;
  final String? customNotes, uom, notes;
  final List<SplitInput> splits;
}

sealed class EditOpening<S> {}

final class FreshEdit<S> extends EditOpening<S> {
  FreshEdit(this.session);
  final S session;
}

final class RecoverableEdit<S> extends EditOpening<S> {
  RecoverableEdit({required this._resume, required this._discard});
  final Future<S> Function() _resume;
  final Future<void> Function() _discard;
  Future<S> resume() => _resume();
  Future<void> discard() => _discard();
}

final class BlockedEdit<S> extends EditOpening<S> {
  BlockedEdit({
    required this.reason,
    required this.preservedInput,
    required this._discard,
  });
  final String reason;
  final String? preservedInput;
  final Future<void> Function() _discard;
  Future<void> discard() => _discard();
}

final class NewJobCreated extends EditOpening<NewJobEditSession> {
  NewJobCreated._({
    required this.id,
    required this.name,
    required this._acknowledge,
  });

  final String id, name;
  final Future<void> Function() _acknowledge;
  Future<void> acknowledge() => _acknowledge();
}

final class WarehouseCountSaved extends EditOpening<WarehouseCountEditSession> {
  WarehouseCountSaved._({required this.count, required this._acknowledge});
  final WarehouseCount count;
  final Future<void> Function() _acknowledge;
  Future<void> acknowledge() => _acknowledge();
}

final class PartSaved {
  const PartSaved(this.session);
  final PartEditSession session;
}

final class JobLinePromoted {
  const JobLinePromoted({
    required this.partId,
    required this.lineId,
    required this.session,
  });
  final String partId, lineId;
  final JobLineEditSession session;
}
