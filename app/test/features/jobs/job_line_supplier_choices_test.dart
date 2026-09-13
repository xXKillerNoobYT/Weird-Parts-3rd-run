import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/job_line_supplier_choices.dart';

Supplier _supplier(String id, String name) => Supplier(
      id: id,
      name: name,
      originDeviceId: 'd',
      createdAt: DateTime.utc(2026),
      modifiedAt: DateTime.utc(2026),
      revision: 1,
    );

void main() {
  final a = _supplier('a', 'A');
  final b = _supplier('b', 'B');

  test('missing catalog part keeps all suppliers and stored splits', () {
    final result = jobLineSupplierChoices(
      allSuppliers: [a, b],
      catalogPartMissing: true,
      brandVersionId: 'bv',
      listingSupplierIds: {},
    );
    expect(result.choices.map((s) => s.id), ['a', 'b']);
    expect(result.preserveExistingSplits, isTrue);
  });

  test('live brand version only offers listing suppliers', () {
    final result = jobLineSupplierChoices(
      allSuppliers: [a, b],
      catalogPartMissing: false,
      brandVersionId: 'bv',
      listingSupplierIds: {'b'},
    );
    expect(result.choices.map((s) => s.id), ['b']);
    expect(result.preserveExistingSplits, isFalse);
  });
}
