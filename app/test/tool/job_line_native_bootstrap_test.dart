import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

import '../features/job_line_commands/atomic_job_line_support.dart';
import '../../tool/job_line_native_validation.dart';

final class _UnavailableStore implements InstallationSecureStore {
  _UnavailableStore({this.failNamespaceSuffix});
  final String? failNamespaceSuffix;
  final states = <String, ProtectedInstallationState>{};
  @override
  Future<ProtectedInstallationState?> readState(String namespace) async =>
      states[namespace];

  @override
  Future<String> compareAndSwapState(
    String namespace, {
    required String? expectedRevision,
    required String nextRevision,
    required Uint8List bytes,
  }) async {
    if (failNamespaceSuffix == null ||
        namespace.endsWith(failNamespaceSuffix!)) {
      throw PlatformException(
        code: 'fixture-unavailable',
        message: 'private-native-detail',
      );
    }
    states[namespace] = ProtectedInstallationState(nextRevision, bytes);
    return nextRevision;
  }
}

final class _ObservedClose extends QueryInterceptor {
  bool closed = false;
  @override
  Future<void> close(QueryExecutor inner) async {
    await inner.close();
    closed = true;
  }
}

void main() {
  for (final failureIndex in [0, 1]) {
    test(
      'nonready native store $failureIndex closes every acquired database before returning failure',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'jobline-bootstrap-',
        );
        final closes = <_ObservedClose>[];
        final executors = <QueryExecutor>[];
        try {
          await expectLater(
            AtomicFixture.create(
              ownedDirectory: directory,
              nativeStore: _UnavailableStore(
                failNamespaceSuffix: '.$failureIndex',
              ),
              namespaceForStore: (i) => 'synthetic.bootstrap.$i',
              databaseExecutor: (file) {
                final observer = _ObservedClose();
                closes.add(observer);
                final executor = NativeDatabase(file).interceptWith(observer);
                executors.add(executor);
                return executor;
              },
            ),
            throwsA(
              isA<FixtureBootstrapFailure>()
                  .having(
                    (failure) => failure.stage,
                    'stage',
                    FixtureBootstrapStage.installation,
                  )
                  .having(
                    (failure) => failure.readiness,
                    'readiness',
                    InstallationReadiness.unavailable,
                  )
                  .having(
                    (failure) => failure.storeIndex,
                    'store',
                    failureIndex,
                  )
                  .having((failure) => failure.databasesClosed, 'closed', true),
            ),
          );
          expect(closes.length, 3);
          expect(closes.every((observer) => observer.closed), isTrue);
        } finally {
          for (final executor in executors) {
            await executor.close();
          }
          await directory.delete(recursive: true);
        }
      },
    );
  }

  testWidgets(
    'native helper records and renders redacted startup failure without PASS',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'jobline-bootstrap-status-',
      );
      final previousExit = exitCode;
      try {
        await tester.runAsync(
          () => runJobLineNativeValidation(
            'failure-unit',
            validationStore: _UnavailableStore(),
            temporaryDirectory: directory,
          ),
        );
        await tester.pump();
        expect(find.textContaining('Native job-line FAIL'), findsOneWidget);
        expect(find.textContaining('Native cause unknown'), findsOneWidget);
        expect(exitCode, 1);
        final failures = directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.contains('job-line-failure-'))
            .toList();
        expect(failures, hasLength(1));
        final text = failures.single.readAsStringSync();
        expect(text, isNot(contains('private-native-detail')));
        expect(text, isNot(contains('fixture-unavailable')));
        final failure = jsonDecode(text) as Map;
        expect(failure['passed'], false);
        expect(failure['stage'], 'bootstrap');
        expect(failure['bootstrapStage'], 'installation');
        expect(failure['readiness'], 'unavailable');
        expect(failure['databasesClosed'], true);
        expect(failure['nativeCause'], 'unknown');
        expect(
          directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('job-line-exercise.json')),
          isEmpty,
        );
        expect(
          directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('job-line-restart.json')),
          isEmpty,
        );
      } finally {
        exitCode = previousExit;
        await tester.pumpWidget(const SizedBox.shrink());
        directory.deleteSync(recursive: true);
      }
    },
  );
}
