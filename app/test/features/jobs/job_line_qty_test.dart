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
