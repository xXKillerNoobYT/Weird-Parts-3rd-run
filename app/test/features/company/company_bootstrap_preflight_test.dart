import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/company/company_bootstrap.dart';
import 'package:wired_parts/features/installation/installation_security.dart';

void main() {
  test('custody storage uses only a reserved companion namespace', () {
    expect(companyCustodyNamespace('production'), 'production.company-custody');
    expect(
      companyCustodyNamespace('synthetic.test'),
      'synthetic.test.company-custody',
    );
    expect(
      () => companyCustodyNamespace('production.other'),
      throwsArgumentError,
    );
  });

  test('bootstrap witness has its own downgrade-blocking schema', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 6);
    await db.customStatement(
      "INSERT INTO company_bootstrap_witnesses "
      "(company_id, bootstrap_id, facts_commitment, package_id, package_digest, status) "
      "VALUES ('company', 'intent', 'facts', 'package', NULL, 'pending')",
    );
    await expectLater(
      CompanyBootstrap.preflightFreshShop(db),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
  });

  test('Create Company admits only an empty, unadopted shop', () async {
    final empty = AppDatabase.forTesting(NativeDatabase.memory());
    await expectLater(CompanyBootstrap.preflightFreshShop(empty), completes);
    await empty.close();

    final legacy = AppDatabase.forTesting(NativeDatabase.memory());
    await legacy.customStatement(
      "INSERT INTO categories (id, origin_device_id, created_at, modified_at, revision, name) "
      "VALUES ('legacy-category', 'old-device', 1, 1, 1, 'Electrical')",
    );
    await expectLater(
      CompanyBootstrap.preflightFreshShop(legacy),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
    await legacy.close();

    final company = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(company.close);
    await company.customStatement(
      "INSERT INTO company_authority_facts (company_id, commitment, signed_bytes) "
      "VALUES ('existing', 'digest', 'bytes')",
    );
    await expectLater(
      CompanyBootstrap.preflightFreshShop(company),
      throwsA(isA<CompanyBootstrapRefusal>()),
    );
  });
  test(
    'orphan company Job journal blocks fresh adoption and legacy mutation',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement(
        "INSERT INTO company_jobs (job_id, company_id, shop_id, origin_generation, request_id, operation_commitment, command_commitment, operation_bytes, projection_bytes, receipt_key, receipt_bytes, audit_bytes, outgoing) VALUES ('orphan', 'company', 'shop', 'origin', 'request', 'op', 'command', '{}', '{}', 'receipt', '{}', '{}', 1)",
      );
      await expectLater(
        CompanyBootstrap.preflightFreshShop(db),
        throwsA(isA<CompanyBootstrapRefusal>()),
      );
      await expectLater(
        db.jobsDao.insertJob(
          id: 'legacy',
          name: 'must refuse',
          deviceId: 'device',
        ),
        throwsA(isA<StateError>()),
      );
      expect(await db.select(db.jobs).get(), isEmpty);
    },
  );
}
