import 'dart:io';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/company/company_jobs_panel.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';
import 'package:wired_parts/features/jobs/job_detail_page.dart';
import 'package:wired_parts/features/jobs/jobs_page.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/reset/local_data_reset.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

import 'company_job_test_support.dart';
import '../../../integration_test/company_bootstrap_native_test.dart'
    show companyJobCreationIsReady;

Future<void> waitForWidget(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 400 && target.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(target, findsOneWidget);
}

final class CapacityCommands extends CompanyJobCommands {
  CapacityCommands({required super.enrollment});
  @override
  Future<JobLineCommandReceipt> createJob(
    CreateJob command, {
    required CompanySession ownerSession,
  }) async {
    throw const CompanyJobCapacityRefusal();
  }
}

void main() {
  testWidgets('lost reply holds one command and retry displays one Job', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('company-job-widget-');
    final db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/shop.sqlite')),
    );
    addTearDown(() async {
      await db.close();
      root.deleteSync(recursive: true);
    });
    final installation = InstallationSecurity(
      store: JobTestStore(),
      namespace: 'synthetic.job-widget',
    );
    final enrollment = CompanyEnrollment(installation: installation, db: db);
    late OwnerSession owner;
    await tester.runAsync(() async {
      await installation.start(db);
      await enrollment.create(
        companyName: 'Widget Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'widget authority phrase',
        recoveryFile: File('${root.path}/authority.wpca'),
      );
      owner = await enrollment.signIn('1234');
    });
    var loseReply = true;
    final commands = CompanyJobCommands(
      enrollment: enrollment,
      afterCommit: () async {
        if (loseReply) {
          loseReply = false;
          throw StateError('reply lost');
        }
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CompanyJobsPanel(commands: commands, owner: owner),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await waitForWidget(tester, find.byKey(const Key('company-job-name')));
    await tester.enterText(
      find.byKey(const Key('company-job-name')),
      'Retained Job',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('company-create-job')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await waitForWidget(tester, find.text('Retry same Job'));
    expect(find.text('Retry same Job'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('company-job-name')))
          .enabled,
      isFalse,
    );
    final before = await tester.runAsync(() => db.select(db.companyJobs).get());
    expect(before, hasLength(1));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('company-create-job')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await waitForWidget(tester, find.text('Retained Job'));
    expect(find.text('Retained Job'), findsOneWidget);
    expect(
      find.byKey(Key('company-job-${before!.single.jobId}')),
      findsOneWidget,
    );
    expect(
      await tester.runAsync(() => db.select(db.companyJobs).get()),
      before,
    );
    expect(find.textContaining('Peer delivery status unknown'), findsOneWidget);
    for (final unicodeName in ['😀' * 51, '👨‍👩‍👧‍👦' * 100]) {
      await tester.enterText(
        find.byKey(const Key('company-job-name')),
        unicodeName,
      );
      await tester.pump();
      expect(
        find.text(unicodeName == '😀' * 51 ? '51/100' : '100/100'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('company-create-job')));
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await waitForWidget(
        tester,
        find.descendant(
          of: find.byKey(const Key('company-jobs-list')),
          matching: find.text(unicodeName),
        ),
      );
    }
    final unicodeRows = await tester.runAsync(
      () => db.select(db.companyJobs).get(),
    );
    expect(unicodeRows, hasLength(3));
    await tester.enterText(
      find.byKey(const Key('company-job-name')),
      'a${'\u0301' * 4096}',
    );
    await tester.tap(find.byKey(const Key('company-create-job')));
    await tester.pump();
    expect(
      find.text('Job name is too large. Shorten the name and retry.'),
      findsOneWidget,
    );
    expect(find.text('Retry same Job'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('company-job-name')))
          .enabled,
      isTrue,
    );
    expect(
      await tester.runAsync(() => db.select(db.companyJobs).get()),
      unicodeRows,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CompanyJobsPanel(
              key: const Key('capacity-panel'),
              commands: CapacityCommands(enrollment: enrollment),
              owner: owner,
            ),
          ),
        ),
      ),
    );
    await waitForWidget(tester, find.byKey(const Key('company-job-name')));
    await tester.enterText(
      find.byKey(const Key('company-job-name')),
      'At capacity',
    );
    await tester.tap(find.byKey(const Key('company-create-job')));
    await waitForWidget(tester, find.textContaining('512 Job capacity'));
    expect(find.text('Retry same Job'), findsNothing);
    expect(find.text('Retained Job'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('company-job-name')))
          .enabled,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('company gate creates and lists Job without legacy routes', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('company-job-gate-');
    final db = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/shop.sqlite')),
    );
    addTearDown(() async {
      await db.close();
      root.deleteSync(recursive: true);
    });
    final installation = InstallationSecurity(
      store: JobTestStore(),
      namespace: 'synthetic.job-gate',
    );
    await tester.runAsync(() async {
      await installation.start(db);
      await CompanyEnrollment(installation: installation, db: db).create(
        companyName: 'Gate Crew',
        policy: CompanyContinuityPolicy.localContinuity,
        pin: '1234',
        recoveryPassphrase: 'gate authority phrase',
        recoveryFile: File('${root.path}/authority.wpca'),
      );
    });
    final deviceId = await tester.runAsync(
      () => db.settingsDao.ensureDeviceId(),
    );
    await tester.pumpWidget(
      WiredPartsApp(
        db: db,
        pin: PinService(db.settingsDao),
        deviceId: deviceId!,
        installation: installation,
        enableCompanyBootstrap: true,
        reset: LocalDataReset(supportDir: root),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await waitForWidget(tester, find.byKey(const Key('company-signin-pin')));
    expect(find.byKey(const Key('company-job-name')), findsNothing);
    await tester.enterText(find.byKey(const Key('company-signin-pin')), '1234');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('company-signin')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await waitForWidget(tester, find.byKey(const Key('company-job-name')));
    await tester.enterText(
      find.byKey(const Key('company-job-name')),
      'Company Gate Job',
    );
    await tester.ensureVisible(find.byKey(const Key('company-create-job')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('company-create-job')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await waitForWidget(tester, find.text('Company Gate Job'));
    expect(find.text('Company Gate Job'), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(find.byType(JobsPage), findsNothing);
    expect(find.byType(JobDetailPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'native completion waits for committed list item beyond pending input',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'company-job-native-ready-',
      );
      final db = AppDatabase.forTesting(
        NativeDatabase(File('${root.path}/shop.sqlite')),
      );
      addTearDown(() async {
        await db.close();
        root.deleteSync(recursive: true);
      });
      final installation = InstallationSecurity(
        store: JobTestStore(),
        namespace: 'synthetic.native-job-ready',
      );
      final enrollment = CompanyEnrollment(installation: installation, db: db);
      late OwnerSession owner;
      await tester.runAsync(() async {
        await installation.start(db);
        await enrollment.create(
          companyName: 'Native Readiness Crew',
          policy: CompanyContinuityPolicy.localContinuity,
          pin: '1234',
          recoveryPassphrase: 'native readiness authority phrase',
          recoveryFile: File('${root.path}/authority.wpca'),
        );
        owner = await enrollment.signIn('1234');
      });
      final reachedCommit = Completer<void>();
      final releaseCommit = Completer<void>();
      var attempts = 0;
      final commands = CompanyJobCommands(
        enrollment: enrollment,
        beforeCommit: () async {
          attempts++;
          reachedCommit.complete();
          await releaseCommit.future;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CompanyJobsPanel(commands: commands, owner: owner),
            ),
          ),
        ),
      );
      await waitForWidget(tester, find.byKey(const Key('company-job-name')));
      const jobName = 'Synthetic pending native Job';
      final renderedJob = find.descendant(
        of: find.byKey(const Key('company-jobs-list')),
        matching: find.text(jobName),
      );
      try {
        await tester.enterText(
          find.byKey(const Key('company-job-name')),
          jobName,
        );
        await tester.tap(find.byKey(const Key('company-create-job')));
        for (var i = 0; i < 400 && !reachedCommit.isCompleted; i++) {
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(reachedCommit.isCompleted, isTrue);
        await tester.pump();
        expect(find.text(jobName), findsOneWidget);
        expect(renderedJob, findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('company-create-job')))
              .onPressed,
          isNull,
        );
        expect(companyJobCreationIsReady(tester, jobName), isFalse);
        releaseCommit.complete();
        await waitForWidget(tester, renderedJob);
        expect(companyJobCreationIsReady(tester, jobName), isTrue);
        expect(attempts, 1);
        await tester.runAsync(() async {
          final jobs = await db.select(db.jobs).get();
          final records = await db.select(db.companyJobs).get();
          expect(jobs, hasLength(1));
          expect(records, hasLength(1));
          expect(jobs.single.id, records.single.jobId);
          expect(jobs.single.name, jobName);
          expect(records.single.outgoing, isTrue);
          await JobLineCommandReceipt.verifyAdmissionSeal(
            records.single.receiptBytes,
            installation.identity!,
            installation.receivingStoreGeneration!.value,
            expectedFamily: CompanyCommandFamily.jobCreate,
          );
        });
      } finally {
        if (!releaseCommit.isCompleted) releaseCommit.complete();
        await waitForWidget(tester, renderedJob);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
