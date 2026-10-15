part of 'job_line_commands.dart';

const _maximumBytes = 65536;
const _maximumOperations = 256;
const _maximumParents = 32;
const kJobLineReceiptMaximumBytes = 131072;

Map<String, Object?> decodeJobLineReceipt(
  String bytes, {
  bool requireSeal = true,
}) {
  if (utf8.encode(bytes).length > kJobLineReceiptMaximumBytes) {
    throw const JobLineRefusal('receipt exceeds byte limit');
  }
  final value = _object(jsonDecode(bytes));
  if (value['v'] != 2) {
    throw const JobLineRefusal(
      'unsealed receipt history requires a compatible recovery app',
    );
  }
  _keys(value, {
    'v',
    'key',
    'parent',
    'operation',
    'command',
    'status',
    'bytes',
    'receiver',
    'store',
    if (requireSeal || value.containsKey('seal')) 'seal',
  });
  if (_canonicalReceipt(value) != bytes) {
    throw const JobLineRefusal('unsupported or noncanonical sealed receipt');
  }
  return value;
}

String _canonicalReceipt(Object? value) =>
    _canonical(value, maximumBytes: kJobLineReceiptMaximumBytes);

class JobLineRefusal implements Exception {
  const JobLineRefusal(this.reason);
  final String reason;
  @override
  String toString() => 'Job-line command refused: $reason';
}

sealed class FieldPatch<T> {
  const FieldPatch();
}

final class Omitted<T> extends FieldPatch<T> {
  const Omitted();
}

final class SetField<T> extends FieldPatch<T> {
  const SetField(this.value);
  final T value;
}

sealed class JobLineIdentity {
  const JobLineIdentity();
  Map<String, Object?> _json();
}

final class CatalogJobLine extends JobLineIdentity {
  const CatalogJobLine(this.partId, {this.brandVersionId});
  final String partId;
  final String? brandVersionId;
  @override
  Map<String, Object?> _json() => {
    'part': partId,
    'version': brandVersionId,
    'custom': null,
  };
}

final class CustomJobLine extends JobLineIdentity {
  const CustomJobLine(this.name);
  final String name;
  @override
  Map<String, Object?> _json() => {
    'part': null,
    'version': null,
    'custom': name,
  };
}

final class JobLineQuantities {
  const JobLineQuantities({
    required this.needed,
    required this.shopPull,
    required this.unit,
  });
  final double needed;
  final double shopPull;
  final String? unit;
  Map<String, Object?> _json() => {
    'needed': needed,
    'pull': shopPull,
    'unit': unit,
  };
}

sealed class JobLineMutation {
  const JobLineMutation();
  Map<String, Object?> _units();
}

final class JobLinePatch extends JobLineMutation {
  const JobLinePatch({
    this.identity,
    this.quantities,
    this.notes = const Omitted(),
    this.customNotes = const Omitted(),
  });
  final JobLineIdentity? identity;
  final JobLineQuantities? quantities;
  final FieldPatch<String?> notes;
  final FieldPatch<String?> customNotes;
  @override
  Map<String, Object?> _units() => {
    if (identity != null) 'identity': identity!._json(),
    if (quantities != null) 'quantities': quantities!._json(),
    if (notes case SetField(value: final value)) 'notes': value,
    if (customNotes case SetField(value: final value)) 'customNotes': value,
  };
}

final class DeleteJobLine extends JobLineMutation {
  const DeleteJobLine();
  @override
  Map<String, Object?> _units() => {'lifecycle': 'deleted'};
}

final class JobLineCommand {
  JobLineCommand({
    required this.companyId,
    required this.shopId,
    required this.lineId,
    required this.requestId,
    required Iterable<String> observedHeads,
    required this.mutation,
  }) : observedHeads = List.unmodifiable(_ids(observedHeads, _maximumParents)) {
    for (final id in [companyId, shopId, lineId, requestId]) {
      _id(id);
    }
    _validateUnits(mutation._units());
  }
  final String companyId;
  final String shopId;
  final String lineId;
  final String requestId;
  final List<String> observedHeads;
  final JobLineMutation mutation;
  Map<String, Object?> _json() => {
    'v': 1,
    'contract': 'job.line.patch@1',
    'company': companyId,
    'shop': shopId,
    'line': lineId,
    'request': requestId,
    'parents': observedHeads,
    'units': mutation._units(),
  };
  String get commitment => _digest(_json());
}

final class JobLineCommandReceipt {
  JobLineCommandReceipt._(
    this.key,
    this.operationCommitment,
    this.status,
    Uint8List operationBytes,
    this.bytes,
  ) : _operationBytes = Uint8List.fromList(operationBytes);
  final String key;
  final String operationCommitment;
  final String status;
  final Uint8List _operationBytes;
  Uint8List get operationBytes => Uint8List.fromList(_operationBytes);
  final String bytes;
  static Future<void> verifyAdmissionSeal(
    String bytes,
    InstallationIdentity identity,
    String storeGeneration,
  ) async {
    final value = decodeJobLineReceipt(bytes);
    if (value['receiver'] != identity.id.value ||
        value['store'] != storeGeneration) {
      throw const JobLineRefusal('unsupported or mismatched sealed receipt');
    }
    final encodedSeal = _string(value, 'seal');
    if (base64Encode(base64Decode(encodedSeal)) != encodedSeal) {
      throw const JobLineRefusal('noncanonical receipt seal');
    }
    final payload = {...value}..remove('seal');
    await _verifySignature(
      payload,
      encodedSeal,
      SimplePublicKey(identity.publicKey, type: KeyPairType.ed25519),
      domain: 'wiredpart.job.line.receipt@2:',
      maximumBytes: kJobLineReceiptMaximumBytes,
    );
  }

  factory JobLineCommandReceipt._decode(String bytes) {
    final value = decodeJobLineReceipt(bytes);
    return JobLineCommandReceipt._(
      _string(value, 'key'),
      _string(value, 'operation'),
      _string(value, 'status'),
      base64Decode(_string(value, 'bytes')),
      bytes,
    );
  }
}

class _LineState {
  _LineState(Map<String, Object?> units) : units = Map.unmodifiable(units);
  final Map<String, Object?> units;
  static _LineState fromRow(JobLine row) => _LineState({
    'identity': {
      'part': row.partId,
      'version': row.brandVersionId,
      'custom': row.customName,
    },
    'quantities': {
      'needed': row.neededQty,
      'pull': row.shopPullQty,
      'unit': row.uom,
    },
    'notes': row.notes,
    'customNotes': row.customNotes,
    'lifecycle': row.deletedAt == null ? 'active' : 'deleted',
  });
  String get bytes => _canonical(units);
  bool get deleted => units['lifecycle'] == 'deleted';
}

class _Operation {
  _Operation(this.body, this.authorization, this.signature, this.bytes);
  final Map<String, Object?> body;
  final Map<String, Object?> authorization;
  final String signature;
  final String bytes;
  String get commitment => _digest(body);
  String get id => _string(body, 'request');
  String get generation => _string(body, 'generation');
  String get key => '$generation/$id';
  String get company => _string(body, 'company');
  String get shop => _string(body, 'shop');
  String get line => _string(body, 'line');
  String get baseline => _string(body, 'baseline');
  String get commandCommitment => _string(body, 'command');
  List<String> get parents => _stringList(body['parents'], _maximumParents);
  Map<String, Object?> get units => _object(body['units']);

  static _Operation parse(Uint8List bytes) {
    if (bytes.length > _maximumBytes) {
      throw const JobLineRefusal('operation exceeds byte limit');
    }
    final text = utf8.decode(bytes);
    final value = _object(jsonDecode(text));
    _keys(value, {'body', 'authorization', 'signature'});
    if (_canonical(value) != text) {
      throw const JobLineRefusal('noncanonical operation');
    }
    final body = _object(value['body']);
    _keys(body, {
      'v',
      'contract',
      'company',
      'shop',
      'line',
      'request',
      'generation',
      'installation',
      'device',
      'user',
      'parents',
      'baseline',
      'units',
      'command',
      'facts',
    });
    if (body['v'] != 1 || body['contract'] != 'job.line.patch@1') {
      throw const JobLineRefusal('unsupported operation version');
    }
    for (final key in [
      'company',
      'shop',
      'line',
      'request',
      'generation',
      'installation',
      'device',
      'user',
    ]) {
      _id(_string(body, key));
    }
    _stringList(body['parents'], _maximumParents);
    _validateUnits(_object(body['units']));
    return _Operation(
      body,
      _object(value['authorization']),
      _string(value, 'signature'),
      text,
    );
  }
}

String _canonical(Object? value, {int maximumBytes = _maximumBytes}) {
  Object? sorted(Object? item, int depth) {
    if (depth > 12) throw const JobLineRefusal('encoding nesting limit');
    if (item is Map<String, Object?>) {
      final keys = item.keys.toList()..sort();
      return {for (final key in keys) key: sorted(item[key], depth + 1)};
    }
    if (item is List) {
      if (item.length > 1024) throw const JobLineRefusal('encoding item limit');
      return item.map((v) => sorted(v, depth + 1)).toList();
    }
    if (item is double && !item.isFinite) {
      throw const JobLineRefusal('nonfinite value');
    }
    return item;
  }

  final text = jsonEncode(sorted(value, 0));
  if (utf8.encode(text).length > maximumBytes) {
    throw const JobLineRefusal('encoding exceeds byte limit');
  }
  return text;
}

String _digest(Object? value) =>
    hashes.sha256.convert(utf8.encode(_canonical(value))).toString();

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const JobLineRefusal('invalid object');
  }
  return Map<String, Object?>.from(value);
}

String _string(Map<String, Object?> value, String key) {
  final item = value[key];
  if (item is! String || item.isEmpty || item.length > 4096) {
    throw JobLineRefusal('invalid $key');
  }
  return item;
}

void _keys(Map<String, Object?> value, Set<String> expected) {
  if (value.length != expected.length || !expected.every(value.containsKey)) {
    throw const JobLineRefusal('unsupported or incomplete fields');
  }
}

void _id(String value) {
  if (!Uuid.isValidUUID(fromString: value)) {
    throw const JobLineRefusal('invalid permanent ID');
  }
}

List<String> _ids(Iterable<String> input, int maximum) {
  final values = input.toList();
  if (values.length > maximum ||
      values.toSet().length != values.length ||
      values.any(
        (v) =>
            v.length > 128 ||
            v.split('/').length != 2 ||
            !v.split('/').every((id) => Uuid.isValidUUID(fromString: id)),
      )) {
    throw const JobLineRefusal('invalid causal IDs');
  }
  values.sort();
  return values;
}

List<String> _stringList(Object? input, int maximum) {
  if (input is! List || input.any((v) => v is! String)) {
    throw const JobLineRefusal('invalid ID list');
  }
  final sorted = _ids(input.cast<String>(), maximum);
  if (_canonical(input) != _canonical(sorted)) {
    throw const JobLineRefusal('causal IDs must use canonical ordering');
  }
  return sorted;
}

void _validateUnits(Map<String, Object?> units) {
  const allowed = {
    'identity',
    'quantities',
    'notes',
    'customNotes',
    'lifecycle',
  };
  if (units.isEmpty || units.keys.any((key) => !allowed.contains(key))) {
    throw const JobLineRefusal('empty or unsupported editing unit');
  }
  if (units.containsKey('lifecycle')) {
    if (units.length != 1 || units['lifecycle'] != 'deleted') {
      throw const JobLineRefusal('invalid lifecycle mutation');
    }
  }
  if (units['identity'] case final Object identity) {
    final value = _object(identity);
    _keys(value, {'part', 'version', 'custom'});
    if (value['part'] != null) {
      _id(_string(value, 'part'));
      if (value['version'] != null) _id(_string(value, 'version'));
      if (value['custom'] != null) {
        throw const JobLineRefusal('catalog/custom identity contradiction');
      }
    } else {
      if (value['version'] != null || _string(value, 'custom').trim().isEmpty) {
        throw const JobLineRefusal('invalid custom identity');
      }
    }
  }
  if (units['quantities'] case final Object quantities) {
    final value = _object(quantities);
    _keys(value, {'needed', 'pull', 'unit'});
    for (final key in ['needed', 'pull']) {
      final number = value[key];
      if (number is! num || !number.isFinite || number < 0) {
        throw const JobLineRefusal('quantity must be finite and nonnegative');
      }
    }
    final unit = value['unit'];
    // Existing catalog units are user-defined text; v1 permits finite
    // fractional quantities and a nonblank bounded label, or legacy null.
    if (unit != null &&
        (unit is! String || unit.trim().isEmpty || unit.length > 64)) {
      throw const JobLineRefusal('invalid quantity unit');
    }
  }
  for (final key in ['notes', 'customNotes']) {
    final value = units[key];
    if (value != null && (value is! String || value.length > 4096)) {
      throw const JobLineRefusal('invalid notes');
    }
  }
}
