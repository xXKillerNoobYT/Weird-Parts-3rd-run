class JobSupplierSplit {
  const JobSupplierSplit({required this.supplierName, required this.qty});

  final String supplierName;
  final double qty;
}

/// Job-line math Isaac asked for: Requested, Split, Left to Pull/Order.
class JobLineQty {
  const JobLineQty({
    required this.requested,
    required this.shop,
    this.supplierSplits = const [],
  });

  final double requested;
  final double shop;
  final List<JobSupplierSplit> supplierSplits;

  double get ordered =>
      supplierSplits.fold<double>(0, (sum, split) => sum + split.qty);

  /// `Requested − shop − sum(supplier splits)`. Negative means over-split.
  double get leftToPullOrder => requested - shop - ordered;

  String get splitSummary {
    final parts = <String>[
      'Shop ${formatQty(shop)}',
      for (final split in supplierSplits)
        '${split.supplierName} ${formatQty(split.qty)}',
    ];
    return parts.join(' · ');
  }

  String get listSubtitle =>
      'Requested ${formatQty(requested)} · $splitSummary\n'
      'Left to Pull/Order ${formatQty(leftToPullOrder)}';
}

String formatQty(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toString();
}

/// Job list title for a catalog part, including a tombstone marker.
String jobLinePartListLabel({
  required String name,
  required bool removedFromCatalog,
}) =>
    removedFromCatalog ? '$name (removed)' : name;

/// Catalog-part picker subtitle on the line editor.
String jobLineCatalogPickLabel({
  required String name,
  String? brandVersionLabel,
  required bool removedFromCatalog,
}) {
  final labeled =
      brandVersionLabel == null ? name : '$name · $brandVersionLabel';
  return removedFromCatalog ? '$labeled (removed from catalog)' : labeled;
}

/// Supplier ids the job-line editor may keep selected.
///
/// Live catalog listings, plus ids already saved on the line when
/// [preserveExistingSplits] is true so opening a deleted part cannot blank
/// supplier splits. Picking a different live variance must pass false.
Set<String> jobLineEditorSupplierIds({
  required Iterable<String> listingSupplierIds,
  required Iterable<String?> existingSplitSupplierIds,
  bool preserveExistingSplits = false,
}) {
  final ids = listingSupplierIds.toSet();
  if (preserveExistingSplits) {
    ids.addAll(existingSplitSupplierIds.whereType<String>());
  }
  return ids;
}
