part of 'job_line_commands.dart';

class _Conflict {
  _Conflict(this.unit, this.candidates, this.frontier);
  final String unit;
  final List<String> candidates;
  final List<String> frontier;
}

class _Reduction {
  _Reduction(this.state, this.conflicts);
  final _LineState state;
  final List<_Conflict> conflicts;
}

_Reduction _reduce(_LineState baseline, List<_Operation> operations) {
  if (operations.length > _maximumOperations) {
    throw const JobLineRefusal('causal history capacity reached');
  }
  final graph = {for (final operation in operations) operation.key: operation};
  final ancestors = <String, Set<String>>{};
  Set<String> ancestry(String key, Set<String> path) {
    if (ancestors[key] case final cached?) return cached;
    if (path.contains(key)) throw const JobLineRefusal('causal cycle');
    final operation = graph[key];
    if (operation == null) throw const JobLineRefusal('missing causal parent');
    final result = <String>{};
    for (final parent in operation.parents) {
      result.add(parent);
      result.addAll(ancestry(parent, {...path, key}));
    }
    ancestors[key] = result;
    return result;
  }

  for (final operation in operations) {
    ancestry(operation.key, {});
  }
  List<_Operation> maximal(Iterable<_Operation> input) {
    final candidates = input.toList();
    return candidates
        .where(
          (a) => !candidates.any(
            (b) => b.key != a.key && ancestors[b.key]!.contains(a.key),
          ),
        )
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
  }

  Set<String> commonAncestors(List<_Operation> candidates) {
    var common = {...ancestors[candidates.first.key]!};
    for (final candidate in candidates.skip(1)) {
      common = common.intersection(ancestors[candidate.key]!);
    }
    return common;
  }

  List<String> frontier(Set<String> common) =>
      common
          .where((a) => !common.any((b) => b != a && ancestors[b]!.contains(a)))
          .toList()
        ..sort();

  final units = Map<String, Object?>.from(baseline.units);
  final conflicts = <_Conflict>[];
  for (final unit in ['identity', 'quantities', 'notes', 'customNotes']) {
    final candidates = maximal(
      operations.where((o) => o.units.containsKey(unit)),
    );
    if (candidates.isEmpty) continue;
    final values = candidates.map((o) => _canonical(o.units[unit])).toSet();
    if (values.length == 1) {
      units[unit] = candidates.first.units[unit];
    } else {
      final common = commonAncestors(candidates);
      final previous = maximal(
        operations.where(
          (o) => common.contains(o.key) && o.units.containsKey(unit),
        ),
      );
      if (previous.isNotEmpty &&
          previous.map((o) => _canonical(o.units[unit])).toSet().length == 1) {
        units[unit] = previous.first.units[unit];
      }
      conflicts.add(
        _Conflict(
          unit,
          candidates.map((o) => o.key).toList(),
          frontier(common),
        ),
      );
    }
  }
  final deletes = maximal(
    operations.where((o) => o.units.containsKey('lifecycle')),
  );
  if (deletes.isNotEmpty) {
    units['lifecycle'] = 'deleted';
    final edits = operations.where(
      (o) =>
          !o.units.containsKey('lifecycle') &&
          deletes.any(
            (deletion) =>
                !ancestors[deletion.key]!.contains(o.key) &&
                !ancestors[o.key]!.contains(deletion.key),
          ),
    );
    final candidates = maximal([...deletes, ...edits]);
    if (candidates.any((o) => !o.units.containsKey('lifecycle'))) {
      conflicts.add(
        _Conflict(
          'lifecycle',
          candidates.map((o) => o.key).toList(),
          frontier(commonAncestors(candidates)),
        ),
      );
    }
  }
  return _Reduction(_LineState(units), conflicts);
}
