import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/job_line_commands/job_line_commands.dart';

import 'company_job_name_test.dart' show NameFixture;

void main() {
  test(
    'production details patch saves all five fields and preserves creation',
    () async {
      final f = await NameFixture.create();
      try {
        final creation = await f.db.select(f.db.companyJobs).get();
        final jobs = await f.db.select(f.db.jobs).get();
        final command = PatchJobDetails(
          companyId: f.owner.identity.companyId,
          shopId: f.owner.identity.shopId,
          jobId: f.createCommand.jobId,
          requestId: const Uuid().v4(),
          creationDigest: f.creationDigest,
          patch: const JobDetailsPatch(
            customer: SetField('Acme'),
            location: SetField('Site 1'),
            jobNumber: SetField('JP-17'),
            status: SetField(CompanyJobStatus.archived),
            notes: SetField('Gate 3'),
          ),
          observedHeads: {for (final field in JobDetailField.values) field: []},
        );
        await f.commands.patchJobDetails(command, ownerSession: f.owner);
        final view = (await f.commands.listJobViews(ownerSession: f.owner))
            .single;
        expect(view.details.customer.value, 'Acme');
        expect(view.details.location.value, 'Site 1');
        expect(view.details.jobNumber.value, 'JP-17');
        expect(view.details.status.value, CompanyJobStatus.archived);
        expect(view.details.notes.value, 'Gate 3');
        expect(view.resolvedName, 'Baseline');
        expect(await f.db.select(f.db.companyJobs).get(), creation);
        expect(await f.db.select(f.db.jobs).get(), jobs);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'disjoint fields combine and nullable clear/archive restore are durable',
    () async {
      final f = await NameFixture.create();
      try {
        await f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(
              customer: SetField('Acme'),
              status: SetField(CompanyJobStatus.archived),
            ),
          ),
          ownerSession: f.owner,
        );
        await f.commands.patchJobDetails(
          details(f, const JobDetailsPatch(notes: SetField('Gate 3'))),
          ownerSession: f.owner,
        );
        var v = (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .details;
        expect(v.customer.value, 'Acme');
        expect(v.notes.value, 'Gate 3');
        expect(v.status.value, CompanyJobStatus.archived);
        await f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(
              customer: SetField(null),
              status: SetField(CompanyJobStatus.active),
            ),
            parents: {
              JobDetailField.customer: v.customer.heads,
              JobDetailField.status: v.status.heads,
            },
          ),
          ownerSession: f.owner,
        );
        await f.reopen();
        v = (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .details;
        expect(v.customer.value, isNull);
        expect(v.notes.value, 'Gate 3');
        expect(v.status.value, CompanyJobStatus.active);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'same field differs visibly; omitted conflict survives other-field write',
    () async {
      final f = await NameFixture.create();
      try {
        await f.commands.patchJobDetails(
          details(f, const JobDetailsPatch(notes: SetField('A'))),
          ownerSession: f.owner,
        );
        await f.commands.patchJobDetails(
          details(f, const JobDetailsPatch(notes: SetField('B'))),
          ownerSession: f.owner,
        );
        await f.commands.patchJobDetails(
          details(f, const JobDetailsPatch(customer: SetField('Acme'))),
          ownerSession: f.owner,
        );
        final v = (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .details;
        expect(v.notes.hasConflict, isTrue);
        expect(v.notes.candidates.map((c) => c.value).toSet(), {'A', 'B'});
        expect(
          v.notes.candidates.every(
            (c) =>
                c.originalUserId == f.owner.identity.userId &&
                c.originalDeviceId == f.owner.identity.deviceId,
          ),
          isTrue,
        );
        expect(v.customer.value, 'Acme');
        final before = await f.db.select(f.db.companyJobDetails).get();
        await expectLater(
          f.commands.patchJobDetails(
            details(
              f,
              const JobDetailsPatch(notes: SetField('Silent')),
              parents: {JobDetailField.notes: v.notes.heads},
            ),
            ownerSession: f.owner,
          ),
          throwsA(isA<JobLineRefusal>()),
        );
        expect(await f.db.select(f.db.companyJobDetails).get(), before);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'equal-value heads preserve both then ordinary edit supersedes them',
    () async {
      final f = await NameFixture.create();
      try {
        for (var i = 0; i < 2; i++) {
          await f.commands.patchJobDetails(
            details(f, const JobDetailsPatch(notes: SetField('Same'))),
            ownerSession: f.owner,
          );
        }
        var v = (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .details;
        expect(v.notes.hasConflict, isFalse);
        expect(v.notes.heads, hasLength(2));
        await f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(notes: SetField('Next')),
            parents: {JobDetailField.notes: v.notes.heads},
          ),
          ownerSession: f.owner,
        );
        v = (await f.commands.listJobViews(ownerSession: f.owner))
            .single
            .details;
        expect(v.notes.value, 'Next');
        expect(v.notes.heads, hasLength(1));
      } finally {
        await f.close();
      }
    },
  );
  test('explicit per-field resolution retries after new head; changed request refuses', () async {
    final f = await NameFixture.create();
    try {
      for (final n in ['A', 'B']) {
        await f.commands.patchJobDetails(
          details(f, JobDetailsPatch(notes: SetField(n))),
          ownerSession: f.owner,
        );
      }
      final v = (await f.commands.listJobViews(ownerSession: f.owner))
          .single
          .details;
      final resolve = details(
        f,
        const JobDetailsPatch(notes: SetField('Chosen')),
        parents: {JobDetailField.notes: v.notes.heads},
        resolve: {JobDetailField.notes},
      );
      final receipt = await f.commands.patchJobDetails(
        resolve,
        ownerSession: f.owner,
      );
      await f.commands.patchJobDetails(
        details(f, const JobDetailsPatch(notes: SetField('Stale'))),
        ownerSession: f.owner,
      );
      final count = (await f.db.select(f.db.companyJobDetails).get()).length;
      expect(
        (await f.commands.patchJobDetails(
          resolve,
          ownerSession: f.owner,
        )).bytes,
        receipt.bytes,
      );
      expect(await f.db.select(f.db.companyJobDetails).get(), hasLength(count));
      await expectLater(
        f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(notes: SetField('Different')),
            request: resolve.requestId,
          ),
          ownerSession: f.owner,
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      await expectLater(
        f.commands.patchJobDetails(
          details(
            f,
            const JobDetailsPatch(notes: SetField('Unseen')),
            parents: {JobDetailField.notes: v.notes.heads},
            resolve: {JobDetailField.notes},
          ),
          ownerSession: f.owner,
        ),
        throwsA(isA<JobLineRefusal>()),
      );
      expect(await f.db.select(f.db.companyJobDetails).get(), hasLength(count));
    } finally {
      await f.close();
    }
  });
  test('stale ordinary edit retains its common agreed predecessor', () async {
    final f = await NameFixture.create();
    try {
      final z = await f.commands.patchJobDetails(
        details(f, const JobDetailsPatch(notes: SetField('Agreed'))),
        ownerSession: f.owner,
      );
      final a = await f.commands.patchJobDetails(
        details(
          f,
          const JobDetailsPatch(notes: SetField('A')),
          parents: {
            JobDetailField.notes: [z.operationId],
          },
        ),
        ownerSession: f.owner,
      );
      await f.commands.patchJobDetails(
        details(
          f,
          const JobDetailsPatch(notes: SetField('B')),
          parents: {
            JobDetailField.notes: [z.operationId],
          },
        ),
        ownerSession: f.owner,
      );
      var v = (await f.commands.listJobViews(ownerSession: f.owner))
          .single
          .details;
      final frontier = v.notes.heads;

      final first = details(
        f,
        const JobDetailsPatch(notes: SetField('C')),
        parents: {JobDetailField.notes: frontier},
        resolve: {JobDetailField.notes},
      );
      await f.commands.patchJobDetails(first, ownerSession: f.owner);
      // A genuinely stale ordinary edit observes one former head and remains concurrent.
      await f.commands.patchJobDetails(
        details(
          f,
          const JobDetailsPatch(notes: SetField('D')),
          parents: {
            JobDetailField.notes: [a.operationId],
          },
        ),
        ownerSession: f.owner,
      );
      v = (await f.commands.listJobViews(ownerSession: f.owner)).single.details;
      expect(v.notes.hasConflict, isTrue);
      expect(v.notes.lastAgreedValue, 'A');
    } finally {
      await f.close();
    }
  });
  test('concurrent null empty and text values remain distinct until explicit resolution', () async {
    final f = await NameFixture.create();
    try {
      for (final value in <String?>[null, '', 'Text']) {
        await f.commands.patchJobDetails(
          details(f, JobDetailsPatch(notes: SetField(value))),
          ownerSession: f.owner,
        );
      }
      var value = (await f.commands.listJobViews(ownerSession: f.owner))
          .single
          .details
          .notes;
      expect(value.hasConflict, isTrue);
      expect(value.candidates.map((c) => c.value).toSet(), {null, '', 'Text'});
      expect(value.lastAgreedValue, isNull);
      await f.commands.patchJobDetails(
        details(
          f,
          const JobDetailsPatch(notes: SetField('')),
          parents: {JobDetailField.notes: value.heads},
          resolve: {JobDetailField.notes},
        ),
        ownerSession: f.owner,
      );
      value = (await f.commands.listJobViews(ownerSession: f.owner))
          .single
          .details
          .notes;
      expect(value.hasConflict, isFalse);
      expect(value.value, '');
      expect(value.heads.length, 1);
    } finally {
      await f.close();
    }
  });
}

PatchJobDetails details(
  NameFixture f,
  JobDetailsPatch patch, {
  Map<JobDetailField, List<String>> parents = const {},
  Set<JobDetailField> resolve = const {},
  String? request,
}) {
  final fields = <JobDetailField>[
    if (patch.customer is SetField) JobDetailField.customer,
    if (patch.location is SetField) JobDetailField.location,
    if (patch.jobNumber is SetField) JobDetailField.jobNumber,
    if (patch.status is SetField) JobDetailField.status,
    if (patch.notes is SetField) JobDetailField.notes,
  ];
  return PatchJobDetails(
    companyId: f.owner.identity.companyId,
    shopId: f.owner.identity.shopId,
    jobId: f.createCommand.jobId,
    requestId: request ?? const Uuid().v4(),
    creationDigest: f.creationDigest,
    patch: patch,
    observedHeads: {for (final field in fields) field: parents[field] ?? []},
    resolvingFields: resolve,
  );
}
