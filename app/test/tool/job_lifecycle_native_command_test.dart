import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_nearby_test_commands.dart';
import 'native_nearby_test_commands_test.dart' show Fixture, change;

String lifecycleStep(Fixture f, Object? step) => change(f.request(1), (value) {
  value['action'] = 'jobLifecycleUi';
  value['arguments'] = {'step': step};
});

void main() {
  test('every lifecycle step round trips with its exact family', () {
    for (final step in NativeJobLifecycleUiStep.values) {
      final f = Fixture();
      final wire = NativeTestCommand.encodeRequest(
        session: f.localSession,
        sequence: 1,
        action: NativeTestAction.jobLifecycleUi,
        deadlineMillis: 1000,
        jobLifecycleStep: step,
      );
      expect(f.cache.submitJson(wire).state, NativeTestCommandState.accepted);
      final command = f.cache.takeNext()!;
      expect(command.jobLifecycleStep, step);
      expect(command.jobNameStep, isNull);
      expect(command.jobDetailsStep, isNull);
    }
    final f = Fixture();
    expect(
      () => NativeTestCommand.encodeRequest(
        session: f.localSession,
        sequence: 1,
        action: NativeTestAction.jobNameUi,
        deadlineMillis: 1000,
        jobLifecycleStep: NativeJobLifecycleUiStep.deleteOffline,
      ),
      throwsA(anything),
    );
  });

  test('identity collisions, expired work and a legacy allowlist refuse', () {
    final f = Fixture();
    f.cache.submitJson(lifecycleStep(f, 'inspect'));
    expect(
      f.cache.submitJson(lifecycleStep(f, 'keepEdited')).error,
      NativeTestCommandError.identityConflict,
    );
    final expired = Fixture()..now = 1000;
    expect(
      expired.cache.submitJson(lifecycleStep(expired, 'deleteOffline')).error,
      NativeTestCommandError.deadlineExpired,
    );
    final old = Fixture();
    expect(
      old.cache
          .submitJson(
            lifecycleStep(old, 'inspect'),
            allowedActions: {
              NativeTestAction.observe,
              NativeTestAction.jobDetailsUi,
            },
          )
          .error,
      NativeTestCommandError.wrongPhase,
    );
    expect(old.cache.takeNext(), isNull);
  });

  test('arbitrary lifecycle actions, values and extra fields refuse', () {
    for (final invalid in [null, '', 'resolveNotes', 'runShell', 1, {}, []]) {
      final f = Fixture();
      expect(
        f.cache.submitJson(lifecycleStep(f, invalid)).error,
        NativeTestCommandError.invalidRequest,
      );
      expect(f.cache.takeNext(), isNull);
    }
    final f = Fixture();
    expect(
      f.cache
          .submitJson(
            change(lifecycleStep(f, 'inspect'), (value) {
              (value['arguments'] as Map)['job'] = 'untrusted-job';
            }),
          )
          .error,
      NativeTestCommandError.invalidRequest,
    );
  });
  test(
    'lifecycle inspect is admitted with an exact single-execution identity',
    () {
      final f = Fixture();
      final wire = lifecycleStep(f, 'inspect');
      expect(f.cache.submitJson(wire).state, NativeTestCommandState.accepted);
      final command = f.cache.takeNext()!;
      final completed = f.cache.complete(
        command,
        const NativeTestCommandResult.effect(),
      );
      expect(f.cache.submitJson(wire).toJson(), completed.toJson());
      expect(f.cache.takeNext(), isNull);
    },
  );
}
