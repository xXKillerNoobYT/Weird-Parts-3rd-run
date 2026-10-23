part of 'edit_drafts.dart';

const _rowLimit = 256 * 1024;
const _splitLimit = 512;

void _newPartTarget(Map<String, String> target) {
  if (target['kind'] != 'part-new' ||
      target.length != 2 ||
      !target.containsKey('reserved') ||
      target.values.any((value) => value.trim().isEmpty)) {
    throw const FormatException('Invalid new Part target');
  }
}

void _supplierListingTarget(Map<String, String> target) {
  const fields = {'kind', 'part', 'listingVersion', 'reserved'};
  if (target['kind'] != 'supplier-listing-new' ||
      target.length != fields.length ||
      !fields.every(target.containsKey) ||
      target.values.any((value) => value.trim().isEmpty)) {
    throw const FormatException('Invalid supplier listing target');
  }
}

extension _CatalogNameStore on CatalogNameKind {
  String get _table => switch (this) {
    CatalogNameKind.category => 'categories',
    CatalogNameKind.type => 'styles',
    CatalogNameKind.variant => 'types',
    CatalogNameKind.brand => 'brands',
    CatalogNameKind.supplier => 'suppliers',
  };

  String? get _parentColumn => switch (this) {
    CatalogNameKind.category => null,
    CatalogNameKind.type => 'category_id',
    CatalogNameKind.variant => 'style_id',
    CatalogNameKind.brand => null,
    CatalogNameKind.supplier => null,
  };
}

CatalogNameKind _catalogNameKind(String? value) => switch (value) {
  'category' => CatalogNameKind.category,
  'type' => CatalogNameKind.type,
  'variant' => CatalogNameKind.variant,
  'brand' => CatalogNameKind.brand,
  'supplier' => CatalogNameKind.supplier,
  _ => throw const FormatException('Unsupported catalog name entity'),
};

void _catalogNameTarget(Map<String, String> target) {
  final kind = _catalogNameKind(target['entity']);
  final rename = target['kind'] == 'catalog-name-rename';
  if (!rename && target['kind'] != 'catalog-name-new') {
    throw const FormatException('Unsupported catalog name target');
  }
  if (rename && kind == CatalogNameKind.supplier) {
    throw const FormatException('Supplier rename is unsupported');
  }
  final listing = target.containsKey('listingVersion');
  final expected = {
    'kind',
    'entity',
    rename ? 'id' : 'reserved',
    if (!rename && kind._parentColumn != null) 'parent',
    if (!rename && kind == CatalogNameKind.supplier && listing) ...{
      'listingVersion',
      'listingReserved',
    },
  };
  if (target.length != expected.length ||
      !expected.every(target.containsKey) ||
      target.values.any((value) => value.trim().isEmpty)) {
    throw const FormatException('Invalid catalog name target');
  }
}

Set<String> _catalogNameResultFields(Map<String, String> result) {
  final kind = _catalogNameKind(result['entity']);
  var listing = false;
  if (kind == CatalogNameKind.supplier) {
    final target = _strings(jsonDecode(_text(result['target'])));
    _catalogNameTarget(target);
    if (target['entity'] != kind.name) {
      throw const FormatException('Saved supplier target mismatch');
    }
    listing = target.containsKey('listingVersion');
  }
  return {
    'entity',
    'id',
    'name',
    'row',
    'slot',
    'target',
    if (kind._parentColumn != null) 'parent',
    if (kind == CatalogNameKind.variant) 'category',
    if (listing) ...{'listing', 'listingRow', 'listingPart'},
  };
}

String? _catalogNameParent(CatalogNameKind kind, Map<String, Object?> row) {
  final column = kind._parentColumn;
  return column == null ? null : _text(row[column]);
}

String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
String _encoded(Object value) {
  final text = jsonEncode(value);
  if (utf8.encode(text).length > _rowLimit) {
    throw StateError(
      'Unfinished edits exceed the device storage limit. Your input is still in this form.',
    );
  }
  return text;
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Invalid unfinished edits');
  }
  return value;
}

String _text(Object? value) {
  if (value is! String) throw const FormatException('Invalid unfinished text');
  return value;
}

String? _nullable(Object? value) => value == null ? null : _text(value);
bool _boolean(Object? value) {
  if (value is! bool) throw const FormatException('Invalid unfinished option');
  return value;
}

Map<String, String> _strings(Object? value) =>
    _map(value).map((key, value) => MapEntry(key, _text(value)));
void _keys(Map<String, Object?> value, Set<String> expected) {
  if (value.length != expected.length || !expected.every(value.containsKey)) {
    throw const FormatException('Unsupported unfinished edit fields');
  }
}

Map<String, String> _parseOrigin(Object? value) {
  final origin = _strings(value);
  final expected = origin['mode'] == 'device'
      ? {'mode', 'device'}
      : {'mode', 'device', 'installation', 'generation'};
  if (origin.length != expected.length ||
      !expected.every(origin.containsKey) ||
      !{'device', 'installed'}.contains(origin['mode']) ||
      origin.values.any((v) => v.isEmpty)) {
    throw const FormatException('Invalid unfinished edit origin');
  }
  return origin;
}

Map<String, Object?> _control(String raw) {
  if (utf8.encode(raw).length > _rowLimit) {
    throw const FormatException(
      'Unfinished edit control exceeds the storage limit',
    );
  }
  final value = _map(jsonDecode(raw));
  final phase = _text(value['phase']);
  if (phase == 'editing') {
    _keys(value, {'phase', 'token'});
  } else if (phase == 'committed') {
    _keys(value, {'phase', 'token', 'command', 'result', 'origin'});
    final command = _text(value['command']);
    final result = _strings(value['result']);
    final expected = command == 'part-create'
        ? {
            'id',
            'name',
            'category',
            'style',
            'type',
            'device',
            'createdAt',
            'slot',
            'target',
          }
        : command == 'part-save'
        ? {'part'}
        : command == 'job-create'
        ? {'job', 'name'}
        : command == 'warehouse-count-save'
        ? {'count', 'location', 'part', 'row'}
        : command == 'warehouse-location-create' ||
              command == 'warehouse-location-rename'
        ? {'location', 'row'}
        : command == 'catalog-name-create' || command == 'catalog-name-rename'
        ? _catalogNameResultFields(result)
        : command == 'supplier-listing-create'
        ? {'id', 'row', 'slot', 'target'}
        : command == 'line-save' || command == 'line-remove'
        ? {'line'}
        : command.startsWith('line-promote/')
        ? {'part', 'line'}
        : <String>{};
    if (expected.isEmpty ||
        expected.length != result.length ||
        !expected.every(result.containsKey) ||
        result.values.any((v) => v.isEmpty)) {
      throw const FormatException('Invalid committed edit result');
    }
    _parseOrigin(value['origin']);
  } else {
    throw const FormatException('Unsupported unfinished edit phase');
  }
  if (_text(value['token']).isEmpty) {
    throw const FormatException('Invalid unfinished edit session');
  }
  return value;
}

Map<String, Object?> _inputJson(Object input) => switch (input) {
  SupplierListingInput l => {'supplier': l.supplierId, 'sku': l.skuText},
  CatalogNameInput c => {'name': c.nameText},
  NewJobInput j => {'name': j.nameText},
  WarehouseLocationNameInput l => {'name': l.nameText},
  WarehouseCountInput c => {
    'quantity': c.quantityText,
    'note': c.noteText,
    'observedAt': c.observedAt.toUtc().toIso8601String(),
  },
  NewPartInput p => {
    'name': p.nameText,
    'category': p.categoryId,
    'style': p.styleId,
    'type': p.typeId,
  },
  PartInput p => {
    'name': p.nameText,
    'description': p.descriptionText,
    'specs': p.specsText,
    'uom': p.uomText,
    'category': p.categoryId,
    'style': p.styleId,
    'type': p.typeId,
    'supplier': p.defaultSupplierId,
    'active': p.active,
  },
  JobLineInput j => {
    'custom': j.useCustom,
    'part': j.partId,
    'brandVersion': j.brandVersionId,
    'name': j.customNameText,
    'needed': j.neededText,
    'pull': j.pullText,
    'customNotes': j.customNotes,
    'uom': j.uom,
    'notes': j.notes,
    'splits': [
      for (final s in j.splits)
        {'supplier': s.supplierId, 'quantity': s.quantityText},
    ],
  },
  _ => throw StateError('Unsupported editing input'),
};
Object _parseInput(String kind, Object? value) {
  final m = _map(value);
  if (kind == 'supplier-listing-new') {
    _keys(m, {'supplier', 'sku'});
    return SupplierListingInput(
      supplierId: _nullable(m['supplier']),
      skuText: _text(m['sku']),
    );
  }
  if (kind == 'catalog-name-new' || kind == 'catalog-name-rename') {
    _keys(m, {'name'});
    return CatalogNameInput(nameText: _text(m['name']));
  }
  if (kind == 'warehouse-location-new' || kind == 'warehouse-location-rename') {
    _keys(m, {'name'});
    return WarehouseLocationNameInput(nameText: _text(m['name']));
  }
  if (kind == 'warehouse-count') {
    _keys(m, {'quantity', 'note', 'observedAt'});
    final text = _text(m['observedAt']);
    final observed = DateTime.tryParse(text);
    if (observed == null || observed.toUtc().toIso8601String() != text) {
      throw const FormatException('Invalid unfinished observation time');
    }
    return WarehouseCountInput(
      quantityText: _text(m['quantity']),
      noteText: _text(m['note']),
      observedAt: observed,
    );
  }
  if (kind == 'job-new') {
    _keys(m, {'name'});
    return NewJobInput(nameText: _text(m['name']));
  }
  if (kind == 'part-new') {
    _keys(m, {'name', 'category', 'style', 'type'});
    return NewPartInput(
      nameText: _text(m['name']),
      categoryId: _nullable(m['category']),
      styleId: _nullable(m['style']),
      typeId: _nullable(m['type']),
    );
  }
  if (kind == 'part') {
    _keys(m, {
      'name',
      'description',
      'specs',
      'uom',
      'category',
      'style',
      'type',
      'supplier',
      'active',
    });
    return PartInput(
      nameText: _text(m['name']),
      descriptionText: _text(m['description']),
      specsText: _text(m['specs']),
      uomText: _text(m['uom']),
      categoryId: _nullable(m['category']),
      styleId: _nullable(m['style']),
      typeId: _nullable(m['type']),
      defaultSupplierId: _nullable(m['supplier']),
      active: _boolean(m['active']),
    );
  }
  _keys(m, {
    'custom',
    'part',
    'brandVersion',
    'name',
    'needed',
    'pull',
    'customNotes',
    'uom',
    'notes',
    'splits',
  });
  final values = m['splits'];
  if (values is! List || values.length > _splitLimit) {
    throw const FormatException('Invalid unfinished supplier splits');
  }
  return JobLineInput(
    useCustom: _boolean(m['custom']),
    partId: _nullable(m['part']),
    brandVersionId: _nullable(m['brandVersion']),
    customNameText: _text(m['name']),
    neededText: _text(m['needed']),
    pullText: _text(m['pull']),
    customNotes: _nullable(m['customNotes']),
    uom: _nullable(m['uom']),
    notes: _nullable(m['notes']),
    splits: [for (final v in values) _parseSplit(v)],
  );
}

SplitInput _parseSplit(Object? value) {
  final m = _map(value);
  _keys(m, {'supplier', 'quantity'});
  return SplitInput(
    supplierId: _nullable(m['supplier']),
    quantityText: _text(m['quantity']),
  );
}

String _slot(Map<String, String> target) {
  String segment(String key) => Uri.encodeComponent(target[key]!);
  if (target['kind'] == 'supplier-listing-new') {
    return 'supplier-listing-new/${segment('listingVersion')}';
  }
  if (target['kind'] == 'catalog-name-new') {
    return 'catalog-name-new/${segment('entity')}'
        '${target.containsKey('parent') ? '/${segment('parent')}' : ''}'
        '${target.containsKey('listingVersion') ? '/version/${segment('listingVersion')}' : ''}';
  }
  if (target['kind'] == 'catalog-name-rename') {
    return 'catalog-name-rename/${segment('entity')}/${segment('id')}';
  }
  if (target['kind'] == 'part') return 'part/${segment('id')}';
  if (target['kind'] == 'job-new') return 'job-new';
  if (target['kind'] == 'part-new') return 'part-new';
  if (target['kind'] == 'warehouse-location-new') {
    return 'warehouse-location-new';
  }
  if (target['kind'] == 'warehouse-location-rename') {
    return 'warehouse-location-rename/${segment('id')}';
  }
  if (target['kind'] == 'warehouse-count') {
    return 'warehouse-count/${segment('location')}/${segment('part')}';
  }
  return target.containsKey('line')
      ? 'job-line/${segment('job')}/${segment('line')}'
      : 'job-line-new/${segment('job')}';
}

final class _DraftRecord {
  _DraftRecord({
    required this.target,
    required this.origin,
    required this.base,
    required this.references,
    required this.token,
    required this.input,
    this.sequence = 0,
  });
  final Map<String, String> target, origin;
  Map<String, String> base;
  final Map<String, String> references;
  final String token;
  Object input;
  int sequence;
  String get slot => _slot(target);
  String get inputKey => '$editDraftPrefix$slot/input';
  String get controlKey => '$editDraftPrefix$slot/control';
  Map<String, Object?> toJson() => {
    'v': 1,
    'target': target,
    'origin': origin,
    'base': base,
    'references': references,
    'token': token,
    'sequence': sequence,
    'input': _inputJson(input),
  };
  factory _DraftRecord.parse(String raw) {
    if (utf8.encode(raw).length > _rowLimit) {
      throw const FormatException('Unfinished edits exceed the storage limit');
    }
    final m = _map(jsonDecode(raw));
    _keys(m, {
      'v',
      'target',
      'origin',
      'base',
      'references',
      'token',
      'sequence',
      'input',
    });
    if (m['v'] != 1) {
      throw const FormatException('Unsupported unfinished edit version');
    }
    final target = _strings(m['target']);
    if (target['kind'] == 'supplier-listing-new') {
      _supplierListingTarget(target);
    } else if (target['kind'] == 'catalog-name-new' ||
        target['kind'] == 'catalog-name-rename') {
      _catalogNameTarget(target);
    } else if (target['kind'] == 'part-new') {
      _newPartTarget(target);
    } else if (target['kind'] == 'part') {
      if (target.length != 2 || !target.containsKey('id')) {
        throw const FormatException('Invalid Part target');
      }
    } else if (target['kind'] == 'job-new') {
      if (target.length != 2 || !target.containsKey('reserved')) {
        throw const FormatException('Invalid new Job target');
      }
    } else if (target['kind'] == 'warehouse-location-new') {
      if (target.length != 2 || !target.containsKey('reserved')) {
        throw const FormatException('Invalid new warehouse target');
      }
    } else if (target['kind'] == 'warehouse-location-rename') {
      final revision = int.tryParse(target['revision'] ?? '');
      if (target.length != 3 ||
          !target.containsKey('id') ||
          revision == null ||
          revision < 1 ||
          target['revision'] != revision.toString()) {
        throw const FormatException('Invalid warehouse rename target');
      }
    } else if (target['kind'] == 'warehouse-count') {
      final expected = {
        'kind',
        'location',
        'part',
        'reserved',
        'uom',
        if (target.containsKey('prior')) 'prior',
      };
      if (target.length != expected.length ||
          !expected.every(target.containsKey) ||
          target['uom']!.trim().isEmpty ||
          target['uom'] != target['uom']!.trim()) {
        throw const FormatException('Invalid warehouse count target');
      }
    } else if (target['kind'] == 'line') {
      if (!target.containsKey('job') ||
          !target.containsKey('reserved') ||
          target.length != (target.containsKey('line') ? 4 : 3)) {
        throw const FormatException('Invalid Job line target');
      }
      if (target.containsKey('line') && target['reserved'] != target['line']) {
        throw const FormatException('Invalid existing line identity');
      }
    } else {
      throw const FormatException('Unsupported unfinished edit target');
    }
    if (target.values.any((v) => v.isEmpty)) {
      throw const FormatException('Empty unfinished edit identity');
    }
    final origin = _parseOrigin(m['origin']);
    final sequence = m['sequence'];
    if (sequence is! int || sequence < 1) {
      throw const FormatException('Invalid unfinished edit sequence');
    }
    final token = _text(m['token']);
    if (token.isEmpty) {
      throw const FormatException('Invalid unfinished edit session');
    }
    return _DraftRecord(
      target: target,
      origin: origin,
      base: _strings(m['base']),
      references: _strings(m['references']),
      token: token,
      sequence: sequence,
      input: _parseInput(target['kind']!, m['input']),
    );
  }
}

class EditDrafts {
  EditDrafts({
    required this._db,
    required this._pin,
    required this._deviceId,
    this._installation,
  });
  final AppDatabase _db;
  final PinService _pin;
  final String _deviceId;
  final InstallationSecurity? _installation;
  final Map<String, _EditSession> _active = {};
  Future<void>? _tail;
  bool _closed = false;
  bool _quiescing = false;

  Future<T> _queue<T>(Future<T> Function() action) {
    final previous = _tail;
    final next = previous == null
        ? Future<T>.sync(action)
        : previous.then((_) => action());
    final drained = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tail = drained;
    unawaited(
      drained.then<void>((_) {
        if (identical(_tail, drained)) _tail = null;
      }),
    );
    return next;
  }

  Map<String, String> _origin() {
    final installation = _installation;
    if (installation == null ||
        installation.readiness == InstallationReadiness.unsupported) {
      return {'mode': 'device', 'device': _deviceId};
    }
    final identity = installation.identity;
    if (installation.readiness != InstallationReadiness.ready ||
        identity == null) {
      throw StateError(
        'Installation identity is unavailable. Unfinished input cannot be acknowledged as saved.',
      );
    }
    return {
      'mode': 'installed',
      'device': _deviceId,
      'installation': identity.id.value,
      'generation': identity.generation.value,
    };
  }

  Future<String?> _read(String key) => _db.settingsDao.getSetting(key);
  Future<void> _delete(String key) =>
      _db.customStatement('DELETE FROM app_settings WHERE key = ?', [key]);
  Future<void> _set(String key, Object value) =>
      _db.settingsDao.setSetting(key, _encoded(value));
  Future<Map<String, Object?>?> _row(String table, String id) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM $table WHERE id = ?',
          variables: [Variable(id)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data;
  }

  Future<Map<String, String>> _base(Map<String, String> target) async {
    if (target['kind'] == 'part-new') {
      final part = await _row('parts', target['reserved']!);
      if (part != null) throw StateError('Reserved Part ID is already in use');
      return {'part': _digest(part)};
    }
    if (target['kind'] == 'supplier-listing-new') {
      final context = await _supplierListingContext(target);
      final listing = await _row('supplier_listings', target['reserved']!);
      if (listing != null) {
        throw StateError('Reserved supplier listing ID is already in use');
      }
      return {
        'listing': _digest(listing),
        for (final entry in context.entries) entry.key: _digest(entry.value),
      };
    }
    if (target['kind'] == 'catalog-name-new' ||
        target['kind'] == 'catalog-name-rename') {
      final kind = _catalogNameKind(target['entity']);
      final rename = target['kind'] == 'catalog-name-rename';
      final row = await _row(kind._table, target[rename ? 'id' : 'reserved']!);
      if (rename && (row == null || row['deleted_at'] != null)) {
        throw StateError('Catalog record is unavailable');
      }
      if (!rename && row != null) {
        throw StateError('Reserved catalog ID is already in use');
      }
      final ancestors = await _catalogNameAncestors(
        kind,
        rename ? _catalogNameParent(kind, row!) : target['parent'],
      );
      final listing = await _supplierListingContext(target);
      if (target.containsKey('listingReserved') &&
          await _row('supplier_listings', target['listingReserved']!) != null) {
        throw StateError('Reserved supplier listing ID is already in use');
      }
      return {
        'record': _digest(row),
        for (final entry in ancestors.entries) entry.key: _digest(entry.value),
        for (final entry in listing.entries)
          'listing${entry.key}': _digest(entry.value),
      };
    }
    if (target['kind'] == 'warehouse-location-new') {
      final row = await _row('warehouse_locations', target['reserved']!);
      if (row != null) {
        throw StateError('Reserved warehouse ID is already in use');
      }
      return {'location': _digest(row)};
    }
    if (target['kind'] == 'warehouse-location-rename') {
      final row = await _row('warehouse_locations', target['id']!);
      if (row == null || row['deleted_at'] != null) {
        throw StateError('Warehouse location is unavailable');
      }
      if (row['revision'].toString() != target['revision']) {
        throw StateError('Location changed. Reload before renaming.');
      }
      return {'location': _digest(row)};
    }
    if (target['kind'] == 'warehouse-count') {
      final location = await _row('warehouse_locations', target['location']!);
      final part = await _row('parts', target['part']!);
      if (location == null || location['deleted_at'] != null) {
        throw StateError('Warehouse location is unavailable');
      }
      if (part == null || part['deleted_at'] != null) {
        throw StateError('Part is no longer in the catalog');
      }
      if (target['uom']!.isEmpty ||
          part['uom'].toString().trim() != target['uom']) {
        throw StateError(
          'Part unit changed. Reload and recount without conversion.',
        );
      }
      final heads = await _db
          .customSelect(
            'SELECT * FROM warehouse_counts WHERE location_id = ? AND part_id = ? '
            'ORDER BY ordinal DESC LIMIT 1',
            variables: [
              Variable(target['location']!),
              Variable(target['part']!),
            ],
          )
          .get();
      final head = heads.isEmpty ? null : heads.single.data;
      if (head?['id'] != target['prior']) {
        throw StateError('Count changed. Cancel and reload before recounting.');
      }
      final reserved = await _row('warehouse_counts', target['reserved']!);
      if (reserved != null) {
        throw StateError('Reserved count ID is already in use');
      }
      return {
        'location': _digest(location),
        'part': _digest(part),
        'head': _digest(head),
        'count': _digest(reserved),
      };
    }
    if (target['kind'] == 'job-new') {
      final job = await _row('jobs', target['reserved']!);
      if (job != null) throw StateError('Reserved Job ID is already in use');
      return {'job': _digest(job)};
    }
    if (target['kind'] == 'part') {
      final row = await _row('parts', target['id']!);
      if (row == null || row['deleted_at'] != null) {
        throw StateError('Part no longer exists');
      }
      return {'part': _digest(row)};
    }
    final job = await _row('jobs', target['job']!);
    if (job == null || job['deleted_at'] != null) {
      throw StateError('Parent Job no longer exists');
    }
    final line = await _row('job_lines', target['reserved']!);
    if (target.containsKey('line')) {
      if (line == null ||
          line['deleted_at'] != null ||
          line['job_id'] != target['job']) {
        throw StateError('Job line no longer belongs to this Job');
      }
    } else if (line != null) {
      throw StateError('Reserved Job line ID is already in use');
    }
    final splits = await _db
        .customSelect(
          'SELECT * FROM order_splits WHERE job_line_id = ? ORDER BY id',
          variables: [Variable(target['reserved']!)],
        )
        .get();
    return {
      'job': _digest(job),
      'line': _digest(line),
      'splits': _digest(splits.map((r) => r.data).toList()),
    };
  }

  Future<Map<String, String>> _references(Object input) async {
    final ids = <String, String>{};
    void add(String table, String? id) {
      if (id != null) ids['$table/$id'] = table;
    }

    switch (input) {
      case SupplierListingInput l:
        add('suppliers', l.supplierId);
      case CatalogNameInput():
        break;
      case NewJobInput():
        break;
      case WarehouseLocationNameInput():
        break;
      case WarehouseCountInput():
        break;
      case NewPartInput p:
        add('categories', p.categoryId);
        add('styles', p.styleId);
        add('types', p.typeId);
      case PartInput p:
        add('categories', p.categoryId);
        add('styles', p.styleId);
        add('types', p.typeId);
        add('suppliers', p.defaultSupplierId);
      case JobLineInput j:
        add('parts', j.partId);
        add('brand_versions', j.brandVersionId);
        for (final split in j.splits) {
          add('suppliers', split.supplierId);
        }
    }
    return {
      for (final entry in ids.entries)
        entry.key: _digest(
          await _row(entry.value, entry.key.substring(entry.value.length + 1)),
        ),
    };
  }

  Future<void> _check(_DraftRecord record) async {
    if (_closed) throw StateError('This storage generation is closed');
    if (_digest(_origin()) != _digest(record.origin)) {
      throw StateError(
        'Unfinished edits belong to another device or installation',
      );
    }
    if (_digest(await _base(record.target)) != _digest(record.base)) {
      throw StateError(
        'The saved record changed. These unfinished edits need review.',
      );
    }
    final current = await _references(record.input);
    for (final entry in current.entries) {
      if (record.references[entry.key] != entry.value) {
        throw StateError(
          'A selected reference changed or is unavailable. Unfinished input is preserved.',
        );
      }
    }
  }

  Future<void> _requireReferences(_DraftRecord record) async {
    final current = await _references(record.input);
    for (final key in current.keys) {
      final at = key.indexOf('/');
      final row = await _row(key.substring(0, at), key.substring(at + 1));
      if (row == null || row['deleted_at'] != null) {
        final baseline = record.target.containsKey('line')
            ? await _db.jobsDao.getJobLine(record.target['line']!)
            : null;
        final inheritedPart =
            baseline?.partId != null && key == 'parts/${baseline!.partId}';
        final inheritedBrand =
            baseline?.brandVersionId != null &&
            key == 'brand_versions/${baseline!.brandVersionId}';
        final inheritedSplit =
            record.target.containsKey('line') &&
            (await _db.jobsDao.orderSplitsForLine(record.target['line']!))
                .any((s) => key == 'suppliers/${s.supplierId}');
        if (!inheritedPart && !inheritedBrand && !inheritedSplit) {
          throw StateError('A selected reference no longer exists');
        }
      }
    }
    final hierarchy = switch (record.input) {
      NewPartInput p => (p.categoryId, p.styleId, p.typeId),
      PartInput p => (p.categoryId, p.styleId, p.typeId),
      _ => null,
    };
    if (hierarchy case (final categoryId, final styleId, final typeId)) {
      if (styleId != null) {
        final style = await _row('styles', styleId);
        if (style != null && style['category_id'] != categoryId) {
          throw StateError('Type belongs to another Category');
        }
      }
      if (typeId != null) {
        final type = await _row('types', typeId);
        if (type != null && type['style_id'] != styleId) {
          throw StateError('Variant belongs to another Type');
        }
      }
    }
    if (record.input case JobLineInput j) {
      if (j.brandVersionId != null) {
        final brand = await _row('brand_versions', j.brandVersionId!);
        if (brand != null && brand['part_id'] != j.partId) {
          throw StateError('Brand version belongs to another Part');
        }
      }
    }
  }

  Future<Map<String, Object?>> _catalogNameRow(
    CatalogNameKind kind,
    String id,
  ) async {
    final row = await _row(kind._table, id);
    if (row == null || row['deleted_at'] != null) {
      throw StateError('Catalog record is unavailable');
    }
    return row;
  }

  Future<Map<String, Map<String, Object?>>> _supplierListingContext(
    Map<String, String> target,
  ) async {
    final versionId = target['listingVersion'];
    if (versionId == null) return {};
    final version = await _row('brand_versions', versionId);
    if (version == null || version['deleted_at'] != null) {
      throw StateError('Supplier listing variance is unavailable');
    }
    final part = await _row('parts', _text(version['part_id']));
    if (part == null || part['deleted_at'] != null) {
      throw StateError('Supplier listing Part is unavailable');
    }
    if (target['kind'] == 'supplier-listing-new' &&
        version['part_id'] != target['part']) {
      throw StateError('Supplier listing variance belongs to another Part');
    }
    return {'Version': version, 'Part': part};
  }

  Future<EditOpening<SupplierListingEditSession>> openSupplierListing({
    required String brandVersionId,
    required String partId,
    required SupplierListingInput initial,
  }) {
    final target = {
      'kind': 'supplier-listing-new',
      'part': partId,
      'listingVersion': brandVersionId,
      'reserved': newId(),
    };
    _supplierListingTarget(target);
    return _open<SupplierListingEditSession>(
      target,
      () async => initial,
      (record) => SupplierListingEditSession._(this, record),
      onCommitted: (raw) => _savedSupplierListing(raw, target),
    );
  }

  Future<SupplierListingSaved> _savedSupplierListing(
    String raw,
    Map<String, String> wanted,
  ) async {
    if (_closed || _quiescing) throw StateError('Catalog storage is changing');
    final control = _control(raw);
    if (control['phase'] != 'committed' ||
        control['command'] != 'supplier-listing-create') {
      throw const FormatException('Unsupported saved supplier listing receipt');
    }
    final result = _strings(control['result']);
    final target = _strings(jsonDecode(result['target']!));
    _supplierListingTarget(target);
    if (result['id'] != target['reserved'] ||
        result['slot'] != _slot(target) ||
        result['slot'] != _slot(wanted) ||
        ![
          'kind',
          'part',
          'listingVersion',
        ].every((key) => target[key] == wanted[key])) {
      throw const FormatException('Saved supplier listing target mismatch');
    }
    Future<SupplierListing> validate() async {
      if (_digest(_origin()) != _digest(control['origin'])) {
        throw StateError(
          'Saved supplier listing belongs to another installation',
        );
      }
      await _supplierListingContext(target);
      final row = await _row('supplier_listings', result['id']!);
      if (row == null ||
          row['deleted_at'] != null ||
          row['origin_device_id'] != _deviceId ||
          row['brand_version_id'] != target['listingVersion'] ||
          _digest(row) != result['row']) {
        throw StateError(
          'The saved supplier listing changed or is unavailable',
        );
      }
      final supplier = await _row('suppliers', _text(row['supplier_id']));
      if (supplier == null || supplier['deleted_at'] != null) {
        throw StateError('The saved listing Supplier is unavailable');
      }
      return (await (_db.select(
        _db.supplierListings,
      )..where((table) => table.id.equals(result['id']!))).getSingle());
    }

    final listing = await validate();
    return SupplierListingSaved._(
      listing: listing,
      acknowledge: () => _queue(() async {
        if (_closed || _quiescing) {
          throw StateError('Catalog storage is changing');
        }
        await _db.transaction(() async {
          final key = '$editDraftPrefix${result['slot']}/control';
          final current = await _read(key);
          if (current == null) return;
          if (current != raw ||
              await _read('$editDraftPrefix${result['slot']}/input') != null) {
            throw StateError(
              'A newer supplier listing edit replaced this receipt',
            );
          }
          await validate();
          await _delete(key);
        });
      }),
    );
  }

  Future<Map<String, Map<String, Object?>>> _catalogNameAncestors(
    CatalogNameKind kind,
    String? parentId,
  ) async {
    if (kind._parentColumn == null) return {};
    if (parentId == null) throw StateError('Catalog parent is unavailable');
    final parent = await _catalogNameRow(
      kind == CatalogNameKind.type
          ? CatalogNameKind.category
          : CatalogNameKind.type,
      parentId,
    );
    return {
      'parent': parent,
      if (kind == CatalogNameKind.variant)
        'category': await _catalogNameRow(
          CatalogNameKind.category,
          _text(parent['category_id']),
        ),
    };
  }

  Future<EditOpening<CatalogNameEditSession>> openCatalogName(
    CatalogNameTarget target,
  ) {
    final recordTarget = {
      'kind': target.isRename ? 'catalog-name-rename' : 'catalog-name-new',
      'entity': target.kind.name,
      if (target.isRename) 'id': target.id! else 'reserved': newId(),
      if (target.parentId != null) 'parent': target.parentId!,
      if (target.listingVersionId != null) ...{
        'listingVersion': target.listingVersionId!,
        'listingReserved': newId(),
      },
    };
    return _open<CatalogNameEditSession>(
      recordTarget,
      () async => CatalogNameInput(
        nameText: target.isRename
            ? _text((await _catalogNameRow(target.kind, target.id!))['name'])
            : '',
      ),
      (record) => CatalogNameEditSession._(this, record),
      onCommitted: (raw) => _savedCatalogName(raw, recordTarget),
    );
  }

  Future<CatalogNameSaved> _savedCatalogName(
    String raw,
    Map<String, String> wanted,
  ) async {
    if (_closed || _quiescing) {
      throw StateError('Catalog storage is changing');
    }
    final control = _control(raw);
    if (control['phase'] != 'committed' ||
        !{
          'catalog-name-create',
          'catalog-name-rename',
        }.contains(control['command'])) {
      throw const FormatException('Unsupported saved catalog name receipt');
    }
    final result = _strings(control['result']);
    final target = _strings(jsonDecode(result['target']!));
    _catalogNameTarget(target);
    final kind = _catalogNameKind(target['entity']);
    final rename = target['kind'] == 'catalog-name-rename';
    final command = rename ? 'catalog-name-rename' : 'catalog-name-create';
    if (control['phase'] != 'committed' ||
        control['command'] != command ||
        result['entity'] != target['entity'] ||
        result['id'] != target[rename ? 'id' : 'reserved'] ||
        result['slot'] != _slot(target) ||
        result['slot'] != _slot(wanted) ||
        ![
          'kind',
          'entity',
          'id',
          'parent',
          'listingVersion',
        ].every((key) => target[key] == wanted[key]) ||
        (!rename &&
            kind._parentColumn != null &&
            result['parent'] != target['parent']) ||
        result['name']!.trim().isEmpty ||
        result['name'] != result['name']!.trim()) {
      throw const FormatException('Saved catalog name target mismatch');
    }

    Future<void> validate() async {
      if (_digest(_origin()) != _digest(control['origin'])) {
        throw StateError('Saved catalog name belongs to another installation');
      }
      final row = await _catalogNameRow(kind, result['id']!);
      if ((!rename && row['origin_device_id'] != _deviceId) ||
          row['name'] != result['name'] ||
          _digest(row) != result['row']) {
        throw StateError('The saved catalog name changed or is unavailable');
      }
      final ancestors = await _catalogNameAncestors(
        kind,
        _catalogNameParent(kind, row),
      );
      for (final entry in ancestors.entries) {
        if (entry.value['id'] != result[entry.key]) {
          throw StateError('The saved catalog name hierarchy changed');
        }
      }
      if (target.containsKey('listingVersion')) {
        final context = await _supplierListingContext(target);
        final listing = await _row('supplier_listings', result['listing']!);
        if (result['listing'] != target['listingReserved'] ||
            result['listingPart'] != context['Part']!['id'] ||
            listing == null ||
            listing['deleted_at'] != null ||
            listing['origin_device_id'] != _deviceId ||
            listing['supplier_id'] != result['id'] ||
            listing['brand_version_id'] != target['listingVersion'] ||
            listing['sku'] != '' ||
            _digest(listing) != result['listingRow']) {
          throw StateError(
            'The saved supplier listing changed or is unavailable',
          );
        }
      }
    }

    await validate();
    return CatalogNameSaved._(
      kind: kind,
      id: result['id']!,
      name: result['name']!,
      acknowledge: () => _queue(() async {
        if (_closed || _quiescing) {
          throw StateError('Catalog storage is changing');
        }
        await _db.transaction(() async {
          final slot = result['slot']!;
          final key = '$editDraftPrefix$slot/control';
          final current = await _read(key);
          if (current == null) return;
          if (current != raw ||
              await _read('$editDraftPrefix$slot/input') != null) {
            throw StateError('A newer catalog edit replaced this receipt');
          }
          await validate();
          await _delete(key);
        });
      }),
    );
  }

  Future<EditOpening<WarehouseLocationEditSession>>
  openNewWarehouseLocation() => _open<WarehouseLocationEditSession>(
    {'kind': 'warehouse-location-new', 'reserved': newId()},
    () async => const WarehouseLocationNameInput(nameText: ''),
    (record) => WarehouseLocationEditSession._(this, record),
    onCommitted: (raw) => _savedWarehouseLocation(
      raw,
      command: 'warehouse-location-create',
      locationId: null,
    ),
  );

  Future<EditOpening<WarehouseLocationEditSession>>
  openWarehouseLocationRename({
    required String locationId,
    required int expectedRevision,
  }) => _open<WarehouseLocationEditSession>(
    {
      'kind': 'warehouse-location-rename',
      'id': locationId,
      'revision': expectedRevision.toString(),
    },
    () async {
      final location = await (_db.select(
        _db.warehouseLocations,
      )..where((t) => t.id.equals(locationId))).getSingleOrNull();
      if (location == null || location.deletedAt != null) {
        throw StateError('Warehouse location is unavailable');
      }
      return WarehouseLocationNameInput(nameText: location.name);
    },
    (record) => WarehouseLocationEditSession._(this, record),
    onCommitted: (raw) => _savedWarehouseLocation(
      raw,
      command: 'warehouse-location-rename',
      locationId: locationId,
    ),
  );

  Future<WarehouseLocationSaved> _savedWarehouseLocation(
    String raw, {
    required String command,
    required String? locationId,
  }) async {
    if (_closed || _quiescing) {
      throw StateError('Warehouse storage is changing');
    }
    final control = _control(raw);
    if (control['phase'] != 'committed' || control['command'] != command) {
      throw const FormatException('Unsupported saved warehouse receipt');
    }
    final result = _strings(control['result']);
    if (locationId != null && result['location'] != locationId) {
      throw const FormatException(
        'Saved warehouse belongs to another location',
      );
    }
    Future<WarehouseLocation> validate() async {
      if (_digest(_origin()) != _digest(control['origin'])) {
        throw StateError('Saved warehouse belongs to another installation');
      }
      final location = await (_db.select(
        _db.warehouseLocations,
      )..where((t) => t.id.equals(result['location']!))).getSingleOrNull();
      if (location == null ||
          location.deletedAt != null ||
          (command == 'warehouse-location-create' &&
              location.originDeviceId != _deviceId) ||
          _digest(location.toJson()) != result['row']) {
        throw StateError('The saved warehouse changed or is unavailable');
      }
      return location;
    }

    final location = await validate();
    final slot = _slot(
      command == 'warehouse-location-create'
          ? {'kind': 'warehouse-location-new'}
          : {'kind': 'warehouse-location-rename', 'id': location.id},
    );
    return WarehouseLocationSaved._(
      location: location,
      acknowledge: () => _queue(() async {
        if (_closed || _quiescing) {
          throw StateError('Warehouse storage is changing');
        }
        await _db.transaction(() async {
          final key = '$editDraftPrefix$slot/control';
          final current = await _read(key);
          if (current == null) return;
          if (current != raw ||
              await _read('$editDraftPrefix$slot/input') != null) {
            throw StateError('A newer warehouse edit replaced this receipt');
          }
          await validate();
          await _delete(key);
        });
      }),
    );
  }

  Future<EditOpening<WarehouseCountEditSession>> openWarehouseCount({
    required String locationId,
    required String partId,
    required String uom,
    required String? expectedPriorCountId,
  }) => _open<WarehouseCountEditSession>(
    {
      'kind': 'warehouse-count',
      'location': locationId,
      'part': partId,
      'reserved': newId(),
      'uom': uom.trim(),
      'prior': ?expectedPriorCountId,
    },
    () async => WarehouseCountInput(
      quantityText: '',
      noteText: '',
      observedAt: DateTime.now().toUtc(),
    ),
    (record) => WarehouseCountEditSession._(this, record),
    onCommitted: (raw) => _savedWarehouseCount(raw, locationId, partId),
  );

  Future<WarehouseCountSaved> _savedWarehouseCount(
    String raw,
    String locationId,
    String partId,
  ) async {
    if (_closed || _quiescing) throw StateError('Count storage is changing');
    final control = _control(raw);
    if (control['phase'] != 'committed' ||
        control['command'] != 'warehouse-count-save') {
      throw const FormatException('Unsupported saved count receipt');
    }
    final result = _strings(control['result']);
    if (result['location'] != locationId || result['part'] != partId) {
      throw const FormatException(
        'Saved count belongs to another location or Part',
      );
    }
    Future<WarehouseCount> validate() async {
      if (_digest(_origin()) != _digest(control['origin'])) {
        throw StateError('Saved count belongs to another installation');
      }
      final count = await (_db.select(
        _db.warehouseCounts,
      )..where((t) => t.id.equals(result['count']!))).getSingleOrNull();
      if (count == null ||
          count.locationId != locationId ||
          count.partId != partId ||
          count.originDeviceId != _deviceId ||
          _digest(count.toJson()) != result['row']) {
        throw StateError('The saved count changed or is unavailable');
      }
      return count;
    }

    final count = await validate();
    final slot = _slot({
      'kind': 'warehouse-count',
      'location': locationId,
      'part': partId,
    });
    return WarehouseCountSaved._(
      count: count,
      acknowledge: () => _queue(() async {
        if (_closed || _quiescing) {
          throw StateError('Count storage is changing');
        }
        await _db.transaction(() async {
          final key = '$editDraftPrefix$slot/control';
          final current = await _read(key);
          if (current == null) return;
          if (current != raw ||
              await _read('$editDraftPrefix$slot/input') != null) {
            throw StateError('A newer count edit replaced this receipt');
          }
          await validate();
          await _delete(key);
        });
      }),
    );
  }

  Future<EditOpening<NewJobEditSession>> openNewJob() =>
      _open<NewJobEditSession>(
        {'kind': 'job-new', 'reserved': newId()},
        () async => const NewJobInput(nameText: ''),
        (record) => NewJobEditSession._(this, record),
        onCommitted: _createdJob,
      );

  Future<NewJobCreated> _createdJob(String raw) async {
    if (_closed || _quiescing) throw StateError('Job storage is changing');
    final control = _control(raw);
    if (control['phase'] != 'committed' || control['command'] != 'job-create') {
      throw const FormatException('Unsupported created Job receipt');
    }
    final result = _strings(control['result']);
    final id = result['job']!;
    final name = result['name']!;
    Future<void> validate() async {
      if (_digest(_origin()) != _digest(control['origin'])) {
        throw StateError('Created Job belongs to another installation');
      }
      final job = await _row('jobs', id);
      if (job == null || job['deleted_at'] != null || job['name'] != name) {
        throw StateError('The created Job changed or is no longer available');
      }
    }

    await validate();
    return NewJobCreated._(
      id: id,
      name: name,
      acknowledge: () => _queue(() async {
        if (_closed || _quiescing) throw StateError('Job storage is changing');
        await _db.transaction(() async {
          const key = '${editDraftPrefix}job-new/control';
          final current = await _read(key);
          if (current == null) return;
          if (current != raw ||
              await _read('${editDraftPrefix}job-new/input') != null) {
            throw StateError('A newer Job edit replaced this receipt');
          }
          await validate();
          await _delete(key);
        });
      }),
    );
  }

  Future<EditOpening<NewPartEditSession>> openNewPart({
    String? initialCategoryId,
    String? initialStyleId,
    String? initialTypeId,
  }) => _open<NewPartEditSession>(
    {'kind': 'part-new', 'reserved': newId()},
    () async => NewPartInput(
      nameText: '',
      categoryId: initialCategoryId,
      styleId: initialStyleId,
      typeId: initialTypeId,
    ),
    (record) => NewPartEditSession._(this, record),
    onCommitted: _createdPart,
  );

  Future<NewPartCreated> _createdPart(String raw) async {
    if (_closed || _quiescing) throw StateError('Part storage is changing');
    final control = _control(raw);
    if (control['phase'] != 'committed' ||
        control['command'] != 'part-create') {
      throw const FormatException('Unsupported created Part receipt');
    }
    final result = _strings(control['result']);
    final target = _strings(jsonDecode(result['target']!));
    _newPartTarget(target);
    if (result['slot'] != 'part-new' || target['reserved'] != result['id']) {
      throw const FormatException('Created Part target mismatch');
    }
    final createdAt = DateTime.tryParse(result['createdAt']!);
    if (createdAt == null ||
        createdAt.toUtc().toIso8601String() != result['createdAt']) {
      throw const FormatException('Invalid Part creation time');
    }
    final origin = _parseOrigin(control['origin']);
    if (result['device'] != origin['device']) {
      throw const FormatException('Created Part origin mismatch');
    }
    Future<void> validate() async {
      if (await _read('${editDraftPrefix}part-new/control') != raw ||
          await _read('${editDraftPrefix}part-new/input') != null) {
        throw StateError('A newer Part edit replaced this receipt');
      }
      if (_digest(_origin()) != _digest(origin)) {
        throw StateError('Created Part belongs to another installation');
      }
      final part = await _db.partsDao.getPart(result['id']!);
      if (part == null ||
          part.originDeviceId != result['device'] ||
          part.createdAt.toUtc() != createdAt) {
        throw StateError('The created Part identity is no longer available');
      }
    }

    await validate();
    final saved = NewPartCreated._(
      id: result['id']!,
      name: result['name']!,
      categoryId: result['category']!,
      styleId: result['style']!,
      typeId: result['type']!,
      originDeviceId: result['device']!,
      createdAt: createdAt,
      acknowledge: () => _queue(() async {
        if (_closed || _quiescing) throw StateError('Part storage is changing');
        await _db.transaction(() async {
          const key = '${editDraftPrefix}part-new/control';
          final current = await _read(key);
          if (current == null) return;
          await validate();
          await _delete(key);
        });
      }),
    );
    return saved;
  }

  Future<EditOpening<PartEditSession>> openPart(String partId) =>
      _open<PartEditSession>({'kind': 'part', 'id': partId}, () async {
        final p = await _db.partsDao.getPart(partId);
        if (p == null) throw StateError('Part no longer exists');
        return PartInput(
          nameText: p.name,
          descriptionText: p.description,
          specsText: p.specs,
          uomText: p.uom,
          categoryId: p.categoryId,
          styleId: p.styleId,
          typeId: p.typeId,
          defaultSupplierId: p.defaultSupplierId,
          active: p.active,
        );
      }, (r) => PartEditSession._(this, r));
  Future<EditOpening<JobLineEditSession>> openJobLine(
    String jobId, {
    String? lineId,
  }) => _open<JobLineEditSession>(
    {
      'kind': 'line',
      'job': jobId,
      'line': ?lineId,
      'reserved': lineId ?? newId(),
    },
    () async {
      final line = lineId == null ? null : await _db.jobsDao.getJobLine(lineId);
      if (lineId != null && line == null) {
        throw StateError('Job line no longer exists');
      }
      final splits = line == null
          ? <OrderSplit>[]
          : await _db.jobsDao.orderSplitsForLine(line.id);
      String qty(double n) =>
          n == n.roundToDouble() ? n.toInt().toString() : n.toString();
      return JobLineInput(
        useCustom: line != null && line.partId == null,
        partId: line?.partId,
        brandVersionId: line?.brandVersionId,
        customNameText: line?.customName ?? '',
        neededText: line == null ? '1' : qty(line.neededQty),
        pullText: line == null ? '0' : qty(line.shopPullQty),
        customNotes: line?.customNotes,
        uom: line?.uom,
        notes: line?.notes,
        splits: splits.isEmpty
            ? const [SplitInput(supplierId: null, quantityText: '')]
            : [
                for (final s in splits)
                  SplitInput(
                    supplierId: s.supplierId,
                    quantityText: qty(s.quantity),
                  ),
              ],
      );
    },
    (r) => JobLineEditSession._(this, r),
  );

  Future<EditOpening<S>> _open<S extends _EditSession>(
    Map<String, String> target,
    Future<Object> Function() initial,
    S Function(_DraftRecord) create, {
    Future<EditOpening<S>> Function(String raw)? onCommitted,
  }) => _queue(() async {
    final slot = _slot(target);
    final inputKey = '$editDraftPrefix$slot/input';
    final controlKey = '$editDraftPrefix$slot/control';
    if (_closed || _quiescing || _active.containsKey(slot)) {
      return BlockedEdit<S>(
        reason: 'This editor is already open or storage is changing',
        preservedInput: null,
        discard: () async => throw StateError('Close the other editor first'),
      );
    }
    final raw = await _read(inputKey);
    final rawControl = await _read(controlKey);
    Future<void> discard() => _queue(() async {
      if (_closed || _active.containsKey(slot)) {
        throw StateError('This editor is unavailable');
      }
      await _db.transaction(() async {
        if (await _read(inputKey) != raw ||
            await _read(controlKey) != rawControl) {
          throw StateError('Unfinished edits changed');
        }
        await _delete(inputKey);
        await _delete(controlKey);
      });
    });
    if (raw != null) {
      try {
        final record = _DraftRecord.parse(raw);
        if (record.slot != slot ||
            ![
              'kind',
              'id',
              'job',
              'line',
              'location',
              'part',
              'entity',
              'parent',
              'listingVersion',
            ].every((key) => record.target[key] == target[key])) {
          throw const FormatException('Unfinished edits target mismatch');
        }
        final control = _control(rawControl ?? 'null');
        if (control['phase'] != 'editing' || control['token'] != record.token) {
          throw const FormatException('Unfinished edits session mismatch');
        }
        await _check(record);
        await _requireReferences(record);
        return RecoverableEdit<S>(
          resume: () => _queue(() async {
            if (_closed ||
                _quiescing ||
                _active.containsKey(slot) ||
                await _read(inputKey) != raw ||
                await _read(controlKey) != rawControl) {
              throw StateError('Unfinished edits changed before Resume');
            }
            await _check(record);
            await _requireReferences(record);
            final session = create(record)
              .._admitted = true
              .._persistedInput = raw;
            _active[slot] = session;
            return session;
          }),
          discard: discard,
        );
      } catch (e) {
        return BlockedEdit<S>(
          reason: e.toString(),
          preservedInput: raw,
          discard: discard,
        );
      }
    }
    if (rawControl != null) {
      try {
        final control = _control(rawControl);
        if (control['phase'] != 'committed') {
          throw const FormatException('Unfinished edit input is missing');
        }
        if (onCommitted != null) return await onCommitted(rawControl);
      } catch (e) {
        return BlockedEdit<S>(
          reason: e.toString(),
          preservedInput: rawControl,
          discard: discard,
        );
      }
    }
    try {
      Object? originError;
      final record = await _db.transaction(() async {
        final input = await initial();
        Map<String, String> origin;
        try {
          origin = _origin();
        } catch (e) {
          originError = e;
          origin = {'mode': 'unavailable', 'device': _deviceId};
        }
        final record = _DraftRecord(
          target: target,
          origin: origin,
          base: await _base(target),
          references: await _references(input),
          token: newId(),
          input: input,
        );
        if (input is NewPartInput) await _requireReferences(record);
        return record;
      });
      final session = create(record);
      if (originError != null) {
        session._status(EditPhase.recoveryBlocked, error: originError);
      }
      _active[slot] = session;
      return FreshEdit<S>(session);
    } catch (e) {
      return BlockedEdit<S>(
        reason: e.toString(),
        preservedInput: null,
        discard: () async {},
      );
    }
  });

  Future<void> quiesce(StorageChange reason) async {
    if (_closed) return;
    if (_quiescing) throw StateError('Storage is already changing');
    _quiescing = true;
    try {
      for (final session in List<_EditSession>.of(_active.values)) {
        await session.flush();
      }
      final pending = _tail;
      if (pending != null) await pending;
      _closed = true;
      for (final session in _active.values) {
        session._close();
      }
      _active.clear();
    } catch (_) {
      _quiescing = false;
      rethrow;
    }
  }
}
