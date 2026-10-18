import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_commands.dart';
import 'native_nearby_test_commands_test.dart' show Fixture, change;

String nameStep(Fixture f, int sequence, Object? step) =>
    change(f.request(sequence), (value) {
      value['action'] = 'jobNameUi';
      value['arguments'] = {'step': step};
    });

void main() {
  test('bounded Job-name UI steps can be admitted and executed once', () {
    for (final step in [
      'inspect',
      'renameSequential',
      'renameConcurrent',
      'inspectConflict',
      'checkpointConflict',
      'resolveFirst',
      'inspectResolved',
    ]) {
      final f = Fixture();
      final wire = nameStep(f, 1, step);
      expect(f.cache.submitJson(wire).state, NativeTestCommandState.accepted);
      final admitted = f.cache.takeNext()!;
      expect(admitted.action.name, 'jobNameUi');
      expect(admitted.jobNameStep!.name, step);
      final completed = f.cache.complete(
        admitted,
        const NativeTestCommandResult.effect(),
      );
      expect(f.cache.submitJson(wire).toJson(), completed.toJson());
      expect(f.cache.takeNext(), isNull);
    }
  });

  test('Job-name UI step changes cannot reuse an admitted identity', () {
    final f = Fixture();
    final first = nameStep(f, 1, 'renameSequential');
    expect(f.cache.submitJson(first).state, NativeTestCommandState.accepted);
    expect(
      f.cache.submitJson(nameStep(f, 1, 'resolveFirst')).error,
      NativeTestCommandError.identityConflict,
    );
  });

  test('arbitrary or extra Job-name UI input is refused without execution', () {
    for (final invalid in [null, '', 'rename', 'runShell', 1, {}, []]) {
      final f = Fixture();
      expect(
        f.cache.submitJson(nameStep(f, 1, invalid)).error,
        NativeTestCommandError.invalidRequest,
      );
      expect(f.cache.takeNext(), isNull);
    }
    final f = Fixture();
    final extra = change(nameStep(f, 1, 'inspect'), (value) {
      (value['arguments'] as Map)['name'] = 'arbitrary';
    });
    expect(
      f.cache.submitJson(extra).error,
      NativeTestCommandError.invalidRequest,
    );
    expect(f.cache.takeNext(), isNull);
  });

  test('a resident without Job-name opt-in refuses the UI action', () {
    final f = Fixture();
    expect(
      f.cache
          .submitJson(
            nameStep(f, 1, 'inspect'),
            allowedActions: {NativeTestAction.observe},
          )
          .error,
      NativeTestCommandError.wrongPhase,
    );
    expect(f.cache.takeNext(), isNull);
  });
}
