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
