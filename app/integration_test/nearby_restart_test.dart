import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/shell/home_shell.dart';
import 'package:wired_parts/main.dart' as production;

import '../tool/nearby_lan_workspace.dart';
import '../tool/native_nearby_restart.dart';
import '../tool/native_nearby_test_crypto.dart';
import '../tool/native_nearby_test_fixture.dart';

void main() {
  final expected = NativeRestartExpectation.read(
    enabled: const bool.fromEnvironment('NATIVE_NEARBY_TEST_MODE'),
    platform: Platform.operatingSystem,
    run: const String.fromEnvironment('LAN_VALIDATION_RUN'),
    role: const String.fromEnvironment('LAN_VALIDATION_ROLE'),
    path: const String.fromEnvironment('NATIVE_NEARBY_RESTART_EXPECTATION'),
    sourceRevision: const String.fromEnvironment(
      'NATIVE_NEARBY_SOURCE_REVISION',
    ),
    sourceTree: const String.fromEnvironment('NATIVE_NEARBY_SOURCE_TREE'),
  );
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('existing native installation survives restart', (tester) async {
    final originalPaths = PathProviderPlatform.instance;
    final originalError = FlutterError.onError;
    ValidationWorkspace? workspace;
    AppDatabase? db;
    FlutterError.onError = (_) => originalError?.call(
      FlutterErrorDetails(
        exception: const NativeTestFailure('restart-framework-failed'),
      ),
    );
    try {
      workspace = expected.open();
      PathProviderPlatform.instance = workspace;
      await production.main();
      await _settle(tester);
      final shell = find.byType(HomeShell);
      _require(shell.evaluate().length == 1);
      final scope = AppScope.of(tester.element(shell));
      db = scope.db;
      _require(scope.deviceId == workspace.deviceId);
      _require(await scope.pin.isPinSet() && !scope.pin.isUnlocked);
      final before = await NativeFixtureSnapshot.capture(db, workspace);
      expected.verify(before);
      _require(find.widgetWithText(AppBar, 'Jobs').evaluate().length == 1);
      _require(
        find
                .byKey(const ValueKey('$nativeRestartRun-sender-job'))
                .evaluate()
                .length ==
            1,
      );
      _require(
        find
                .text('Synthetic sender shop $nativeRestartRun')
                .evaluate()
                .length ==
            1,
      );

      await _tap(tester, find.text('More'));
      _require(find.text('Locked').evaluate().length == 1);
      await _tap(tester, find.text('Catalog'));
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Search the tree',
      );
      _require(search.evaluate().length == 1);
      await tester.enterText(search, 'Synthetic sender part');
      await _settle(tester);
      final part = find.byKey(
        const ValueKey('search-$nativeRestartRun-sender-part'),
      );
      _require(part.evaluate().isNotEmpty);
      final general = find.widgetWithText(ListTile, 'General (no brand)');
      _require(general.evaluate().length == 1);
      await tester.ensureVisible(general);
      await _tap(tester, general);
      _require(find.byType(PartDetailPage).evaluate().length == 1);
      _require(
        tester.widget<PartDetailPage>(find.byType(PartDetailPage)).partId ==
            '$nativeRestartRun-sender-part',
      );
      final photoPath = p.join(
        workspace.photos.path,
        '$nativeRestartRun-sender.png',
      );
      final photo = find.byKey(ValueKey(photoPath));
      _require(photo.evaluate().length == 1);
      await tester.ensureVisible(photo);
      await _settle(tester);
      _require(photo.hitTestable().evaluate().length == 1);
      final image = tester.widget<Image>(photo);
      final provider = image.image;
      _require(provider is FileImage && provider.file.path == photoPath);
      final decoded = Completer<bool>();
      final stream = provider.resolve(
        createLocalImageConfiguration(tester.element(photo)),
      );
      final listener = ImageStreamListener(
        (info, _) {
          if (!decoded.isCompleted) {
            decoded.complete(info.image.width > 0 && info.image.height > 0);
          }
        },
        onError: (_, _) {
          if (!decoded.isCompleted) decoded.complete(false);
        },
      );
      stream.addListener(listener);
      try {
        final ok = await tester.runAsync(
          () => decoded.future.timeout(const Duration(seconds: 10)),
        );
        _require(ok == true);
      } finally {
        stream.removeListener(listener);
      }
      await tester.pageBack();
      await _settle(tester);
      await _tap(tester, find.byTooltip('New part'));
      _require(
        find.widgetWithText(AlertDialog, 'Editor PIN').evaluate().length == 1,
      );
      final pinField = find.descendant(
        of: find.widgetWithText(AlertDialog, 'Editor PIN'),
        matching: find.byType(TextField),
      );
      _require(pinField.evaluate().length == 1);
      await tester.enterText(pinField, '1234');
      await _tap(tester, find.widgetWithText(FilledButton, 'Unlock'));
      _require(scope.pin.isUnlocked);
      final namePrompt = find.widgetWithText(AlertDialog, 'New part');
      _require(namePrompt.evaluate().length == 1);
      await _tap(
        tester,
        find.descendant(of: namePrompt, matching: find.text('Cancel')),
      );
      await _tap(tester, find.text('More'));
      await _tap(tester, find.widgetWithText(ListTile, 'Lock catalog'));
      _require(
        !scope.pin.isUnlocked && find.text('Locked').evaluate().length == 1,
      );
      expected.verify(await NativeFixtureSnapshot.capture(db, workspace));
      binding.reportData = <String, dynamic>{
        'format': 1,
        'probe': 'native-nearby-restart',
        'platform': Platform.operatingSystem,
        'run': nativeRestartRun,
        'role': expected.role.name,
        'existingStateEqual': true,
        'jobsRendered': true,
        'partPhotoDecoded': true,
        'pinGatePassed': true,
        'priorNormalQuitProvedByThisTest': false,
      };
    } catch (_) {
      throw const NativeTestFailure('restart-failed');
    } finally {
      try {
        try {
          try {
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            await db?.close();
          }
        } finally {
          try {
            workspace?.close();
          } finally {
            try {
              PathProviderPlatform.instance = originalPaths;
            } finally {
              FlutterError.onError = originalError;
            }
          }
        }
      } catch (_) {
        throw const NativeTestFailure('restart-cleanup-failed');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

void _require(bool condition) {
  if (!condition) rejectNativeTest('restart-check-failed');
}

Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 20),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  _require(finder.evaluate().length == 1);
  await tester.tap(finder);
  await _settle(tester);
}
