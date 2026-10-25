import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

const mockShopSourceSha256 =
    'e938bee1e13dba5ca2d6a4b966969c098668f6c05a389fc0bda3dcd07d7ffb69';
const mockShopFixtureSha256 =
    '690005c0461ee072c099d8d15bad1989d908d4f50633ff3c2960b3c509223851';

String canonicalMockJson(Object? value) {
  Object? sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: sorted(v[k])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

Map<String, dynamic> _map(Object? value, String label) {
  if (value is! Map || value.keys.any((k) => k is! String)) {
    throw FormatException('Expected object: $label');
  }
  return Map<String, dynamic>.from(value);
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final e in value.entries) e.key as String: _freeze(e.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

final class MockShopFixture {
  MockShopFixture._(this.raw, this.sha256Value);

  final Map<String, dynamic> raw;
  final String sha256Value;
  String get id => raw['fixture_id'] as String;
  DateTime get asOf => DateTime.parse(raw['as_of'] as String);
  Map<String, dynamic> get shop => raw['shop'] as Map<String, dynamic>;
  Map<String, dynamic> get catalog => raw['catalog'] as Map<String, dynamic>;
  Map<String, dynamic> get jobs => raw['jobs'] as Map<String, dynamic>;
  Map<String, dynamic> get materials =>
      raw['job_material_lines'] as Map<String, dynamic>;
  Map<String, dynamic> get locations =>
      raw['locations'] as Map<String, dynamic>;
  List<dynamic> get stock => raw['stock_snapshot'] as List<dynamic>;
  Map<String, dynamic> get variants =>
      catalog['variants'] as Map<String, dynamic>;
  Map<String, dynamic> get offers => catalog['offers'] as Map<String, dynamic>;
  Map<String, dynamic> get suppliers =>
      catalog['suppliers'] as Map<String, dynamic>;

  String nativeId(String family, String sourceId) => const Uuid().v5(
    Namespace.url.value,
    'wired-parts/mock-shop/v1/$id/$family/$sourceId',
  );

  static MockShopFixture read(Directory directory) => decode(
    File('${directory.path}/shop.json').readAsBytesSync(),
    readSourceBytes(directory),
  );

  static List<int> readSourceBytes(Directory directory) {
    final raw = File('${directory.path}/source-catalog.json');
    final compressed = File('${directory.path}/source-catalog.json.gz');
    final hasRaw = raw.existsSync();
    final hasCompressed = compressed.existsSync();
    _require(
      hasRaw != hasCompressed,
      'Expected exactly one frozen catalog encoding: JSON or gzip',
    );
    return hasRaw
        ? raw.readAsBytesSync()
        : gzip.decode(compressed.readAsBytesSync());
  }

  static MockShopFixture decode(
    List<int> bytes,
    List<int> sourceBytes, {
    bool requireFrozen = true,
  }) {
    final hash = sha256.convert(bytes).toString();
    final sourceHash = sha256.convert(sourceBytes).toString();
    if (requireFrozen) {
      _require(hash == mockShopFixtureSha256, 'Unexpected fixture hash');
      _require(sourceHash == mockShopSourceSha256, 'Unexpected catalog hash');
    }
    final d = _map(jsonDecode(utf8.decode(bytes)), 'fixture');
    final source = _map(jsonDecode(utf8.decode(sourceBytes)), 'source catalog');
    _require(d['synthetic'] == true, 'Only synthetic fixtures are admitted');
    _require(
      d['fixture_id'] == 'mock-electrical-shop-v1',
      'Unknown fixture ID',
    );
    _require(d['schema_version'] == '1.0.0', 'Unsupported fixture schema');
    final shop = _map(d['shop'], 'shop');
    _require(shop['id'] == 'SHOP-001', 'Wrong fixture shop');
    final asOf = DateTime.tryParse(d['as_of']?.toString() ?? '');
    _require(
      asOf != null && (d['as_of'] as String).contains('-06:00'),
      'Missing fixed offset-aware fixture clock',
    );
    final cat = _map(d['catalog'], 'catalog');
    final variants = _map(cat['variants'], 'variants');
    final offers = _map(cat['offers'], 'offers');
    final suppliers = _map(cat['suppliers'], 'suppliers');
    _require(
      variants.length == 59 && offers.length == 66 && suppliers.length == 4,
      'Fixture catalog counts changed',
    );
    final reference = _map(d['catalog_reference'], 'catalog reference');
    _require(
      reference['sha256'] == sourceHash,
      'Catalog source binding changed',
    );
    for (final name in ['variants', 'offers', 'suppliers']) {
      final sourceRows = source[name] as List;
      final keyed = {for (final row in sourceRows) row['id']: row};
      _require(
        canonicalMockJson(cat[name]) == canonicalMockJson(keyed),
        'Embedded source records changed: $name',
      );
    }
    for (final e in variants.entries) {
      final v = _map(e.value, e.key);
      _require(v['id'] == e.key, 'Variant identity mismatch');
      _require(
        v['stock_unit'] == 'each' || v['stock_unit'] == 'ft',
        'Unsupported stock unit',
      );
      _require(
        v['quantity_per_sell_unit'] is int && v['quantity_per_sell_unit'] > 0,
        'Invalid pack conversion',
      );
      _require(
        v['model_number'] is String &&
            v['brand'] is String &&
            v['category'] is String &&
            v['name'] is String,
        'Missing variant fields',
      );
    }
    for (final e in offers.entries) {
      final o = _map(e.value, e.key);
      _require(
        o['id'] == e.key &&
            variants.containsKey(o['variant_id']) &&
            suppliers.containsKey(o['supplier_id']),
        'Orphan supplier offer',
      );
      final price = o['price_usd'];
      _require(
        price == null || price is num && price.isFinite && price > 0,
        'Invalid price or null handling',
      );
      _require(
        (o['supplier_sku'] == null || o['supplier_sku'] is String) &&
            (o['supplier_online_id'] == null ||
                o['supplier_online_id'] is String),
        'Retail identifiers must remain strings',
      );
    }
    final jobs = _map(d['jobs'], 'jobs');
    final lines = _map(d['job_material_lines'], 'material lines');
    final locations = _map(d['locations'], 'locations');
    _require(
      jobs.length == 7 && lines.length == 40 && locations.length == 11,
      'Fixture job or location counts changed',
    );
    final claimed = <String>{};
    for (final e in jobs.entries) {
      final j = _map(e.value, e.key);
      _require(
        j['id'] == e.key && j['shop_id'] == 'SHOP-001',
        'Job identity or shop mismatch',
      );
      _require(
        j['title'] is String && (j['title'] as String).isNotEmpty,
        'Missing Job title',
      );
      for (final lid in j['material_line_ids'] as List) {
        _require(
          lines.containsKey(lid) && claimed.add(lid as String),
          'Duplicate or missing material line',
        );
        final l = _map(lines[lid], lid);
        _require(l['job_id'] == e.key, 'Material owner mismatch');
      }
    }
    _require(claimed.length == lines.length, 'Orphan material record');
    for (final e in lines.entries) {
      final l = _map(e.value, e.key);
      _require(
        l['id'] == e.key &&
            jobs.containsKey(l['job_id']) &&
            variants.containsKey(l['variant_id']),
        'Orphan material reference',
      );
      final offer = offers[l['preferred_offer_id']];
      _require(
        offer is Map && offer['variant_id'] == l['variant_id'],
        'Wrong material offer',
      );
      _require(
        l['stock_unit'] == variants[l['variant_id']]['stock_unit'],
        'Material stock unit changed',
      );
      for (final field in [
        'planned_qty',
        'reserved_qty',
        'issued_qty',
        'consumed_qty',
        'returned_qty',
        'staged_qty',
        'unallocated_qty',
      ]) {
        _require(l[field] is int && l[field] >= 0, 'Invalid material quantity');
      }
      _require(
        l['issued_qty'] >= l['consumed_qty'] + l['returned_qty'],
        'Material usage exceeds issued stock',
      );
    }
    final seen = <String>{};
    final stock = d['stock_snapshot'] as List;
    for (final row in stock) {
      final r = _map(row, 'stock observation');
      _require(
        locations.containsKey(r['location_id']) &&
            variants.containsKey(r['variant_id']),
        'Orphan stock observation',
      );
      final locationId = r['location_id'] as String;
      final variantId = r['variant_id'] as String;
      final key = '$locationId/$variantId';
      _require(seen.add(key), 'Duplicate stock observation');
      for (final field in ['on_hand_qty', 'reserved_qty', 'available_qty']) {
        _require(r[field] is int && r[field] >= 0, 'Invalid stock quantity');
      }
    }
    _require(stock.length == 649, 'Incomplete stock observations');
    return MockShopFixture._(_freeze(d) as Map<String, dynamic>, hash);
  }
}
