import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/pin/pin_service.dart';
import 'package:wired_parts/features/shell/home_shell.dart';

void main() {
  testWidgets('HomeShell shows navigation destinations', (WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final deviceId = await db.settingsDao.ensureDeviceId();
    final pin = PinService(db.settingsDao);

    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: deviceId,
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Jobs'), findsWidgets);
    expect(find.text('Catalog'), findsWidgets);
    expect(find.text('More'), findsWidgets);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
