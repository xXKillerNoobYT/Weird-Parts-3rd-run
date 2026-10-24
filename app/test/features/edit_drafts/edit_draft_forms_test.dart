import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/app.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/catalog/catalog_repository.dart';
import 'package:wired_parts/features/catalog/part_detail_page.dart';
import 'package:wired_parts/features/edit_drafts/edit_drafts.dart';
import 'package:wired_parts/features/edit_drafts/edit_draft_widgets.dart';
import 'package:wired_parts/features/jobs/job_line_editor.dart';
import 'package:wired_parts/features/jobs/jobs_repository.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String textOf(WidgetTester tester, String label) =>
    tester.widget<TextField>(field(label)).controller!.text;

class _DelayedPartOpening extends EditDrafts {
  _DelayedPartOpening({
    required super.db,
    required super.pin,
    required super.deviceId,
  });
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<EditOpening<PartEditSession>> openPart(String partId) async {
    entered.complete();
    await release.future;
    return super.openPart(partId);
  }
}

void main() {
  late AppDatabase db;
  late PinService pin;
  late String device;
  late String job;
  late String part;
  late EditDrafts edits;
  late JobsRepository jobs;
  late CatalogRepository catalog;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    device = await db.settingsDao.ensureDeviceId();
    pin = PinService(db.settingsDao);
    catalog = CatalogRepository(db, pin, device);
    jobs = JobsRepository(db, device);
    await db.taxonomyDao.insertCategory(
      id: 'category',
      name: 'Electrical',
      deviceId: device,
    );
    await db.taxonomyDao.insertStyle(
      id: 'style',
      categoryId: 'category',
      name: 'Outlet',
      deviceId: device,
    );
    await db.taxonomyDao.insertType(
      id: 'type',
      styleId: 'style',
      name: 'Duplex',
      deviceId: device,
    );
    await db.taxonomyDao.insertSupplier(
      id: 'supply',
      name: 'Supply',
      deviceId: device,
    );
    part = await catalog.createGeneralPart(
      name: 'Saved outlet',
      categoryId: 'category',
      styleId: 'style',
      typeId: 'type',
    );
    job = await jobs.createJob('Draft form job');
    edits = EditDrafts(db: db, pin: pin, deviceId: device);
  });

  tearDown(() async => db.close());

  Future<void> pumpDatabase(WidgetTester tester) async {
    await tester.pump();
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final waiting =
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
          find
              .text('Saving unfinished edits on this device...')
              .evaluate()
              .isNotEmpty ||
          find.text('Saving changes...').evaluate().isNotEmpty;
      if (!waiting) {
        await tester.pumpAndSettle();
        return;
      }
    }
    final statuses = tester
        .widgetList<EditStatusBanner>(find.byType(EditStatusBanner))
        .map(
          (banner) =>
              '${banner.status.value.phase}/${banner.status.value.latestSequence}/${banner.status.value.durableSequence}/${banner.status.value.error}',
        )
        .toList();
    final visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .toList();
    final savedLines = await tester.runAsync(() => jobs.listLinesForJob(job));
    throw StateError(
      'The form did not finish. Status $statuses. UI $visible. Saved lines $savedLines',
    );
  }

  Future<void> mount(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.runAsync(db.close));
    await tester.pumpWidget(
      AppScope(
        db: db,
        pin: pin,
        deviceId: device,
        edits: edits,
        wipeLocalData: () async {},
        restoreFromBackup: (_, _) async {},
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => page)),
                child: const Text('Open form'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open form'));
    await pumpDatabase(tester);
  }

  Future<void> reopen(WidgetTester tester) async {
    await tester.tap(find.text('Open form'));
    await pumpDatabase(tester);
  }

  testWidgets(
    'Part fields stay unavailable until the real typed opening is acquired',
    (tester) async {
      final delayed = _DelayedPartOpening(db: db, pin: pin, deviceId: device);
      addTearDown(() => tester.runAsync(db.close));
      await tester.pumpWidget(
        AppScope(
          db: db,
          pin: pin,
          deviceId: device,
          edits: delayed,
          wipeLocalData: () async {},
          restoreFromBackup: (_, _) async {},
          child: MaterialApp(home: PartDetailPage(partId: part)),
        ),
      );
      await tester.runAsync(
        () => delayed.entered.future.timeout(const Duration(seconds: 2)),
      );
      await tester.pump();
      expect(field('Name'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      delayed.release.complete();
      await pumpDatabase(tester);
      expect(textOf(tester, 'Name'), 'Saved outlet');
      expect(find.text('No unfinished changes'), findsOneWidget);
    },
  );

  testWidgets(
    'Part Back preserves raw input and Resume is explicit; Discard restores business fields',
    (tester) async {
      await mount(tester, PartDetailPage(partId: part));
      await tester.enterText(field('Name'), '  unfinished outlet  ');
      await tester.enterText(field('Description'), '\nraw description  ');
      await tester.enterText(field('Specifications'), ' raw specs\n');
      await tester.enterText(field('Unit of measure'), '  box  ');
      await tester.pageBack();
      await pumpDatabase(tester);
      expect(
        (await tester.runAsync(() => catalog.getPart(part)))!.name,
        'Saved outlet',
      );
      await reopen(tester);
      expect(find.text('Resume'), findsOneWidget);
      expect(field('Name'), findsNothing);
      await tester.tap(find.text('Resume'));
      await pumpDatabase(tester);
      expect(textOf(tester, 'Name'), '  unfinished outlet  ');
      expect(textOf(tester, 'Description'), '\nraw description  ');
      expect(textOf(tester, 'Specifications'), ' raw specs\n');
      expect(textOf(tester, 'Unit of measure'), '  box  ');
      await tester.tap(find.text('Discard'));
      await pumpDatabase(tester);
      await reopen(tester);
      expect(find.text('Resume'), findsNothing);
      expect(textOf(tester, 'Name'), 'Saved outlet');
      expect(
        (await tester.runAsync(() => catalog.getPart(part)))!.name,
        'Saved outlet',
      );
    },
  );

  testWidgets(
    'Part Save replaces sealed handle so later raw edits recover separately',
    (tester) async {
      await mount(tester, PartDetailPage(partId: part));
      await tester.enterText(field('Name'), 'First saved outlet');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await pumpDatabase(tester);
      expect(
        (await tester.runAsync(() => catalog.getPart(part)))!.name,
        'First saved outlet',
      );
      await tester.enterText(field('Name'), '  second unfinished outlet ');
      await tester.pageBack();
      await pumpDatabase(tester);
      await reopen(tester);
      await tester.tap(find.text('Resume'));
      await pumpDatabase(tester);
      expect(textOf(tester, 'Name'), '  second unfinished outlet ');
      expect(
        (await tester.runAsync(() => catalog.getPart(part)))!.name,
        'First saved outlet',
      );
    },
  );

  testWidgets(
    'Job Back preserves invalid raw quantities and ordered empty splits without business Save',
    (tester) async {
      await mount(tester, JobLineEditor(jobId: job));
      await tester.tap(find.text('Custom'));
      await pumpDatabase(tester);
      await tester.enterText(field('Custom name'), '  raw custom line  ');
      await tester.enterText(field('Requested'), '1..2');
      await tester.enterText(field('Shop'), '2..');
      await tester.enterText(field('Qty'), '3..');
      await tester.tap(find.text('Add split'));
      await pumpDatabase(tester);
      await tester.pageBack();
      await pumpDatabase(tester);
      expect(await tester.runAsync(() => jobs.listLinesForJob(job)), isEmpty);
      await reopen(tester);
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await pumpDatabase(tester);
      expect(textOf(tester, 'Custom name'), '  raw custom line  ');
      expect(textOf(tester, 'Requested'), '1..2');
      expect(textOf(tester, 'Shop'), '2..');
      expect(
        tester
            .widgetList<TextField>(field('Qty'))
            .map((w) => w.controller!.text)
            .toList(),
        ['3..', ''],
      );
      expect(await tester.runAsync(() => jobs.listLinesForJob(job)), isEmpty);
    },
  );

  testWidgets(
    'ordinary Job Save remains available with locked catalog PIN and commits recovered input',
    (tester) async {
      await tester.runAsync(() => pin.setPin('2468'));
      await mount(tester, JobLineEditor(jobId: job));
      await tester.tap(find.text('Custom'));
      await pumpDatabase(tester);
      await tester.enterText(field('Custom name'), '  ordinary job line  ');
      await tester.enterText(field('Requested'), ' 7.5 ');
      await tester.pageBack();
      await pumpDatabase(tester);
      await reopen(tester);
      await tester.tap(find.text('Resume'));
      await pumpDatabase(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await pumpDatabase(tester);
      final saved = (await tester.runAsync(() => jobs.listLinesForJob(job)))!
          .single;
      expect(saved.customName, 'ordinary job line');
      expect(saved.neededQty, 7.5);
      expect(pin.isUnlocked, false);
      await reopen(tester);
      expect(find.text('Resume'), findsNothing);
      expect(textOf(tester, 'Requested'), '1');
    },
  );

  testWidgets(
    'foreign Part draft is inspectable and blocked until explicit Discard',
    (tester) async {
      await tester.runAsync(() async {
        final opening = await edits.openPart(part);
        final session = (opening as FreshEdit<PartEditSession>).session;
        session.replace(
          const PartInput(
            nameText: 'preserved foreign outlet',
            descriptionText: '',
            specsText: '',
            uomText: 'ea',
            categoryId: 'category',
            styleId: 'style',
            typeId: 'type',
            defaultSupplierId: null,
            active: true,
          ),
        );
        await session.leave(LeaveIntent.back);
      });
      edits = EditDrafts(db: db, pin: pin, deviceId: 'foreign-device');
      await mount(tester, PartDetailPage(partId: part));
      expect(find.text('Unfinished edits cannot be resumed.'), findsOneWidget);
      expect(find.text('Resume'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Save'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SelectableText &&
              (w.data?.contains('preserved foreign outlet') ?? false),
        ),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(() => catalog.getPart(part)))!.name,
        'Saved outlet',
      );
      await tester.tap(find.text('Discard unfinished edits'));
      await pumpDatabase(tester);
      expect(textOf(tester, 'Name'), 'Saved outlet');
      expect(find.widgetWithText(TextButton, 'Save'), findsOneWidget);
    },
  );

  testWidgets(
    'cancelled Job Remove retains input; confirmed session Remove settles it',
    (tester) async {
      final line = (await tester.runAsync(
        () => jobs.addLine(
          jobId: job,
          customName: 'Original line',
          neededQty: 4,
          shopPullQty: 0,
        ),
      ))!;
      await mount(tester, JobLineEditor(jobId: job, lineId: line));
      await tester.enterText(field('Custom name'), 'unfinished removal input');
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await pumpDatabase(tester);
      await tester.tap(find.text('Cancel'));
      await pumpDatabase(tester);
      expect(
        (await tester.runAsync(() => jobs.getJobLine(line)))!.customName,
        'Original line',
      );
      expect(textOf(tester, 'Custom name'), 'unfinished removal input');
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await pumpDatabase(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Remove').last);
      await pumpDatabase(tester);
      expect(await tester.runAsync(() => jobs.listLinesForJob(job)), isEmpty);
      await reopen(tester);
      expect(find.text('Resume'), findsNothing);
    },
  );
  testWidgets(
    'failed Job Remove retains business line and recoverable raw input',
    (tester) async {
      final line = (await tester.runAsync(
        () => jobs.addLine(
          jobId: job,
          customName: 'Original line',
          neededQty: 4,
          shopPullQty: 0,
        ),
      ))!;
      await mount(tester, JobLineEditor(jobId: job, lineId: line));
      await tester.runAsync(
        () => db.customStatement(
          "CREATE TRIGGER reject_line_remove BEFORE UPDATE ON job_lines WHEN NEW.deleted_at IS NOT NULL BEGIN SELECT RAISE(ABORT, 'synthetic remove failure'); END",
        ),
      );
      await tester.enterText(
        field('Custom name'),
        '  input after failed remove  ',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await pumpDatabase(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Remove').last);
      await pumpDatabase(tester);
      expect(
        (await tester.runAsync(() => jobs.getJobLine(line)))!.customName,
        'Original line',
      );
      expect(textOf(tester, 'Custom name'), '  input after failed remove  ');
      await tester.pageBack();
      await pumpDatabase(tester);
      await reopen(tester);
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await pumpDatabase(tester);
      expect(textOf(tester, 'Custom name'), '  input after failed remove  ');
    },
  );

  testWidgets(
    'Job promotion supplies a fresh existing-line handle for subsequent edits',
    (tester) async {
      await mount(tester, JobLineEditor(jobId: job));
      await tester.tap(find.text('Custom'));
      await pumpDatabase(tester);
      await tester.enterText(field('Custom name'), 'Promoted outlet');
      await tester.tap(find.text('Promote to catalog'));
      await pumpDatabase(tester);
      for (final entry in [(0, 'Electrical'), (1, 'Outlet'), (2, 'Duplex')]) {
        await tester.tap(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(DropdownButtonFormField<String>),
              )
              .at(entry.$1),
        );
        await pumpDatabase(tester);
        await tester.tap(find.text(entry.$2).last);
        await pumpDatabase(tester);
      }
      await tester.tap(find.text('Promote'));
      await pumpDatabase(tester);
      final promoted = (await tester.runAsync(() => jobs.listLinesForJob(job)))!
          .single;
      expect(
        (await tester.runAsync(() => catalog.getPart(promoted.partId!)))!.name,
        'Promoted outlet',
      );
      await tester.enterText(field('Requested'), ' 9.5 ');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await pumpDatabase(tester);
      final saved = (await tester.runAsync(() => jobs.listLinesForJob(job)))!
          .single;
      expect(saved.id, promoted.id);
      expect(saved.neededQty, 9.5);
    },
  );

  testWidgets(
    'draft status claims durability only for the latest committed sequence',
    (tester) async {
      final status = ValueNotifier(
        const EditStatus(
          EditPhase.durable,
          latestSequence: 3,
          durableSequence: 2,
        ),
      );
      addTearDown(status.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EditStatusBanner(status: status)),
        ),
      );
      expect(find.text('Unfinished edits saved on this device'), findsNothing);
      expect(
        find.text('Saving unfinished edits on this device...'),
        findsOneWidget,
      );
      status.value = const EditStatus(
        EditPhase.durable,
        latestSequence: 3,
        durableSequence: 3,
      );
      await tester.pump();
      expect(
        find.text('Unfinished edits saved on this device'),
        findsOneWidget,
      );
      status.value = const EditStatus(
        EditPhase.storageFailed,
        latestSequence: 4,
        durableSequence: 3,
        error: 'disk full',
      );
      await tester.pump();
      expect(find.text('Unfinished edits saved on this device'), findsNothing);
      expect(
        find.text('Unfinished edits could not be saved. disk full'),
        findsOneWidget,
      );
    },
  );
}
