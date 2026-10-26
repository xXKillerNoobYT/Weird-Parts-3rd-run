import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import '../../tool/mock_shop/company.dart';
import '../../tool/mock_shop/fixture.dart';

void main() {
  late MockShopFixture fixture;
  setUpAll(() {
    fixture = MockShopFixture.read(Directory('test/fixtures/mock_shop'));
  });

  test(
    'seven signed fixture Jobs sync, repeat and survive database reopen',
    () async {
      final pair = await MockCompanyPair.create(fixture);
      addTearDown(pair.close);
      expect(await pair.a.db.select(pair.a.db.companyJobs).get(), hasLength(7));
      expect(
        await pair.a.db.select(pair.a.db.companyJobDetails).get(),
        hasLength(7),
      );
      expect(await pair.b.db.select(pair.b.db.companyJobs).get(), isEmpty);
      expect(await pair.a.db.select(pair.a.db.parts).get(), isEmpty);
      expect(await pair.a.db.select(pair.a.db.jobLines).get(), isEmpty);
      final original = await pair.a.publicJobState();
      await pair.a.importJobs(fixture);
      expect(await pair.a.publicJobState(), original);
      final synced = await pair.openSync();
      final first = await synced.a.syncNow();
      expect(
        first.complete,
        isTrue,
        reason: '${first.failure?.stage.name}/${first.failure?.reason.name}',
      );
      expect(first.received, 0);
      expect(first.sent, greaterThan(0));
      expect(await pair.b.db.select(pair.b.db.companyJobs).get(), hasLength(7));
      expect(
        await pair.b.db.select(pair.b.db.companyJobDetails).get(),
        hasLength(7),
      );
      expect(await pair.b.publicJobState(), original);
      final receiver = await pair.b.views();
      expect(
        receiver.where((v) => v.details.status.value.name == 'active'),
        hasLength(5),
      );
      expect(
        receiver.where((v) => v.details.status.value.name == 'archived'),
        hasLength(2),
      );
      final repeated = await synced.a.syncNow();
      expect(
        repeated.complete,
        isTrue,
        reason:
            '${repeated.failure?.stage.name}/${repeated.failure?.reason.name}',
      );
      expect(repeated.sent, 0);
      expect(repeated.received, 0);
      await pair.reopen();
      expect(await pair.a.publicJobState(), original);
      expect(await pair.b.publicJobState(), original);
      final reopened = await pair.openSync();
      final after = await reopened.a.syncNow();
      expect(
        after.complete,
        isTrue,
        reason: '${after.failure?.stage.name}/${after.failure?.reason.name}',
      );
      expect(after.sent, 0);
      expect(after.received, 0);
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test('production controller exchanges independent offline Job detail edits', () async {
    final pair = await MockCompanyPair.create(fixture);
    addTearDown(pair.close);
    final initial = await pair.openSync();
    final initialResult = await initial.a.syncNow();
    expect(
      initialResult.complete,
      isTrue,
      reason:
          '${initialResult.failure?.stage.name}/${initialResult.failure?.reason.name}',
    );
    await initial.close();
    final aNotes = (await pair.a.views())
        .singleWhere(
          (v) => v.baseJob.id == fixture.nativeId('company-job', 'JOB-001'),
        )
        .details
        .notes
        .value!;
    final bNotes = (await pair.b.views())
        .singleWhere(
          (v) => v.baseJob.id == fixture.nativeId('company-job', 'JOB-002'),
        )
        .details
        .notes
        .value!;
    final aEdit = canonicalMockJson({
      ...jsonDecode(aNotes) as Map<String, dynamic>,
      'scenario_edit': 'offline A',
    });
    final bEdit = canonicalMockJson({
      ...jsonDecode(bNotes) as Map<String, dynamic>,
      'scenario_edit': 'offline B',
    });
    await pair.a.patchNotes(fixture, 'JOB-001', aEdit, 'offline-a');
    await pair.b.patchNotes(fixture, 'JOB-002', bEdit, 'offline-b');
    final connection = await pair.openSync();
    final exchanged = await connection.a.syncNow();
    expect(
      exchanged.complete,
      isTrue,
      reason:
          '${exchanged.failure?.stage.name}/${exchanged.failure?.reason.name}',
    );
    expect(exchanged.sent, 1);
    expect(exchanged.received, 1);
    expect(await pair.a.publicJobState(), await pair.b.publicJobState());
    final all = await pair.a.views();
    expect(
      all
          .singleWhere(
            (v) => v.baseJob.id == fixture.nativeId('company-job', 'JOB-001'),
          )
          .details
          .notes
          .value,
      aEdit,
    );
    expect(
      all
          .singleWhere(
            (v) => v.baseJob.id == fixture.nativeId('company-job', 'JOB-002'),
          )
          .details
          .notes
          .value,
      bEdit,
    );
    final repeated = await connection.a.syncNow();
    expect(
      repeated.complete,
      isTrue,
      reason:
          '${repeated.failure?.stage.name}/${repeated.failure?.reason.name}',
    );
    expect(repeated.sent, 0);
    expect(repeated.received, 0);
    await pair.reopen();
    expect(await pair.a.publicJobState(), await pair.b.publicJobState());
    expect(await pair.a.db.select(pair.a.db.companyJobs).get(), hasLength(7));
    expect(await pair.b.db.select(pair.b.db.companyJobs).get(), hasLength(7));
  }, timeout: const Timeout(Duration(minutes: 6)));

  test(
    'wrong company command and changed import refuse without Job mutation',
    () async {
      final pair = await MockCompanyPair.create(fixture);
      addTearDown(pair.close);
      final before = await pair.a.publicJobState();
      final ownedDb = pair.a.db;
      final ownedInstallation = pair.a.installation;
      final ownedEnrollment = pair.a.enrollment;
      final ownedOwner = pair.a.owner;
      expect(() => (pair.a as dynamic).db = pair.b.db, throwsNoSuchMethodError);
      expect(
        () => (pair.a as dynamic).installation = pair.b.installation,
        throwsNoSuchMethodError,
      );
      expect(
        () => (pair.a as dynamic).enrollment = pair.b.enrollment,
        throwsNoSuchMethodError,
      );
      expect(
        () => (pair.a as dynamic).owner = pair.b.owner,
        throwsNoSuchMethodError,
      );
      expect(identical(pair.a.db, ownedDb), isTrue);
      expect(identical(pair.a.installation, ownedInstallation), isTrue);
      expect(identical(pair.a.enrollment, ownedEnrollment), isTrue);
      expect(identical(pair.a.owner, ownedOwner), isTrue);
      await expectLater(
        pair.a.commands.createJob(
          CreateJob(
            companyId: const Uuid().v4(),
            shopId: pair.a.owner.identity.shopId,
            jobId: const Uuid().v4(),
            requestId: const Uuid().v4(),
            name: 'Wrong company synthetic probe',
          ),
          ownerSession: pair.a.owner,
        ),
        throwsA(
          isA<CompanyBootstrapRefusal>().having(
            (error) => error.message,
            'message',
            'Command is outside this company',
          ),
        ),
      );
      expect(await pair.a.publicJobState(), before);
      await pair.a.patchNotes(
        fixture,
        'JOB-001',
        'Separate deliberate edit',
        'changed-before-import',
      );
      final edited = await pair.a.publicJobState();
      final detailCount =
          (await pair.a.db.select(pair.a.db.companyJobDetails).get()).length;
      await pair.a.patchNotes(
        fixture,
        'JOB-001',
        'Separate deliberate edit',
        'changed-before-import',
      );
      expect(await pair.a.publicJobState(), edited);
      expect(
        (await pair.a.db.select(pair.a.db.companyJobDetails).get()).length,
        detailCount,
      );
      await expectLater(
        pair.a.patchNotes(
          fixture,
          'JOB-001',
          'Different content',
          'changed-before-import',
        ),
        throwsStateError,
      );
      expect(await pair.a.publicJobState(), edited);
      await pair.reopen();
      await pair.a.patchNotes(
        fixture,
        'JOB-001',
        'Separate deliberate edit',
        'changed-before-import',
      );
      expect(await pair.a.publicJobState(), edited);
      expect(
        (await pair.a.db.select(pair.a.db.companyJobDetails).get()).length,
        detailCount,
      );
      await expectLater(pair.a.importJobs(fixture), throwsStateError);
      expect(await pair.a.publicJobState(), edited);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
