import '../../data/app_database.dart';

/// Supplier dropdowns for a job line.
///
/// A removed catalog part has no live listings. Do not strip stored split
/// suppliers in that case — Save would fail or wipe the original splits.
({List<Supplier> choices, bool preserveExistingSplits}) jobLineSupplierChoices({
  required List<Supplier> allSuppliers,
  required bool catalogPartMissing,
  required String? brandVersionId,
  required Set<String> listingSupplierIds,
  String? defaultSupplierId,
}) {
  if (catalogPartMissing) {
    return (
      choices: List<Supplier>.of(allSuppliers),
      preserveExistingSplits: true,
    );
  }
  if (brandVersionId != null) {
    return (
      choices: allSuppliers
          .where((s) => listingSupplierIds.contains(s.id))
          .toList(),
      preserveExistingSplits: false,
    );
  }
  final choices = List<Supplier>.of(allSuppliers);
  final preferred = defaultSupplierId;
  if (preferred != null) {
    choices.sort((a, b) {
      if (a.id == preferred) return -1;
      if (b.id == preferred) return 1;
      return a.name.compareTo(b.name);
    });
  }
  return (choices: choices, preserveExistingSplits: false);
}
