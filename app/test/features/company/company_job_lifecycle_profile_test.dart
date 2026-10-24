import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/installation/installation_security.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_name_test.dart' show NameFixture;
import 'company_job_test_support.dart' show JobTestStore;
import 'company_join_test.dart' show sqlSnapshot;
import 'company_job_lifecycle_test.dart' show lifecycle;

void main() {
  test('recovered empty entities retain ordinary Job reads and edits but refuse new lifecycle', () async {
    final f = await NameFixture.create();
    final db = AppDatabase.forTesting(
      NativeDatabase(File('${f.root.path}/recovered.sqlite')),
    );
    final security = InstallationSecurity(
      store: JobTestStore(),
      namespace: 'synthetic.lifecycle-recovered',
    );
    try {
      await security.start(db);
      final enrollment = CompanyEnrollment(db: db, installation: security);
      final identity = await enrollment.recover(
        policy: CompanyContinuityPolicy.localContinuity,
        sourceFile: File('${f.root.path}/authority.wpca'),
        sourcePassphrase: 'synthetic names authority',
        newPin: '1234',
        newRecoveryPassphrase: 'recovered synthetic lifecycle authority',
        newRecoveryFile: File('${f.root.path}/recovered.wpca'),
      );
      final owner = await enrollment.signIn('1234');
      final commands = CompanyJobCommands(enrollment: enrollment);
      await commands.createJob(
        CreateJob(
          companyId: identity.companyId,
          shopId: identity.shopId,
          jobId: const Uuid().v4(),
          requestId: const Uuid().v4(),
          name: 'Recovered Job',
        ),
        ownerSession: owner,
      );
      var view = (await commands.listJobViews(ownerSession: owner)).single;
      await commands.renameJob(
        RenameJob(
          companyId: identity.companyId,
          shopId: identity.shopId,
          jobId: view.baseJob.id,
          requestId: const Uuid().v4(),
          creationDigest: view.creationDigest,
          observedHeads: [],
          name: 'Recovered edit',
        ),
        ownerSession: owner,
      );
      view = (await commands.listJobViews(ownerSession: owner)).single;
      expect(view.displayName, 'Recovered edit');
      expect(view.lifecycle.state, CompanyJobLifecycleState.live);
      final before = await sqlSnapshot(db);
      await expectLater(
        commands.setJobLifecycle(
          SetJobLifecycle(
            companyId: identity.companyId,
            shopId: identity.shopId,
            jobId: view.baseJob.id,
            requestId: const Uuid().v4(),
            creationDigest: view.creationDigest,
            observed: view.lifecycle.context,
            choice: JobLifecycleChoice.deleted,
          ),
          ownerSession: owner,
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await sqlSnapshot(db), before);
      expect(
        await commands.lifecycleUnavailableReason(view, owner),
        contains('genesis'),
      );
    } finally {
      await db.close();
      await f.close();
    }
  });

  for (final floor in [
    'authority',
    'permission',
    'credential',
    'grant',
    'revocation.user',
    'revocation.device',
    'revocation.grant',
  ]) {
    test(
      'lifecycle current $floor enforcement refuses without mutation',
      () async {
        final f = await NameFixture.create();
        try {
          final view = (await f.commands.listJobViews(ownerSession: f.owner))
              .single;
          final command = lifecycle(f, view);
          final state = f.store.states[f.security.namespace]!;
          final raw =
              jsonDecode(utf8.decode(state.bytes)) as Map<String, dynamic>;
          final facts = jsonDecode(
            (await f.db.select(f.db.companyAuthorityFacts).get())
                .single
                .signedBytes,
          ) as Map;
          final grant =
              ((facts['body'] as Map)['devices'] as List).single['grant']
                  as String;
          final actor = floor == 'authority'
              ? f.owner.identity.companyId
              : floor.endsWith('grant')
              ? grant
              : floor.endsWith('device')
              ? f.owner.identity.deviceId
              : f.owner.identity.userId;
          (raw['floors'] as Map)['$floor.$actor'] =
              floor.startsWith('revocation') ? 1 : 2;
          f.store.states[f.security.namespace] = ProtectedInstallationState(
            const Uuid().v4(),
            Uint8List.fromList(utf8.encode(jsonEncode(raw))),
          );
          final before = await sqlSnapshot(f.db),
              protected = base64Encode(
                f.store.states[f.security.namespace]!.bytes,
              );
          await expectLater(
            f.commands.setJobLifecycle(command, ownerSession: f.owner),
            throwsA(anything),
          );
          expect(await sqlSnapshot(f.db), before);
          expect(
            base64Encode(f.store.states[f.security.namespace]!.bytes),
            protected,
          );
        } finally {
          await f.close();
        }
      },
    );
  }
  test('typed child writer cannot issue an assertion against signed empty entities', () async {
    final f = await NameFixture.create();
    try {
      final before = await sqlSnapshot(f.db);
      await expectLater(
        f.enrollment.issueJobLineAssertion(
          JobLineCommand(
            companyId: f.owner.identity.companyId,
            shopId: f.owner.identity.shopId,
            lineId: const Uuid().v4(),
            requestId: const Uuid().v4(),
            observedHeads: [],
            mutation: const JobLinePatch(notes: SetField('Unsupported child')),
          ),
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await sqlSnapshot(f.db), before);
    } finally {
      await f.close();
    }
  });
}
