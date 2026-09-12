import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wired_parts/features/shell/home_shell.dart';

void main() {
  testWidgets('HomeShell shows navigation destinations', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeShell()));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Jobs'), findsWidgets);
    expect(find.text('Catalog'), findsWidgets);
    expect(find.text('More'), findsWidgets);
  });
}
