# Phase 1 Local Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Flutter app on iOS/Android/Windows/Mac with local SQLite that can manage jobs, general parts (+ optional brand versions and supplier listings), job lines with shop pulls and order splits, catalog maintenance, and a shared editor PIN — fully offline, with sync metadata fields ready for later phases.

**Architecture:** Single Flutter package `app/` using Drift (SQLite). Feature folders own UI + repositories; `data/` owns schema/DAOs. Every syncable row carries id, origin device, timestamps, revision, and `deleted_at`. No Bluetooth/Wi‑Fi sync UI in Phase 1 — only schema hooks.

**Tech Stack:** Flutter 3.x, Drift + sqlite3, uuid, crypto (PIN), flutter_test + drift testing

**Spec:** `docs/superpowers/specs/2026-09-11-parts-foundation-design.md`  
**Tracker:** `roadmap.md`

---

## File map (create in Phase 1)

```
app/
  pubspec.yaml
  analysis_options.yaml
  lib/
    main.dart
    app.dart
    core/
      new_id.dart                 # uuid helper
      pin_hasher.dart             # salted PIN hash/verify
    data/
      app_database.dart           # Drift database + DAOs
      tables/
        device_profile.dart
        app_settings.dart
        taxonomy.dart             # categories, styles, types, devices, brands, suppliers
        parts.dart                # parts, brand_versions, supplier_listings, part_devices
        jobs.dart                 # jobs, job_lines, order_splits
      daos/
        settings_dao.dart
        taxonomy_dao.dart
        parts_dao.dart
        jobs_dao.dart
    features/
      shell/
        home_shell.dart           # bottom nav: Jobs | Catalog | More
      jobs/
        jobs_page.dart
        job_detail_page.dart
        job_line_editor.dart
        jobs_repository.dart
      catalog/
        catalog_page.dart
        part_detail_page.dart
        catalog_repository.dart
      maintenance/
        maintenance_page.dart
        maintenance_repository.dart
      pin/
        pin_gate.dart
        pin_service.dart
  test/
    core/pin_hasher_test.dart
    data/jobs_dao_test.dart
    data/parts_dao_test.dart
    data/order_splits_test.dart
    features/pin/pin_service_test.dart
```

---

### Task 1: Scaffold Flutter project

**Files:**
- Create: `app/` (flutter create)
- Create: `app/pubspec.yaml` dependencies
- Modify: root `README.md`
- Modify: `roadmap.md` (check scaffold when done)

- [ ] **Step 1: Create the Flutter project**

```bash
cd c:/Users/weird/.GitHub/Weird-Parts-3rd-run
flutter create --org com.wiredpart --project-name wired_parts --platforms=android,ios,windows,macos app
```

Expected: `app/` created with platform folders.

- [ ] **Step 2: Add dependencies to `app/pubspec.yaml`**

Under `dependencies:`:

```yaml
  drift: ^2.22.1
  drift_flutter: ^0.2.4
  sqlite3_flutter_libs: ^0.5.28
  path_provider: ^2.1.5
  path: ^1.9.1
  uuid: ^4.5.1
  crypto: ^3.0.6
  collection: ^1.19.0
```

Under `dev_dependencies:`:

```yaml
  drift_dev: ^2.22.1
  build_runner: ^2.4.14
```

- [ ] **Step 3: Install packages**

```bash
cd app
flutter pub get
```

Expected: exit 0.

- [ ] **Step 4: Replace `app/README.md` stub note and update root README**

Root `README.md`:

```markdown
# Weird Parts / WiredPart (foundation)

Local-first parts + jobs app. See `roadmap.md` and `docs/superpowers/specs/2026-09-11-parts-foundation-design.md`.

## Run

```bash
cd app
flutter run -d windows
```
```

- [ ] **Step 5: Commit**

```bash
git add app README.md
git commit -m "chore: scaffold Flutter multi-platform app"
```

---

### Task 2: Core helpers — ids and PIN hasher (TDD)

**Files:**
- Create: `app/lib/core/new_id.dart`
- Create: `app/lib/core/pin_hasher.dart`
- Test: `app/test/core/pin_hasher_test.dart`

- [ ] **Step 1: Write failing PIN hasher tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/pin_hasher.dart';

void main() {
  test('same PIN verifies against its hash', () {
    final stored = PinHasher.hashPin('2468');
    expect(PinHasher.verify('2468', stored), isTrue);
  });

  test('wrong PIN fails verification', () {
    final stored = PinHasher.hashPin('2468');
    expect(PinHasher.verify('0000', stored), isFalse);
  });

  test('hash is not the raw PIN', () {
    final stored = PinHasher.hashPin('2468');
    expect(stored.contains('2468'), isFalse);
  });
}
```

- [ ] **Step 2: Run test — expect fail**

```bash
cd app
flutter test test/core/pin_hasher_test.dart
```

Expected: FAIL (library/file missing).

- [ ] **Step 3: Implement helpers**

`app/lib/core/new_id.dart`:

```dart
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newId() => _uuid.v4();
```

`app/lib/core/pin_hasher.dart`:

```dart
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

class PinHasher {
  /// Returns `saltHex:hashHex` (SHA-256 of salt+pin).
  static String hashPin(String pin, {String? saltHex}) {
    final salt = saltHex ?? _randomSalt();
    final digest = sha256.convert(utf8.encode('$salt:$pin'));
    return '$salt:${digest.toString()}';
  }

  static bool verify(String pin, String stored) {
    final parts = stored.split(':');
    if (parts.length != 2) return false;
    final again = hashPin(pin, saltHex: parts[0]);
    return again == stored;
  }

  static String _randomSalt() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd app
flutter test test/core/pin_hasher_test.dart
```

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/core app/test/core
git commit -m "feat: add id helper and salted PIN hasher"
```

---

### Task 3: Drift database shell + device profile + settings

**Files:**
- Create: `app/lib/data/tables/device_profile.dart`
- Create: `app/lib/data/tables/app_settings.dart`
- Create: `app/lib/data/app_database.dart`
- Create: `app/lib/data/daos/settings_dao.dart`
- Test: `app/test/features/pin/pin_service_test.dart` (after Task 4 uses DB — for this task test ensureDevice)

- [ ] **Step 1: Define tables**

`app/lib/data/tables/device_profile.dart`:

```dart
import 'package:drift/drift.dart';

class DeviceProfiles extends Table {
  TextColumn get id => text()(); // device_id
  TextColumn get displayName => text().withDefault(const Constant('This device'))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
```

Settings keys (convention):
- `editor_pin_hash` — salted hash string
- `default_company_name` — optional later

- [ ] **Step 2: Create `AppDatabase` stub**

`app/lib/data/app_database.dart`:

```dart
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tables/device_profile.dart';
import 'tables/app_settings.dart';
import 'daos/settings_dao.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [DeviceProfiles, AppSettings],
  daos: [SettingsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'wired_parts.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
```

`app/lib/data/daos/settings_dao.dart`:

```dart
import 'package:drift/drift.dart';

import '../app_database.dart';
import '../../core/new_id.dart';

part 'settings_dao.g.dart';

@DriftAccessor(tables: [DeviceProfiles, AppSettings])
class SettingsDao extends DatabaseAccessor<AppDatabase> with _$SettingsDaoMixin {
  SettingsDao(super.db);

  Future<String> ensureDeviceId() async {
    final existing = await select(deviceProfiles).getSingleOrNull();
    if (existing != null) return existing.id;
    final id = newId();
    await into(deviceProfiles).insert(
      DeviceProfilesCompanion.insert(
        id: id,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    return id;
  }

  Future<void> setSetting(String key, String value) async {
    await into(appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: key, value: value),
    );
  }

  Future<String?> getSetting(String key) async {
    final row = await (select(appSettings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }
}
```

- [ ] **Step 3: Generate Drift code**

```bash
cd app
dart run build_runner build --delete-conflicting-outputs
```

Expected: `app_database.g.dart` and `settings_dao.g.dart` created.

- [ ] **Step 4: Write device-id test**

`app/test/data/settings_dao_test.dart`:

```dart
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
```

- [ ] **Step 5: Run test**

```bash
cd app
flutter test test/data/settings_dao_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/data app/test/data
git commit -m "feat: add Drift DB with device profile and settings"
```

---

### Task 4: PIN service

**Files:**
- Create: `app/lib/features/pin/pin_service.dart`
- Create: `app/lib/features/pin/pin_gate.dart`
- Test: `app/test/features/pin/pin_service_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/features/pin/pin_service.dart';

void main() {
  late AppDatabase db;
  late PinService pin;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    pin = PinService(db.settingsDao);
  });

  tearDown(() async => db.close());

  test('no PIN set means catalog unlocked until set', () async {
    expect(await pin.isPinSet(), isFalse);
  });

  test('set and unlock with correct PIN', () async {
    await pin.setPin('1357');
    expect(await pin.isPinSet(), isTrue);
    expect(await pin.unlock('1357'), isTrue);
    expect(pin.isUnlocked, isTrue);
  });

  test('wrong PIN does not unlock', () async {
    await pin.setPin('1357');
    expect(await pin.unlock('0000'), isFalse);
    expect(pin.isUnlocked, isFalse);
  });
}
```

- [ ] **Step 2: Run — expect fail**

```bash
cd app
flutter test test/features/pin/pin_service_test.dart
```

- [ ] **Step 3: Implement `PinService`**

```dart
import '../../core/pin_hasher.dart';
import '../../data/daos/settings_dao.dart';

class PinService {
  PinService(this._settings);

  final SettingsDao _settings;
  static const _key = 'editor_pin_hash';

  bool _unlocked = false;
  bool get isUnlocked => _unlocked;

  Future<bool> isPinSet() async => (await _settings.getSetting(_key)) != null;

  Future<void> setPin(String pin) async {
    await _settings.setSetting(_key, PinHasher.hashPin(pin));
    _unlocked = false;
  }

  Future<bool> unlock(String pin) async {
    final stored = await _settings.getSetting(_key);
    if (stored == null) {
      _unlocked = true;
      return true;
    }
    final ok = PinHasher.verify(pin, stored);
    _unlocked = ok;
    return ok;
  }

  void lock() => _unlocked = false;

  /// Call before any catalog write.
  Future<void> requireUnlocked() async {
    if (!await isPinSet()) return;
    if (!_unlocked) {
      throw StateError('Catalog editor PIN required');
    }
  }
}
```

`pin_gate.dart` — simple dialog used by UI later:

```dart
import 'package:flutter/material.dart';

import 'pin_service.dart';

Future<bool> showPinGate(BuildContext context, PinService pin) async {
  final controller = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Editor PIN'),
      content: TextField(
        controller: controller,
        obscureText: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'PIN'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final unlocked = await pin.unlock(controller.text);
            if (ctx.mounted) Navigator.pop(ctx, unlocked);
          },
          child: const Text('Unlock'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
```

- [ ] **Step 4: Run tests — PASS**

```bash
cd app
flutter test test/features/pin/pin_service_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/pin app/test/features/pin
git commit -m "feat: add catalog editor PIN service and gate"
```

---

### Task 5: Taxonomy + parts schema and DAO

**Files:**
- Create: `app/lib/data/tables/taxonomy.dart`
- Create: `app/lib/data/tables/parts.dart`
- Create: `app/lib/data/daos/taxonomy_dao.dart`
- Create: `app/lib/data/daos/parts_dao.dart`
- Modify: `app/lib/data/app_database.dart` (register tables/DAOs)
- Test: `app/test/data/parts_dao_test.dart`

Shared sync columns pattern on parts tables (inline on each table):

- `id` text PK  
- `originDeviceId` text  
- `createdAt` / `modifiedAt` dateTime  
- `revision` int  
- `deletedAt` dateTime nullable  

- [ ] **Step 1: Write failing parts DAO test (general part + brand + listing)**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';
import 'package:wired_parts/data/daos/parts_dao.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  test('create general part with default supplier and optional brand listing', () async {
    final deviceId = await db.settingsDao.ensureDeviceId();
    final supplierId = await db.taxonomyDao.insertSupplier(
      id: newId(),
      name: 'SupplyHouse',
      deviceId: deviceId,
    );
    final brandId = await db.taxonomyDao.insertBrand(
      id: newId(),
      name: 'Watts',
      deviceId: deviceId,
    );
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: '3/4 isolation valve',
      defaultSupplierId: supplierId,
      deviceId: deviceId,
    );
    final bvId = await db.partsDao.insertBrandVersion(
      id: newId(),
      partId: partId,
      brandId: brandId,
      mpn: 'W-123',
      deviceId: deviceId,
    );
    await db.partsDao.insertSupplierListing(
      id: newId(),
      brandVersionId: bvId,
      supplierId: supplierId,
      sku: 'SH-9',
      deviceId: deviceId,
    );

    final part = await db.partsDao.getPart(partId);
    expect(part!.name, '3/4 isolation valve');
    expect(part.defaultSupplierId, supplierId);
    final listings = await db.partsDao.listingsForBrandVersion(bvId);
    expect(listings, hasLength(1));
  });
}
```

- [ ] **Step 2: Run — expect fail / compile errors**

- [ ] **Step 3: Implement taxonomy + parts tables and DAOs**

Implement tables:

**Taxonomy:** `Categories`, `Styles` (categoryId), `Types` (styleId), `Devices`, `Brands`, `Suppliers` — each with sync columns + `name` text + soft delete.

**Parts:**  
- `Parts`: name, description, categoryId?, styleId?, typeId?, uom, specs, keywords, photoPath?, active (bool), defaultSupplierId?, + sync columns  
- `PartDevices`: partId, deviceId (compatible device taxonomy id)  
- `BrandVersions`: partId, brandId, mpn, model, description, + sync columns  
- `SupplierListings`: brandVersionId, supplierId, sku, description, packageQty, lastPrice?, notes?, + sync columns  

DAO methods used by the test: `insertSupplier`, `insertBrand`, `insertGeneralPart`, `insertBrandVersion`, `insertSupplierListing`, `getPart`, `listingsForBrandVersion`.

Wire them into `@DriftDatabase` and re-run:

```bash
cd app
dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 4: Catalog writes must call `PinService.requireUnlocked` from repository layer (Task 7)** — DAO stays pure data.

- [ ] **Step 5: Run parts test — PASS**

```bash
cd app
flutter test test/data/parts_dao_test.dart
```

- [ ] **Step 6: Commit**

```bash
git add app/lib/data app/test/data
git commit -m "feat: add taxonomy and parts catalog schema"
```

---

### Task 6: Jobs, job lines, order splits (TDD)

**Files:**
- Create: `app/lib/data/tables/jobs.dart`
- Create: `app/lib/data/daos/jobs_dao.dart`
- Modify: `app/lib/data/app_database.dart`
- Test: `app/test/data/jobs_dao_test.dart`
- Test: `app/test/data/order_splits_test.dart`

- [ ] **Step 1: Write order-splits test**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wired_parts/core/new_id.dart';
import 'package:wired_parts/data/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  test('job line tracks needed, shop pull, and split orders', () async {
    final deviceId = await db.settingsDao.ensureDeviceId();
    final s1 = await db.taxonomyDao.insertSupplier(id: newId(), name: 'A', deviceId: deviceId);
    final s2 = await db.taxonomyDao.insertSupplier(id: newId(), name: 'B', deviceId: deviceId);
    final partId = await db.partsDao.insertGeneralPart(
      id: newId(),
      name: 'Valve',
      defaultSupplierId: s1,
      deviceId: deviceId,
    );
    final jobId = await db.jobsDao.insertJob(
      id: newId(),
      name: 'Boiler swap',
      deviceId: deviceId,
    );
    final lineId = await db.jobsDao.insertJobLine(
      id: newId(),
      jobId: jobId,
      partId: partId,
      brandVersionId: null,
      neededQty: 10,
      shopPullQty: 4,
      deviceId: deviceId,
    );
    await db.jobsDao.insertOrderSplit(id: newId(), jobLineId: lineId, supplierId: s1, qty: 3, deviceId: deviceId);
    await db.jobsDao.insertOrderSplit(id: newId(), jobLineId: lineId, supplierId: s2, qty: 3, deviceId: deviceId);

    final line = await db.jobsDao.getJobLine(lineId);
    expect(line!.neededQty, 10);
    expect(line.shopPullQty, 4);
    final splits = await db.jobsDao.orderSplitsForLine(lineId);
    expect(splits, hasLength(2));
    expect(splits.map((s) => s.quantity).fold<double>(0, (a, b) => a + b), 6);
  });
}
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Implement jobs tables**

- `Jobs`: name, customer?, location?, jobNumber?, status (text: active|completed|archived), notes?, + sync columns  
- `JobLines`: jobId, partId?, customName?, customNotes?, brandVersionId?, neededQty (real), shopPullQty (real), uom?, notes?, + sync columns  
- `OrderSplits`: jobLineId, supplierId, quantity (real), + sync columns  

Implement DAO methods matching the test. Custom parts: `partId` null + `customName` set.

- [ ] **Step 4: build_runner + tests PASS**

```bash
cd app
dart run build_runner build --delete-conflicting-outputs
flutter test test/data/order_splits_test.dart test/data/jobs_dao_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add app/lib/data app/test/data
git commit -m "feat: add jobs, job lines, and order splits"
```

---

### Task 7: Repositories + wire app shell

**Files:**
- Create: `app/lib/features/jobs/jobs_repository.dart`
- Create: `app/lib/features/catalog/catalog_repository.dart`
- Create: `app/lib/features/maintenance/maintenance_repository.dart`
- Create: `app/lib/app.dart`
- Modify: `app/lib/main.dart`
- Create: `app/lib/features/shell/home_shell.dart`

- [ ] **Step 1: Implement repositories**

`JobsRepository` — create/list/archive jobs; add/update lines; set shop pull; replace order splits for a line. No PIN required.

`CatalogRepository` / `MaintenanceRepository` — all mutating methods start with `await pin.requireUnlocked();` then DAO calls. Reads do not require PIN.

- [ ] **Step 2: `main.dart` opens DB, ensures device id, provides via `InheritedWidget` or simple `AppScope`**

```dart
class AppScope extends InheritedWidget {
  const AppScope({
    required this.db,
    required this.pin,
    required this.deviceId,
    required super.child,
    super.key,
  });

  final AppDatabase db;
  final PinService pin;
  final String deviceId;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) =>
      db != old.db || pin != old.pin || deviceId != old.deviceId;
}
```

- [ ] **Step 3: `HomeShell` with 3 destinations: Jobs, Catalog, More (maintenance + set PIN)**

- [ ] **Step 4: Manual smoke**

```bash
cd app
flutter run -d windows
```

Expected: app launches to shell with empty Jobs list.

- [ ] **Step 5: Commit**

```bash
git add app/lib
git commit -m "feat: wire repositories and app shell"
```

---

### Task 8: Jobs UI

**Files:**
- Create: `app/lib/features/jobs/jobs_page.dart`
- Create: `app/lib/features/jobs/job_detail_page.dart`
- Create: `app/lib/features/jobs/job_line_editor.dart`

- [ ] **Step 1: Jobs list — search field, FAB create job (name required), tap → detail, archive action**

- [ ] **Step 2: Job detail — list lines showing needed / pulled / ordered(sum of splits)**

- [ ] **Step 3: Line editor — pick catalog part or enter custom name; optional brand version dropdown; needed qty; shop pull qty; dynamic list of order splits (supplier dropdown + qty); save**

Supplier dropdown rules:

- If brand version selected → suppliers from that version’s listings  
- Else → at least the part’s default supplier (and all suppliers as fallback list for Phase 1)

- [ ] **Step 4: Manual verify on Windows (or chrome if needed)**

Create job → add line need 10, pull 4, split 3+3 across two suppliers → list shows those numbers.

- [ ] **Step 5: Commit**

```bash
git add app/lib/features/jobs
git commit -m "feat: add jobs and job parts list UI"
```

---

### Task 9: Catalog + maintenance UI with PIN gate

**Files:**
- Create: `app/lib/features/catalog/catalog_page.dart`
- Create: `app/lib/features/catalog/part_detail_page.dart`
- Create: `app/lib/features/maintenance/maintenance_page.dart`
- Modify: `app/lib/features/shell/home_shell.dart`

- [ ] **Step 1: Catalog page — search box, list general parts, FAB add (calls `showPinGate` if locked)**

- [ ] **Step 2: Part detail — edit general fields; manage brand versions; manage supplier listings per brand version; set default supplier; attempt save without unlock shows PIN dialog**

- [ ] **Step 3: Maintenance page — simple CRUD lists for categories, styles, types, devices, brands, suppliers (each write PIN-gated)**

- [ ] **Step 4: More tab — Set/Change PIN, open Maintenance, Lock catalog button (`pin.lock()`)**

- [ ] **Step 5: Manual verify**

Without PIN set: allow first-time set PIN from More. With PIN set and locked: catalog FAB prompts PIN. Jobs still editable while locked.

- [ ] **Step 6: Run full unit tests**

```bash
cd app
flutter test
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add app/lib/features app/test
git commit -m "feat: add catalog and maintenance UI with PIN gate"
```

---

### Task 10: Phase 1 wrap-up

**Files:**
- Modify: `roadmap.md`
- Modify: `docs/superpowers/specs/2026-09-11-parts-foundation-design.md` status if needed

- [ ] **Step 1: Check off Phase 1 items on `roadmap.md` that are done; leave photos/search/sync unchecked**

- [ ] **Step 2: Add short “Phase 1 done” note under Where we are; set current focus to Phase 2**

- [ ] **Step 3: Commit**

```bash
git add roadmap.md
git commit -m "docs: mark Phase 1 local core complete on roadmap"
```

---

## Self-review (plan vs spec)

| Spec foundation item | Task |
|---|---|
| Flutter 4 platforms | Task 1 |
| SQLite + device id | Task 3 |
| Editor PIN | Tasks 2, 4, 9 |
| General part, no MPN; default supplier | Task 5 |
| Brand versions + supplier listings | Task 5 |
| Editable taxonomy | Tasks 5, 9 |
| Jobs + lines + custom parts | Tasks 6, 8 |
| Needed / shop pull / order splits | Tasks 6, 8 |
| Sync metadata columns | Tasks 5–6 |
| Catalog + maintenance screens | Task 9 |
| Photos, backup, BT/Wi‑Fi sync | Out of Phase 1 (Phases 2–5) |

No intentional Phase 1 coverage of warehouse ledger, Hats, MCP, auto sync, or preferred brand.

---

## Out of scope for this plan

- Search/filter polish and photos (Phase 2)  
- Encrypted backup (Phase 3)  
- Nearby sync transports (Phases 4–5)  
- Auto/background sync (Phase 7)  
