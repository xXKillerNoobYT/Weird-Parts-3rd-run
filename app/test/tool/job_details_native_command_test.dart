import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/company_join_native_test.dart' as adapter;
import '../../tool/native_nearby_test_commands.dart';
import '../../tool/native_nearby_test_crypto.dart';
import 'native_nearby_test_commands_test.dart' show Fixture, change;

String detailsStep(Fixture f, Object? step) => change(f.request(1), (value) {
  value['action'] = 'jobDetailsUi';
  value['arguments'] = {'step': step};
});

void main() {
  test('finite details commands retain typed single-execution identity', () {
    for (final step in NativeJobDetailsUiStep.values) {
      final f = Fixture();
      final source = NativeTestCommand.encodeRequest(
        session: f.localSession,
        sequence: 1,
        action: NativeTestAction.jobDetailsUi,
        deadlineMillis: 1000,
        jobDetailsStep: step,
      );
      expect(f.cache.submitJson(source).state, NativeTestCommandState.accepted);
      final command = f.cache.takeNext()!;
      expect(command.jobDetailsStep, step);
      expect(command.jobNameStep, isNull);
      final completed = f.cache.complete(
        command,
        const NativeTestCommandResult.effect(),
      );
      expect(f.cache.submitJson(source).toJson(), completed.toJson());
      expect(f.cache.takeNext(), isNull);
    }
  });

  test(
    'details refuses changed identity, expired work and non-opted-in action',
    () {
      final f = Fixture();
      expect(
        f.cache.submitJson(detailsStep(f, 'inspect')).state,
        NativeTestCommandState.accepted,
      );
      expect(
        f.cache.submitJson(detailsStep(f, 'resolveNotes')).error,
        NativeTestCommandError.identityConflict,
      );
      final old = Fixture();
      expect(
        old.cache
            .submitJson(
              detailsStep(old, 'inspect'),
              allowedActions: {
                NativeTestAction.jobNameUi,
                NativeTestAction.observe,
              },
            )
            .error,
        NativeTestCommandError.wrongPhase,
      );
      expect(old.cache.takeNext(), isNull);
      final expired = Fixture()..now = 1000;
      expect(
        expired.cache
            .submitJson(detailsStep(expired, 'editMixedOffline'))
            .error,
        NativeTestCommandError.deadlineExpired,
      );
      expect(expired.cache.takeNext(), isNull);
    },
  );

  test(
    'arbitrary details values, scripts, name steps and extra keys refuse',
    () {
      for (final invalid in [
        null,
        '',
        'renameSequential',
        'runShell',
        1,
        {},
        [],
      ]) {
        final f = Fixture();
        expect(
          f.cache.submitJson(detailsStep(f, invalid)).error,
          NativeTestCommandError.invalidRequest,
        );
        expect(f.cache.takeNext(), isNull);
      }
      final f = Fixture();
      final source = change(detailsStep(f, 'inspect'), (value) {
        (value['arguments'] as Map)['fields'] = {'notes': 'arbitrary'};
      });
      expect(
        f.cache.submitJson(source).error,
        NativeTestCommandError.invalidRequest,
      );
      expect(f.cache.takeNext(), isNull);
    },
  );

  test('fresh details run rejects V19 and uses separate custody namespace', () {
    void validate(String run, {bool created = true}) =>
        adapter.validateJoinNativeDefines(
          enabled: true,
          run: run,
          role: 'owner',
          platform: 'windows',
          revision: 'a' * 40,
          tree: 'b' * 40,
          adapter: 'c' * 64,
          createdMode: created,
          detailsMode: true,
          productRevision: 'a' * 40,
        );
    expect(() => validate(adapter.jobDetailsNativeRun), returnsNormally);
    expect(
      () => validate(adapter.createdJobNativeRun),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(
      () => validate(adapter.jobDetailsNativeRun, created: false),
      throwsA(isA<NativeTestFailure>()),
    );
    expect(
      adapter.joinNativeNamespace(
        adapter.jobDetailsNativeRun,
        'owner',
        createdMode: true,
        detailsMode: true,
      ),
      isNot(
        adapter.joinNativeNamespace(
          adapter.createdJobNativeRun,
          'owner',
          createdMode: true,
        ),
      ),
    );
  });

  test('mixed repeat requires actual 1/1 then 0/0 on same Pair within five minutes', () {
    Map<String, Object?> terminal(
      int sent,
      int received,
      int time, {
      int page = 1,
    }) => {
      'complete': true,
      'sent': sent,
      'received': received,
      'elapsedMillis': time,
      'pageEpoch': page,
    };
    expect(
      () => adapter.validateJobDetailsNativeMixedRepeat([
        terminal(1, 1, 5),
        terminal(0, 0, 300005),
      ]),
      returnsNormally,
    );
    for (final sequence in [
      <Map<String, Object?>>[],
      [terminal(1, 1, 5)],
      [terminal(1, 0, 5), terminal(0, 0, 6)],
      [terminal(1, 1, 5), terminal(0, 0, 300006)],
      [terminal(1, 1, 5), terminal(0, 0, 6, page: 2)],
      [
        terminal(1, 1, 5),
        {...terminal(0, 0, 6), 'complete': false},
      ],
    ]) {
      expect(
        () => adapter.validateJobDetailsNativeMixedRepeat(sequence),
        throwsA(isA<NativeTestFailure>()),
      );
    }
  });
}
