import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/jobs/job_line_qty.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';

import 'adapter.dart';
import 'fixture.dart';

enum MockScenarioStatus { pass, fail, notRun, blocked }

const _scenarioContractSha256 =
    '65b95deed97fa2ac37f9d6861bf0048303f4ae4e3d9267f43c079ace14644466';
const _automationContractSha256 =
    'ffb11ae2adecbb6dce2860762ac43b08ea0c7c7b67f60a40cfb9f50ac6dac679';

final class _ScenarioEvidence {
  const _ScenarioEvidence(this.observations, this.assertionEvidence);
  final Map<String, Object?> observations;
  final Map<String, List<String>> assertionEvidence;
}

const _blockedScenarios = <String, String>{
  'SCN-001': 'Verified test-app process exit/relaunch is not supplied by a database reopen.',
  'SCN-004':
      'No native receipt, transfer, movement or receipt-deduplication engine.',
  'SCN-005':
      'No native purchase draft cost/finalization or quote automation engine.',
  'SCN-007':
      'No native change-request, reservation-release or issue-history engine.',
  'SCN-008': 'No native purchase orders or partial receiving engine.',
  'SCN-009': 'No native over-receipt, damage disposition or delivery-variance automation.',
  'SCN-010':
      'No native reservation cancellation, return ledger or supplier credits.',
  'SCN-011': 'Native Job states are active/archived, not seven business workflow stages.',
  'SCN-012': 'No native eight-role staff or receiving permission matrix.',
  'SCN-013': 'Frozen case edits material-line notes; company Job-detail sync is a separate probe.',
  'SCN-014': 'No full catalog/stock/allocation company sync or verified process-cold restart.',
  'SCN-015': 'Full fixture company-scoped import/sync is unavailable; parser and command denials are separate probes.',
  'SCN-016': 'No process-crash driver or native movement/reservation/PO replay engine.',
  'SCN-017': 'No native stock-pick operation or approved distributed stock-spend policy.',
  'SCN-018': 'No remote material-line tombstone replay protocol.',
  'SCN-019': 'No native service-date scheduler or automation DST execution.',
  'SCN-020':
      'No native immutable purchase-order and receipt valuation snapshots.',
  'SCN-021': 'No native Job attachment corruption/repair workflow.',
  'SCN-022': 'No native automation trigger or draft runtime.',
  'SCN-023': 'No native automation claim, crash recovery or concurrent worker runtime.',
  'SCN-024': 'No native automation allowed-draft and forbidden-promotion action boundary.',
  'SCN-025': 'Repository arithmetic probes do not execute every required JobLineEditor field/error assertion.',
  'SCN-026':
      'Completed Riverbend lacks an admitted role-aware edit/reopen operation.',
  'SCN-027': 'Local split probes do not supply verified app process restart.',
};

final class MockScenarioRunner {
  MockScenarioRunner({
    required this.fixture,
    required this.scenarioDocument,
    required this.automationDocument,
    required this.sourceRevision,
  });
  final MockShopFixture fixture;
  final Map<String, dynamic> scenarioDocument;
  final Map<String, dynamic> automationDocument;
  final String sourceRevision;

  void _check(bool condition, String assertion) {
    if (!condition) {
      throw StateError('Mock scenario assertion failed: $assertion');
    }
  }

  Map<String, dynamic> _bindDocument(
    Map<String, dynamic> document,
    String expectedHash,
    String name,
  ) {
    final canonical = canonicalMockJson(document);
    _check(
      hashes.sha256.convert(utf8.encode(canonical)).toString() == expectedHash,
      'frozen $name contract changed',
    );
    return jsonDecode(canonical) as Map<String, dynamic>;
  }

  Future<Map<String, Object?>> run() async {
    final boundScenarios = _bindDocument(
      scenarioDocument,
      _scenarioContractSha256,
      'scenario',
    );
    final boundAutomations = _bindDocument(
      automationDocument,
      _automationContractSha256,
      'automation',
    );
    final scenarios = boundScenarios['scenarios'] as List;
    final plans = boundAutomations['plans'] as List;
    final ids = scenarios.map((s) => s['id'] as String).toSet();
    _check(
      scenarios.length == 28 &&
          ids.length == 28 &&
          List.generate(
            28,
            (i) => 'SCN-${(i + 1).toString().padLeft(3, '0')}',
          ).every(ids.contains),
      'complete frozen scenario registry',
    );
    _check(
      plans.length == 8 && plans.map((p) => p['id']).toSet().length == 8,
      'complete frozen automation registry',
    );
    final runId = const Uuid().v4();
    final outcomes = <Map<String, Object?>>[];
    for (final value in scenarios) {
      final spec = value as Map<String, dynamic>;
      final id = spec['id'] as String;
      if (id == 'SCN-028') continue;
      final reason = _blockedScenarios[id];
      if (reason != null) {
        outcomes.add({
          'scenario_id': id,
          'status': 'BLOCKED',
          'reason': reason,
          'evidence_refs': ['#/capability_prerequisites/$id'],
          'job_ids': spec['job_ids'],
          'assertions': [
            for (final a in spec['expected_assertions'] as List)
              {
                'assertion_id': a['assertion_id'],
                'status': 'BLOCKED',
                'reason': reason,
                'evidence_refs': ['#/capability_prerequisites/$id'],
              },
          ],
        });
        continue;
      }
      final outcomeIndex = outcomes.length;
      final target = await MockLocalWorkspace.create();
      try {
        await target.import(fixture);
        final evidence = switch (id) {
          'SCN-002' => await _colors(target),
          'SCN-003' => await _suppliers(target),
          'SCN-006' => await _allocations(target),
          _ => throw StateError('Unknown executable scenario: $id'),
        };
        final requiredIds = {
          for (final assertion in spec['expected_assertions'] as List)
            assertion['assertion_id'] as String,
        };
        _check(
          requiredIds.length == evidence.assertionEvidence.length &&
              requiredIds.containsAll(evidence.assertionEvidence.keys),
          '$id has evidence for every frozen assertion',
        );
        for (final keys in evidence.assertionEvidence.values) {
          _check(
            keys.isNotEmpty && keys.every(evidence.observations.containsKey),
            '$id assertion evidence points to recorded observations',
          );
        }
        outcomes.add({
          'scenario_id': id,
          'status': 'PASS',
          'scope': 'production repositories and persisted isolated SQLite',
          'reason': 'Every frozen assertion completed its persisted checks.',
          'evidence_refs': ['#/scenarios/$outcomeIndex/observations'],
          'namespace': '$runId/$id',
          'job_ids': spec['job_ids'],
          'observations': evidence.observations,
          'assertions': [
            for (final proof in evidence.assertionEvidence.entries)
              {
                'assertion_id': proof.key,
                'status': 'PASS',
                'reason': (spec['expected_assertions'] as List).singleWhere(
                  (a) => a['assertion_id'] == proof.key,
                )['expected'],
                'evidence_refs': [
                  for (final key in proof.value)
                    '#/scenarios/$outcomeIndex/observations/$key',
                ],
              },
          ],
        });
      } catch (error) {
        outcomes.add({
          'scenario_id': id,
          'status': 'FAIL',
          'job_ids': spec['job_ids'],
          'failure_type': error.runtimeType.toString(),
          'reason':
              'Supported scenario did not complete its persisted assertions.',
          'evidence_refs': ['#/scenarios/$outcomeIndex/failure_type'],
        });
      } finally {
        await target.close();
      }
    }
    final jobs = outcomes
        .expand((r) => (r['job_ids'] as List).cast<String>())
        .toSet();
    _check(jobs.containsAll(fixture.jobs.keys), 'all seven Jobs covered');
    _check(
      _blockedScenarios.keys.every(
        (id) =>
            outcomes.singleWhere((r) => r['scenario_id'] == id)['status'] ==
            'BLOCKED',
      ),
      'SCN-028 unsupported cases remain blocked',
    );
    outcomes.add({
      'scenario_id': 'SCN-028',
      'status': 'PASS',
      'scope': 'report aggregation only; blocked children remain blocked',
      'reason': 'Validated registry coverage, terminal reporting and execution boundaries.',
      'evidence_refs': ['#/report_checks'],
      'job_ids': fixture.jobs.keys.toList(),
      'assertions': [
        for (final proof in const {
          'SCN-028-A01': 'terminal_results',
          'SCN-028-A02': 'unsupported_cases',
          'SCN-028-A03': 'coverage',
          'SCN-028-A04': 'sync_acceptance',
          'SCN-028-A05': 'execution_boundary',
        }.entries)
          {
            'assertion_id': proof.key,
            'status': 'PASS',
            'reason': 'Report invariant validated at ${proof.value}.',
            'evidence_refs': ['#/report_checks/${proof.value}'],
          },
      ],
    });
    _check(
      outcomes.length == 28 &&
          outcomes.map((r) => r['scenario_id']).toSet().length == 28 &&
          outcomes.every(
            (r) =>
                const [
                  'PASS',
                  'FAIL',
                  'NOT_RUN',
                  'BLOCKED',
                ].contains(r['status']) &&
                (r['reason'] as String).isNotEmpty &&
                (r['evidence_refs'] as List).isNotEmpty,
          ),
      'SCN-028 concrete terminal results including aggregation',
    );
    return {
      'schema_version': '1.0.0',
      'run_id': runId,
      'source_revision': sourceRevision,
      'fixture_sha256': fixture.sha256Value,
      'finished_at_utc': DateTime.now().toUtc().toIso8601String(),
      'scope': 'same-host isolated app repositories; no native process or physical device acceptance',
      'contract_sha256': {
        'scenarios': _scenarioContractSha256,
        'automation_plans': _automationContractSha256,
      },
      'capability_prerequisites': {
        for (final entry in _blockedScenarios.entries)
          entry.key: {
            'missing': entry.value,
            'execution_evidence': 'none; case not executed',
            'contract': 'frozen scenarios.json#${entry.key}',
          },
        'automations': 'No native automation runtime; plans were not executed.',
      },
      'report_checks': {
        'terminal_results': {
          'case_count': outcomes.length,
          'unique_case_count': outcomes
              .map((r) => r['scenario_id'])
              .toSet()
              .length,
          'reason_and_evidence_required': true,
          'evidence_refs': ['#/scenarios'],
        },
        'unsupported_cases': {
          'blocked_case_ids': _blockedScenarios.keys.toList(),
          'fixture_validation_is_app_acceptance': false,
          'evidence_refs': ['#/capability_prerequisites', '#/scenarios'],
        },
        'coverage': {
          'jobs': {
            for (final id in fixture.jobs.keys)
              id: [
                for (final spec in scenarios)
                  if ((spec['job_ids'] as List).contains(id)) spec['id'],
              ],
          },
          'automations': {
            for (final plan in plans)
              plan['id'] as String: plan['scenario_ids'],
          },
        },
        'sync_acceptance': {
          'passing_sync_cases': <String>[],
          'required': 'terminal sender and receiver results and persisted readback after verified cold restarts',
          'evidence_refs': [
            '#/physical_windows_mac_sync',
            '#/process_cold_restart',
          ],
        },
        'execution_boundary': {
          'database': 'fresh owned temporary SQLite workspace for each executable case; closed and removed in finally',
          'operations': [
            'catalog reads and default supplier saves',
            'Job material-line saves and allocation readback',
          ],
          'external_effects': 'none',
          'automation_execution': 'BLOCKED',
        },
      },
      'jobs': {for (final e in fixture.jobs.entries) e.key: e.value['title']},
      'scenarios': outcomes,
      'automations': [
        for (final plan in plans)
          {
            'automation_id': plan['id'],
            'name': plan['name'],
            'status': 'BLOCKED',
            'reason': 'No native automation runtime.',
            'evidence_refs': ['#/capability_prerequisites/automations'],
          },
      ],
      'physical_windows_mac_sync': 'NOT_RUN',
      'native_secure_store': 'NOT_RUN',
      'process_cold_restart': 'NOT_RUN',
      'company_job_sync': {
        'status': 'NOT_RUN',
        'reason': 'Executed separately by mock_shop_sync_test.dart; not a substitute for material-line sync.',
      },
      'external_effects': 'none',
    };
  }

  Future<_ScenarioEvidence> _colors(MockLocalWorkspace target) async {
    final db = target.db;
    final catalog = CatalogRepository(db, target.pin, target.deviceId);
    final jobs = JobsRepository(db, target.deviceId);
    final maple = fixture.nativeId('job', 'JOB-001');
    final beforeMaple = canonicalMockJson(
      (await jobs.listLinesForJob(maple)).map((r) => r.toJson()).toList(),
    );
    final variants = [
      'part-leviton-r55-t5320-00e',
      'part-leviton-t5320-w',
      'part-lutron-cw-1-bl',
      'part-lutron-cw-1-wh',
      'part-leviton-m22-t5320-wmp',
    ];
    final searchable = await catalog.listParts();
    final saved = <String>[];
    for (final sourceId in variants) {
      final partId = fixture.nativeId('part', sourceId);
      _check(searchable.any((p) => p.id == partId), 'SCN-002 catalog search');
      final version = (await catalog.listBrandVersionsForPart(partId)).single;
      _check(
        version.varianceName == fixture.variants[sourceId]['color'],
        'SCN-002 variance identity',
      );
      final listing = await catalog.listingsForBrandVersion(version.id);
      _check(listing.isNotEmpty, 'SCN-002 supplier listings');
      saved.add(
        await jobs.addLine(
          jobId: fixture.nativeId('job', 'JOB-002'),
          partId: partId,
          brandVersionId: version.id,
          neededQty: 1,
          uom: 'ea',
          notes: sourceId,
        ),
      );
    }
    _check(saved.toSet().length == 5, 'SCN-002 distinct saved lines');
    final single = await catalog.listingsForBrandVersion(
      fixture.nativeId('brand-version', 'part-leviton-t5320-w'),
    );
    final pack = await catalog.listingsForBrandVersion(
      fixture.nativeId('brand-version', 'part-leviton-m22-t5320-wmp'),
    );
    _check(
      single.single.packageQty == 1 && pack.single.packageQty == 10,
      'SCN-002 pack identity',
    );
    final readback = <Map<String, Object?>>[];
    for (var i = 0; i < saved.length; i++) {
      final sourceId = variants[i];
      final line = (await jobs.getJobLine(saved[i]))!;
      _check(
        line.partId == fixture.nativeId('part', sourceId) &&
            line.brandVersionId ==
                fixture.nativeId('brand-version', sourceId) &&
            line.notes == sourceId &&
            line.neededQty == 1 &&
            line.uom == 'ea',
        'SCN-002 persisted cafe variant identity',
      );
      readback.add({
        'line': line.toJson(),
        'variant': await _variantReadback(catalog, sourceId),
      });
    }
    final afterMaple = canonicalMockJson(
      (await jobs.listLinesForJob(maple)).map((r) => r.toJson()).toList(),
    );
    _check(afterMaple == beforeMaple, 'SCN-002 Maple unchanged');
    return _ScenarioEvidence(
      {
        'saved_distinct_lines': saved.length,
        'selected_variants': readback,
        'single_pack_qty': single.single.packageQty,
        'ten_pack_qty': pack.single.packageQty,
        'maple_before': jsonDecode(beforeMaple),
        'maple_after': jsonDecode(afterMaple),
      },
      const {
        'SCN-002-A01': ['selected_variants', 'saved_distinct_lines'],
        'SCN-002-A02': ['selected_variants', 'saved_distinct_lines'],
        'SCN-002-A03': ['single_pack_qty', 'ten_pack_qty'],
        'SCN-002-A04': ['selected_variants'],
        'SCN-002-A05': ['maple_before', 'maple_after'],
      },
    );
  }

  Future<Map<String, Object?>> _variantReadback(
    CatalogRepository catalog,
    String sourceId,
  ) async {
    final source = fixture.variants[sourceId];
    final partId = fixture.nativeId('part', sourceId);
    final version = (await catalog.listBrandVersionsForPart(partId)).single;
    _check(
      version.id == fixture.nativeId('brand-version', sourceId) &&
          version.varianceName == (source['color'] ?? '') &&
          version.model == source['model_number'],
      'persisted variant color and model: $sourceId',
    );
    final expected = fixture.offers.values
        .where((o) => o['variant_id'] == sourceId)
        .toList();
    final actual = await catalog.listingsForBrandVersion(version.id);
    _check(
      actual.length == expected.length,
      'persisted offer count: $sourceId',
    );
    final readback = <Map<String, Object?>>[];
    for (final offer in expected) {
      final listing = actual.singleWhere(
        (l) => l.id == fixture.nativeId('offer', offer['id']),
      );
      final provenance = jsonDecode(listing.notes!);
      _check(
        listing.brandVersionId == version.id &&
            listing.supplierId ==
                fixture.nativeId('supplier', offer['supplier_id']) &&
            listing.sku == (offer['supplier_sku'] ?? '') &&
            listing.packageQty ==
                (source['quantity_per_sell_unit'] as num).toDouble() &&
            listing.lastPrice == (offer['price_usd'] as num?)?.toDouble() &&
            provenance['supplier_online_id'] == offer['supplier_online_id'] &&
            canonicalMockJson(provenance) == canonicalMockJson(offer),
        'persisted SKU, online ID, pack and price: ${offer['id']}',
      );
      readback.add({
        'source_offer_id': offer['id'],
        'listing': listing.toJson(),
        'supplier_online_id': provenance['supplier_online_id'],
      });
    }
    return {
      'source_variant_id': sourceId,
      'version': version.toJson(),
      'offers': readback,
    };
  }

  Future<_ScenarioEvidence> _suppliers(MockLocalWorkspace target) async {
    final catalog = CatalogRepository(target.db, target.pin, target.deviceId);
    final partId = fixture.nativeId('part', 'part-lutron-cw-1-wh');
    final version = fixture.nativeId('brand-version', 'part-lutron-cw-1-wh');
    final before = await catalog.listingsForBrandVersion(version);
    final frozen = canonicalMockJson(before.map((r) => r.toJson()).toList());
    for (final supplier in ['home-depot', 'lowes', 'platt', 'home-depot']) {
      final part = (await catalog.getPart(partId))!;
      await catalog.updatePart(
        partId: part.id,
        name: part.name,
        description: part.description,
        uom: part.uom,
        active: part.active,
        specs: part.specs,
        categoryId: part.categoryId,
        styleId: part.styleId,
        typeId: part.typeId,
        defaultSupplierId: fixture.nativeId('supplier', supplier),
      );
    }
    final after = await catalog.listingsForBrandVersion(version);
    _check(
      canonicalMockJson(after.map((r) => r.toJson()).toList()) == frozen,
      'SCN-003 offers unchanged after supplier selection',
    );
    _check(after.length == 3, 'SCN-003 three listings');
    final bySupplier = {for (final l in after) l.supplierId: l};
    final hd = bySupplier[fixture.nativeId('supplier', 'home-depot')]!;
    final lowes = bySupplier[fixture.nativeId('supplier', 'lowes')]!;
    final platt = bySupplier[fixture.nativeId('supplier', 'platt')]!;
    _check(
      hd.lastPrice == 4.97 &&
          lowes.lastPrice == 4.98 &&
          platt.lastPrice == null,
      'SCN-003 price snapshots',
    );
    _check(platt.sku == '0181973', 'SCN-003 leading zero');
    _check(
      jsonDecode(hd.notes!)['supplier_online_id'] != hd.sku,
      'SCN-003 online ID remains separate',
    );
    final variant = await _variantReadback(catalog, 'part-lutron-cw-1-wh');
    _check(
      (await catalog.getPart(partId))!.defaultSupplierId ==
          fixture.nativeId('supplier', 'home-depot'),
      'SCN-003 selected supplier saved',
    );
    return _ScenarioEvidence(
      {
        'variant': variant,
        'offers_before': jsonDecode(frozen),
        'offers_after': after.map((r) => r.toJson()).toList(),
        'selected_supplier_id': fixture.nativeId('supplier', 'home-depot'),
        'home_depot_usd': hd.lastPrice,
        'lowes_usd': lowes.lastPrice,
        'platt_usd': platt.lastPrice,
        'platt_sku': platt.sku,
      },
      const {
        'SCN-003-A01': ['variant'],
        'SCN-003-A02': ['home_depot_usd', 'lowes_usd', 'variant'],
        'SCN-003-A03': ['platt_usd', 'platt_sku'],
        'SCN-003-A04': [
          'offers_before',
          'offers_after',
          'variant',
          'selected_supplier_id',
        ],
        'SCN-003-A05': ['variant'],
      },
    );
  }

  Future<_ScenarioEvidence> _allocations(MockLocalWorkspace target) async {
    final repo = JobsRepository(target.db, target.deviceId);
    final jobId = fixture.nativeId('job', 'JOB-001');
    final before = await repo.listLinesForJob(jobId);
    // Native projection of expected-results.json#/job_quantity_snapshots/JOB-001.
    const expectedQuantities = {
      'MAT-001-01': (needed: 120.0, shop: 120.0, uom: 'ft'),
      'MAT-001-02': (needed: 24.0, shop: 24.0, uom: 'ea'),
      'MAT-001-03': (needed: 90.0, shop: 90.0, uom: 'ea'),
      'MAT-001-04': (needed: 4.0, shop: 4.0, uom: 'ea'),
      'MAT-001-05': (needed: 24.0, shop: 24.0, uom: 'ea'),
    };
    final changedId = fixture.nativeId('material', 'MAT-001-01');
    final supplierId = fixture.nativeId('supplier', 'home-depot');
    Future<Map<String, Object?>> readMaple({bool changed = false}) async {
      final lines = await repo.listLinesForJob(jobId);
      _check(
        lines.length == expectedQuantities.length,
        'SCN-006 all Maple lines',
      );
      final result = <String, Object?>{};
      for (final entry in expectedQuantities.entries) {
        final line = lines.singleWhere(
          (r) => r.id == fixture.nativeId('material', entry.key),
        );
        final source = fixture.materials[entry.key];
        final expected = entry.value;
        final splits = await repo.orderSplitsForLine(line.id);
        final isChanged = changed && line.id == changedId;
        _check(
          line.jobId == jobId &&
              line.partId == fixture.nativeId('part', source['variant_id']) &&
              line.brandVersionId ==
                  fixture.nativeId('brand-version', source['variant_id']) &&
              line.neededQty == expected.needed &&
              line.shopPullQty == expected.shop &&
              line.uom == expected.uom &&
              canonicalMockJson(jsonDecode(line.notes!)) ==
                  canonicalMockJson(source) &&
              splits.length == (isChanged ? 1 : 0),
          'SCN-006 persisted projection: ${entry.key}',
        );
        if (isChanged) {
          _check(
            splits.single.supplierId == supplierId &&
                splits.single.quantity == 3,
            'SCN-006 saved supplier allocation',
          );
        }
        final remaining = JobLineQty(
          requested: line.neededQty,
          shop: line.shopPullQty,
          supplierSplits: [
            for (final split in splits)
              JobSupplierSplit(
                supplierName: split.supplierId,
                qty: split.quantity,
              ),
          ],
        ).leftToPullOrder;
        _check(
          remaining == expected.needed - expected.shop - (isChanged ? 3 : 0),
          'SCN-006 remaining arithmetic: ${entry.key}',
        );
        result[entry.key] = {
          'line_id': line.id,
          'part_id': line.partId,
          'version_id': line.brandVersionId,
          'needed': line.neededQty,
          'shop': line.shopPullQty,
          'uom': line.uom,
          'supplier_allocations': [
            for (final split in splits)
              {'supplier_id': split.supplierId, 'qty': split.quantity},
          ],
          'remaining': remaining,
        };
      }
      return result;
    }

    Future<String> unrelatedJobs() async {
      final readback = <String, Object?>{};
      for (final id in fixture.jobs.keys.where((id) => id != 'JOB-001')) {
        final native = fixture.nativeId('job', id);
        final lines = await repo.listLinesForJob(native);
        readback[id] = {
          'job': (await repo.getJob(native))!.toJson(),
          'lines': lines.map((r) => r.toJson()).toList(),
          'splits': [
            for (final line in lines)
              (await repo.orderSplitsForLine(line.id))
                  .map((r) => r.toJson())
                  .toList(),
          ],
        };
      }
      return canonicalMockJson(readback);
    }

    Future<String> warehouse() async => canonicalMockJson(
      (await target.db.select(target.db.warehouseCounts).get())
          .map((r) => r.toJson())
          .toList(),
    );
    final baseline = await readMaple();
    final unrelatedBefore = await unrelatedJobs();
    final warehouseBefore = await warehouse();
    for (final line in before) {
      await repo.updateLine(
        lineId: line.id,
        partId: line.partId,
        brandVersionId: line.brandVersionId,
        customName: line.customName,
        customNotes: line.customNotes,
        neededQty: line.neededQty,
        shopPullQty: line.shopPullQty,
        uom: line.uom,
        notes: line.notes,
        splits: const [],
      );
    }
    final noChange = await readMaple();
    _check(
      canonicalMockJson(noChange) == canonicalMockJson(baseline),
      'SCN-006 no-change save preserves every line quantity',
    );
    final line = before.singleWhere((r) => r.id == changedId);
    Future<void> save(List<({String supplierId, double qty})> splits) =>
        repo.updateLine(
          lineId: line.id,
          partId: line.partId,
          brandVersionId: line.brandVersionId,
          customName: line.customName,
          customNotes: line.customNotes,
          neededQty: line.neededQty,
          shopPullQty: line.shopPullQty,
          uom: line.uom,
          notes: line.notes,
          splits: splits,
        );
    await save([(supplierId: supplierId, qty: 3)]);
    final changed = await readMaple(changed: true);
    for (final id in expectedQuantities.keys.where(
      (id) => id != 'MAT-001-01',
    )) {
      _check(
        canonicalMockJson(changed[id]) == canonicalMockJson(baseline[id]),
        'SCN-006 unrelated Maple line unchanged: $id',
      );
    }
    final unrelatedChanged = await unrelatedJobs();
    _check(
      unrelatedChanged == unrelatedBefore,
      'SCN-006 unrelated Jobs unchanged',
    );
    await save(const []);
    final restored = await readMaple();
    _check(
      canonicalMockJson(restored) == canonicalMockJson(baseline),
      'SCN-006 restored all expected quantities',
    );
    final unrelatedAfter = await unrelatedJobs();
    final warehouseAfter = await warehouse();
    _check(
      unrelatedAfter == unrelatedBefore && warehouseAfter == warehouseBefore,
      'SCN-006 unrelated Jobs and warehouse unchanged after restore',
    );
    return _ScenarioEvidence(
      {
        'projection': 'needed = planned; shop = issued - returned + reserved; supplier allocations initially empty; each -> ea',
        'expected_results_ref':
            'expected-results.json#/job_quantity_snapshots/JOB-001',
        'before': baseline,
        'no_change_save': noChange,
        'changed': changed,
        'restored': restored,
        'unrelated_jobs_before': jsonDecode(unrelatedBefore),
        'unrelated_jobs_after_change': jsonDecode(unrelatedChanged),
        'unrelated_jobs_after_restore': jsonDecode(unrelatedAfter),
        'warehouse_before': jsonDecode(warehouseBefore),
        'warehouse_after': jsonDecode(warehouseAfter),
        'allocation_is_order_or_receipt': false,
        'unsupported_operations': [
          'reservation execution',
          'consumption',
          'purchase submission',
          'receiving',
        ],
      },
      const {
        'SCN-006-A01': ['projection', 'before', 'changed', 'restored'],
        'SCN-006-A02': ['before', 'no_change_save'],
        'SCN-006-A03': [
          'before',
          'changed',
          'unrelated_jobs_before',
          'unrelated_jobs_after_change',
        ],
        'SCN-006-A04': [
          'projection',
          'expected_results_ref',
          'before',
          'restored',
        ],
        'SCN-006-A05': [
          'warehouse_before',
          'warehouse_after',
          'allocation_is_order_or_receipt',
          'unsupported_operations',
        ],
      },
    );
  }
}

Future<void> writeMockScenarioReceipt(
  File destination,
  Map<String, Object?> receipt,
) async {
  await destination.parent.create(recursive: true);
  final lock = File('${destination.path}.lock');
  await lock.create(exclusive: true);
  try {
    if (await destination.exists()) {
      throw StateError('Refusing to overwrite an existing run receipt');
    }
    final stage = File('${destination.path}.pending');
    await stage.create(exclusive: true);
    await stage.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
      flush: true,
    );
    await stage.rename(destination.path);
  } finally {
    await lock.delete();
  }
}
