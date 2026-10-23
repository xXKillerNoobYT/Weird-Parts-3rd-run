import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;

import '../../core/new_id.dart';

import '../../data/app_database.dart';
import '../catalog/part_photo_store.dart';
import '../catalog/catalog_repository.dart';
import '../catalog/part_write_companion.dart';
import '../company/company_store_markers.dart';
import '../jobs/jobs_repository.dart';
import '../jobs/catalog_promotion.dart';
import '../installation/installation_security.dart';
import '../maintenance/maintenance_repository.dart';
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

enum CatalogNameKind { category, type, variant, brand, supplier }

final class CatalogNameTarget {
  const CatalogNameTarget._(
    this.kind,
    this.isRename, {
    this.id,
    this.parentId,
    this.listingVersionId,
  });

  const CatalogNameTarget.newCategory()
    : this._(CatalogNameKind.category, false);

  const CatalogNameTarget.newBrand() : this._(CatalogNameKind.brand, false);

  const CatalogNameTarget.newSupplier()
    : this._(CatalogNameKind.supplier, false);

  factory CatalogNameTarget.newSupplierForVersion(String brandVersionId) =>
      CatalogNameTarget._(
        CatalogNameKind.supplier,
        false,
        listingVersionId: _identity(brandVersionId),
      );

  factory CatalogNameTarget.newType(String categoryId) => CatalogNameTarget._(
    CatalogNameKind.type,
    false,
    parentId: _identity(categoryId),
  );

  factory CatalogNameTarget.newVariant(String styleId) => CatalogNameTarget._(
    CatalogNameKind.variant,
    false,
    parentId: _identity(styleId),
  );

  factory CatalogNameTarget.renameCategory(String id) =>
      CatalogNameTarget._(CatalogNameKind.category, true, id: _identity(id));

  factory CatalogNameTarget.renameType(String id) =>
      CatalogNameTarget._(CatalogNameKind.type, true, id: _identity(id));

  factory CatalogNameTarget.renameVariant(String id) =>
      CatalogNameTarget._(CatalogNameKind.variant, true, id: _identity(id));

  factory CatalogNameTarget.renameBrand(String id) =>
      CatalogNameTarget._(CatalogNameKind.brand, true, id: _identity(id));

  final CatalogNameKind kind;
  final bool isRename;
  final String? id, parentId, listingVersionId;

  static String _identity(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, 'id', 'Catalog identity is required');
    }
    return value;
  }
}

final class CatalogNameInput {
  const CatalogNameInput({required this.nameText});
  final String nameText;
}

final class VarianceInput {
  const VarianceInput({
    required this.brandId,
    required this.varianceNameText,
    required this.mpnText,
    required this.isMain,
  });
  final String? brandId;
  final String varianceNameText, mpnText;
  final bool isMain;
}

final class SupplierListingInput {
  const SupplierListingInput({required this.supplierId, required this.skuText});
  final String? supplierId;
  final String skuText;
}

final class WarehouseLocationNameInput {
  const WarehouseLocationNameInput({required this.nameText});
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

final class NewPartInput {
  const NewPartInput({
    required this.nameText,
    required this.categoryId,
    required this.styleId,
    required this.typeId,
  });
  final String nameText;
  final String? categoryId, styleId, typeId;
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

final class _JobLineDraftInput {
  const _JobLineDraftInput(this.line, [this.promotion]);
  final JobLineInput line;
  final _PendingPromotion? promotion;
}

final class _PendingPromotion {
  _PendingPromotion({
    required this.generation,
    required this.partId,
    required this.details,
    required this.references,
  });
  final String generation, partId;
  final NewPartInput details;
  final Map<String, String> references;
}

final class JobLinePromotion {
  JobLinePromotion._(this._parent, this._generation);
  final JobLineEditSession _parent;
  final String _generation;
  NewPartInput get initial => _parent._pending(_generation).details;
  ValueListenable<EditStatus> get status => _parent.status;
  void replace(NewPartInput input) =>
      _parent._replacePromotion(_generation, input);
  Future<void> flush() => _parent._flushPromotion(_generation);
  Future<void> cancel() => _parent._cancelPromotion(_generation);
  Future<JobLinePromoted> promote() => _parent._promote(_generation);
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

final class VarianceCreated extends EditOpening<NewVarianceEditSession> {
  VarianceCreated._({
    required this.id,
    required this.partId,
    required this.brandId,
    required this.originDeviceId,
    required this.createdAt,
    required this._acknowledge,
  });
  final String id, partId, brandId, originDeviceId;
  final DateTime createdAt;
  final Future<void> Function() _acknowledge;
  bool identifies(BrandVersion variance) =>
      variance.id == id &&
      variance.partId == partId &&
      variance.brandId == brandId &&
      variance.originDeviceId == originDeviceId &&
      variance.createdAt.toUtc() == createdAt &&
      variance.deletedAt == null;
  Future<void> acknowledge() => _acknowledge();
}

final class NewPartCreated extends EditOpening<NewPartEditSession> {
  NewPartCreated._({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.styleId,
    required this.typeId,
    required this.originDeviceId,
    required this.createdAt,
    required this._acknowledge,
  });

  final String id, name, categoryId, styleId, typeId, originDeviceId;
  final DateTime createdAt;
  final Future<void> Function() _acknowledge;
  bool identifies(Part part) =>
      part.id == id &&
      part.originDeviceId == originDeviceId &&
      part.createdAt.toUtc() == createdAt &&
      part.deletedAt == null;
  Future<void> acknowledge() => _acknowledge();
}

final class CatalogNameSaved extends EditOpening<CatalogNameEditSession> {
  CatalogNameSaved._({
    required this.kind,
    required this.id,
    required this.name,
    required this._acknowledge,
  });

  final CatalogNameKind kind;
  final String id, name;
  final Future<void> Function() _acknowledge;
  Future<void> acknowledge() => _acknowledge();
}

final class SupplierListingSaved
    extends EditOpening<SupplierListingEditSession> {
  SupplierListingSaved._({required this.listing, required this._acknowledge});
  final SupplierListing listing;
  final Future<void> Function() _acknowledge;
  Future<void> acknowledge() => _acknowledge();
}

final class WarehouseCountSaved extends EditOpening<WarehouseCountEditSession> {
  WarehouseCountSaved._({required this.count, required this._acknowledge});
  final WarehouseCount count;
  final Future<void> Function() _acknowledge;
  Future<void> acknowledge() => _acknowledge();
}

final class WarehouseLocationSaved
    extends EditOpening<WarehouseLocationEditSession> {
  WarehouseLocationSaved._({
    required this.location,
    required this._acknowledge,
  });
  final WarehouseLocation location;
  final Future<void> Function() _acknowledge;
  Future<void> acknowledge() => _acknowledge();
}

final class PartSaved {
  const PartSaved(this.session);
  final PartEditSession session;
}

final class JobLinePromoted extends EditOpening<JobLineEditSession> {
  JobLinePromoted._({
    required this.partId,
    required this.lineId,
    required this.name,
    required this.categoryId,
    required this.styleId,
    required this.typeId,
    required this.continuation,
    required this._acknowledgeAndContinue,
  });
  final String partId, lineId, name, categoryId, styleId, typeId;
  final JobLineInput continuation;
  final Future<JobLineEditSession> Function() _acknowledgeAndContinue;
  Future<JobLineEditSession> acknowledgeAndContinue() =>
      _acknowledgeAndContinue();
}
