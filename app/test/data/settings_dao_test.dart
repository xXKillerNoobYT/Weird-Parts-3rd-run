import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('ensureDeviceId is stable', () async {
    final a = await db.settingsDao.ensureDeviceId();
    final b = await db.settingsDao.ensureDeviceId();
    expect(a, equals(b));
    expect(a.isNotEmpty, isTrue);
  });
}
