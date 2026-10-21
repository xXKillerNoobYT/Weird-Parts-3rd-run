import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';

void main() {
  test('reserved line identity rejects blanks and collisions without changing a saved line', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final device = await db.settingsDao.ensureDeviceId();
    final jobs = JobsRepository(db, device);
    final job = await jobs.createJob('Synthetic reserved identity');
    for (final invalid in ['', '   ']) {
      await expectLater(
        jobs.addLine(
          jobId: job,
          reservedLineId: invalid,
          customName: 'Refused',
          neededQty: 3,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Reserved Job line ID must not be empty',
          ),
        ),
      );
    }
    expect(await jobs.listLinesForJob(job), isEmpty);
    final id = await jobs.addLine(
      jobId: job,
      reservedLineId: 'synthetic-reserved-line',
      customName: 'One saved line',
      neededQty: 3,
    );
    expect(id, 'synthetic-reserved-line');
    await expectLater(
      jobs.addLine(
        jobId: job,
        reservedLineId: id,
        customName: 'Must not overwrite',
        neededQty: 99,
      ),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('UNIQUE constraint failed: job_lines.id'),
        ),
      ),
    );
    final saved = await jobs.listLinesForJob(job);
    expect(saved, hasLength(1));
    expect(saved.single.id, 'synthetic-reserved-line');
    expect(saved.single.customName, 'One saved line');
    expect(saved.single.neededQty, 3);
  });
}
