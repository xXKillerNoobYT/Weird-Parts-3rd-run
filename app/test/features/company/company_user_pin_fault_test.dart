import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

import 'company_join_test.dart' show JoinFixture, sqlSnapshot;
import 'company_user_disable_domain_test.dart' show disableJob;

void main() {
  test(
    'replacement credential can create a Job through its real held commit',
    () async {
      final f = await JoinFixture.create(allowOwnerAdditions: true);
      final user = await f.aEnrollment.createRestrictedUser(
        owner: f.owner,
        requestId: const Uuid().v4(),
        name: 'Casey',
        pin: '0123',
      );
      await f.aEnrollment.resetRestrictedUserPin(
        owner: f.owner,
        userId: user.userId,
        requestId: const Uuid().v4(),
        expectedCredentialVersion: 1,
        pin: '4567',
      );
      await f.aEnrollment.signInUser(user.userId, '4567');
      final id = await disableJob(f.aEnrollment, 'Replacement credential Job');
      final record = (await f.aDb.select(f.aDb.companyJobs).get()).singleWhere(
        (r) => r.jobId == id,
      );
      final proof =
          (jsonDecode(record.operationBytes) as Map)['authorization'] as Map;
      expect((proof['body'] as Map)['credential'], 2);
      expect(
        (jsonDecode(record.operationBytes) as Map)['body']['user'],
        user.userId,
      );
    },
  );
  test('v3 terminal command refuses caller transaction before any protected mutation', () async {
    final f = await JoinFixture.create();
    final user = await f.aEnrollment.createRestrictedUser(
      owner: f.owner,
      requestId: const Uuid().v4(),
      name: 'Casey',
      pin: '0123',
    );
    await f.aEnrollment.resetRestrictedUserPin(
      owner: f.owner,
      userId: user.userId,
      requestId: const Uuid().v4(),
      expectedCredentialVersion: 1,
      pin: '4567',
    );
    final slot = companyUserNamespace(f.a.namespace);
    final before = f.aStore.states[slot]!;
    final sql = await sqlSnapshot(f.aDb);
    await f.aDb.transaction(() async {
      await expectLater(
        f.aEnrollment.disableRestrictedUser(
          owner: f.owner,
          userId: user.userId,
          requestId: const Uuid().v4(),
        ),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
    });
    expect(
      base64Encode(f.aStore.states[slot]!.bytes) == base64Encode(before.bytes),
      isTrue,
    );
    expect(f.aStore.states[slot]!.revision, before.revision);
    expect(await sqlSnapshot(f.aDb), sql);
  });

  test(
    'terminal request cannot reuse an earlier spent reset identity',
    () async {
      final f = await JoinFixture.create();
      final user = await f.aEnrollment.createRestrictedUser(
        owner: f.owner,
        requestId: const Uuid().v4(),
        name: 'Casey',
        pin: '0123',
      );
      final first = const Uuid().v4();
      await f.aEnrollment.resetRestrictedUserPin(
        owner: f.owner,
        userId: user.userId,
        requestId: first,
        expectedCredentialVersion: 1,
        pin: '4567',
      );
      await f.aEnrollment.resetRestrictedUserPin(
        owner: f.owner,
        userId: user.userId,
        requestId: const Uuid().v4(),
        expectedCredentialVersion: 2,
        pin: '6789',
      );
      final slot = companyUserNamespace(f.a.namespace);
      final before = f.aStore.states[slot]!;
      final sql = await sqlSnapshot(f.aDb);
      await expectLater(
        f.aEnrollment.disableRestrictedUser(
          owner: f.owner,
          userId: user.userId,
          requestId: first,
        ),
        throwsA(anything),
      );
      expect(
        base64Encode(f.aStore.states[slot]!.bytes) ==
            base64Encode(before.bytes),
        isTrue,
      );
      expect(f.aStore.states[slot]!.revision, before.revision);
      expect(await sqlSnapshot(f.aDb), sql);
    },
  );
}
