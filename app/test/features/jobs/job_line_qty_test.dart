import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/jobs/job_line_qty.dart';

void main() {
  test('requested 10, shop 4, A 3, B 3 → left 0', () {
    const qty = JobLineQty(
      requested: 10,
      shop: 4,
      supplierSplits: [
        JobSupplierSplit(supplierName: 'SupplyHouse', qty: 3),
        JobSupplierSplit(supplierName: 'Other', qty: 3),
      ],
    );
    expect(qty.ordered, 6);
    expect(qty.leftToPullOrder, 0);
    expect(qty.splitSummary, 'Shop 4 · SupplyHouse 3 · Other 3');
    expect(qty.listSubtitle, contains('Requested 10'));
    expect(qty.listSubtitle, contains('Left to Pull/Order 0'));
  });

  test('tombstoned listings still keep saved split supplier ids', () {
    const supplierId = 'supply-a';
    final wiped = jobLineEditorSupplierIds(
      listingSupplierIds: const [],
      existingSplitSupplierIds: const [supplierId],
    );
    expect(wiped, isEmpty);

    final kept = jobLineEditorSupplierIds(
      listingSupplierIds: const [],
      existingSplitSupplierIds: const [supplierId],
      preserveExistingSplits: true,
    );
    expect(kept, contains(supplierId));

    final fromListings = jobLineEditorSupplierIds(
      listingSupplierIds: const [supplierId],
      existingSplitSupplierIds: const [supplierId],
    );
    expect(fromListings, contains(supplierId));
  });

  test('picking a live variance drops suppliers not listed on it', () {
    const saved = 'supply-a';
    const listed = 'supply-b';
    final dropped = jobLineEditorSupplierIds(
      listingSupplierIds: const [listed],
      existingSplitSupplierIds: const [saved],
    );
    expect(dropped, equals({listed}));
    expect(dropped, isNot(contains(saved)));
  });

  test('job list and pick labels mark a removed catalog part', () {
    expect(
      jobLinePartListLabel(name: 'Isolation valve', removedFromCatalog: false),
      'Isolation valve',
    );
    expect(
      jobLinePartListLabel(name: 'Isolation valve', removedFromCatalog: true),
      'Isolation valve (removed)',
    );
    expect(
      jobLineCatalogPickLabel(
        name: 'Isolation valve',
        brandVersionLabel: 'Watts · W-123',
        removedFromCatalog: false,
      ),
      'Isolation valve · Watts · W-123',
    );
    expect(
      jobLineCatalogPickLabel(
        name: 'Isolation valve',
        brandVersionLabel: 'Watts · W-123',
        removedFromCatalog: true,
      ),
      'Isolation valve · Watts · W-123 (removed from catalog)',
    );
  });

  test('over-split shows a negative left', () {
    const qty = JobLineQty(
      requested: 10,
      shop: 4,
      supplierSplits: [
        JobSupplierSplit(supplierName: 'A', qty: 7),
      ],
    );
    expect(qty.leftToPullOrder, -1);
    expect(qty.listSubtitle, contains('Left to Pull/Order -1'));
  });
}
