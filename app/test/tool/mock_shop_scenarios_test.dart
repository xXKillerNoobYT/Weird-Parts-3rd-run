import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/mock_shop/fixture.dart';
import '../../tool/mock_shop/scenarios.dart';

bool _hasPointer(Object? document, String pointer) {
  Object? current = document;
  for (final segment in pointer.substring(2).split('/')) {
    final key = segment.replaceAll('~1', '/').replaceAll('~0', '~');
    if (current is Map && current.containsKey(key)) {
      current = current[key];
    } else if (current is List) {
      final index = int.tryParse(key);
      if (index == null || index < 0 || index >= current.length) return false;
      current = current[index];
    } else {
      return false;
    }
  }
  return true;
}

Iterable<String> _evidenceRefs(Object? document) sync* {
  if (document is Map) {
    for (final entry in document.entries) {
      if (entry.key == 'evidence_refs') {
        yield* (entry.value as List).cast<String>();
      } else {
        yield* _evidenceRefs(entry.value);
      }
    }
  } else if (document is List) {
    for (final value in document) {
      yield* _evidenceRefs(value);
    }
  }
}

void main() {
  test(
    'frozen scenario registry executes supported app operations honestly',
    () async {
      final root = Directory('test/fixtures/mock_shop');
      final fixture = MockShopFixture.read(root);
      final runner = MockScenarioRunner(
        fixture: fixture,
        scenarioDocument: jsonDecode(
          File('${root.path}/scenarios.json').readAsStringSync(),
        ) as Map<String, dynamic>,
        automationDocument: jsonDecode(
          File('${root.path}/automation-plans.json').readAsStringSync(),
        ) as Map<String, dynamic>,
        sourceRevision:
            Platform.environment['MOCK_SHOP_SOURCE_REVISION'] ?? 'UNRECORDED',
      );
      final result = await runner.run();
      final cases = result['scenarios'] as List;
      expect(cases, hasLength(28));
      expect(cases.map((r) => r['scenario_id']).toSet(), hasLength(28));
      expect(cases.where((r) => r['status'] == 'FAIL'), isEmpty);
      for (final id in ['SCN-002', 'SCN-003', 'SCN-006', 'SCN-028']) {
        expect(
          cases.singleWhere((r) => r['scenario_id'] == id)['status'],
          'PASS',
        );
      }
      expect(
        cases.singleWhere((r) => r['scenario_id'] == 'SCN-013')['status'],
        'BLOCKED',
      );
      expect(
        (result['automations'] as List).every((a) => a['status'] == 'BLOCKED'),
        isTrue,
      );
      expect(result['physical_windows_mac_sync'], 'NOT_RUN');
      for (final outcome in cases) {
        expect(outcome['reason'], isNotEmpty);
        expect(outcome['evidence_refs'], isNotEmpty);
        final spec = (runner.scenarioDocument['scenarios'] as List).singleWhere(
          (s) => s['id'] == outcome['scenario_id'],
        );
        if (outcome['status'] == 'PASS') {
          expect(
            (outcome['assertions'] as List)
                .map((a) => a['assertion_id'])
                .toSet(),
            (spec['expected_assertions'] as List)
                .map((a) => a['assertion_id'])
                .toSet(),
          );
        }
      }
      for (final ref in _evidenceRefs(result)) {
        expect(ref, startsWith('#/'));
        expect(_hasPointer(result, ref), isTrue, reason: ref);
      }
      final colors =
          cases.singleWhere(
                (r) => r['scenario_id'] == 'SCN-002',
              )['observations']
              as Map;
      final selected = colors['selected_variants'] as List;
      expect(selected, hasLength(5));
      expect(
        selected.map((r) => r['line']['brandVersionId']).toSet(),
        hasLength(5),
      );
      for (final row in selected) {
        final variant = row['variant'];
        final sourceId = variant['source_variant_id'];
        final offers = fixture.offers.values.where(
          (o) => o['variant_id'] == sourceId,
        );
        expect(variant['offers'], hasLength(offers.length));
        for (final offer in offers) {
          final saved = (variant['offers'] as List).singleWhere(
            (o) => o['source_offer_id'] == offer['id'],
          );
          expect(saved['listing']['sku'], offer['supplier_sku'] ?? '');
          expect(saved['listing']['lastPrice'], offer['price_usd']);
          expect(
            saved['listing']['packageQty'],
            fixture.variants[sourceId]['quantity_per_sell_unit'],
          );
          expect(saved['supplier_online_id'], offer['supplier_online_id']);
        }
      }
      final allocations =
          cases.singleWhere(
                (r) => r['scenario_id'] == 'SCN-006',
              )['observations']
              as Map;
      final before = allocations['before'] as Map;
      expect(before.keys.toSet(), {
        'MAT-001-01',
        'MAT-001-02',
        'MAT-001-03',
        'MAT-001-04',
        'MAT-001-05',
      });
      const expectedNeeded = [120, 24, 90, 4, 24];
      for (var i = 0; i < expectedNeeded.length; i++) {
        final id = 'MAT-001-0${i + 1}';
        expect(before[id]['needed'], expectedNeeded[i]);
        expect(before[id]['shop'], expectedNeeded[i]);
        expect(before[id]['remaining'], 0);
        expect(allocations['changed'][id]['remaining'], i == 0 ? -3 : 0);
      }
      expect(allocations['no_change_save'], before);
      expect(allocations['restored'], before);
      expect(
        allocations['unrelated_jobs_after_change'],
        allocations['unrelated_jobs_before'],
      );
      expect(
        allocations['unrelated_jobs_after_restore'],
        allocations['unrelated_jobs_before'],
      );
      expect(allocations['warehouse_after'], allocations['warehouse_before']);
      final coverage = (result['report_checks'] as Map)['coverage'] as Map;
      expect((coverage['automations'] as Map).values, everyElement(isNotEmpty));
      final output = Platform.environment['MOCK_SHOP_SCENARIO_RECEIPT'];
      if (output != null) {
        expect(
          RegExp(r'^[a-f0-9]{40}$')
              .hasMatch(result['source_revision'] as String),
          isTrue,
          reason: 'A saved receipt requires an exact source revision',
        );
        await writeMockScenarioReceipt(File(output), result);
      }
    },
  );

  for (final mutation in [
    'extra assertion',
    'changed assertion',
    'changed automation',
  ]) {
    test('rejects $mutation in a frozen contract before execution', () async {
      final root = Directory('test/fixtures/mock_shop');
      final scenarios = jsonDecode(
        File('${root.path}/scenarios.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final automations = jsonDecode(
        File('${root.path}/automation-plans.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final assertions =
          (scenarios['scenarios'] as List).singleWhere(
                (s) => s['id'] == 'SCN-002',
              )['expected_assertions']
              as List;
      switch (mutation) {
        case 'extra assertion':
          assertions.add({
            'assertion_id': 'SCN-002-A06',
            'expected': 'Unimplemented requirement',
          });
          break;
        case 'changed assertion':
          assertions.first['expected'] =
              'Changed requirement with the same assertion ID';
          break;
        case 'changed automation':
          automations['plans'][0]['name'] = 'Changed automation contract';
          break;
      }
      final runner = MockScenarioRunner(
        fixture: MockShopFixture.read(root),
        scenarioDocument: scenarios,
        automationDocument: automations,
        sourceRevision: 'UNRECORDED',
      );
      await expectLater(
        runner.run(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'contract failure',
            contains('contract changed'),
          ),
        ),
      );
    });
  }
}
