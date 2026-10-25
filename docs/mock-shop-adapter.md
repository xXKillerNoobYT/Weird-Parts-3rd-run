# Run the Ponderosa mock shop

Use the frozen inputs in `app/test/fixtures/mock_shop`. The adapter creates its own disposable SQLite files. It never opens the daily-use application database.

The repository stores the catalog as deterministic `source-catalog.json.gz` to preserve its exact original bytes. The loader also accepts the original package's `source-catalog.json`. It refuses a directory containing both forms and checks the original decompressed hash before import.

Run from `app` with the existing resolved dependencies.

```sh
flutter test --no-pub test/tool/mock_shop_adapter_test.dart \
  test/tool/mock_shop_sync_test.dart \
  test/tool/mock_shop_widgets_test.dart --concurrency=1
```

Run the frozen scenario registry separately.

```sh
flutter test --no-pub test/tool/mock_shop_scenarios_test.dart --concurrency=1
```

To save an immutable scenario receipt, set `MOCK_SHOP_SCENARIO_RECEIPT` to a new output filename. Set `MOCK_SHOP_SOURCE_REVISION` to the exact tested commit. An existing output or interrupted output stage refuses replacement.

The receipt records one result for each of the 28 source scenarios and each automation proposal. A passing supported assertion cannot promote an incomplete scenario to PASS. Missing purchasing, receiving, reservation, material-line sync, workflow, and automation implementations remain BLOCKED.

## Inspect the local app

Coordinate the native build and screen lane with the current Mac or Windows owner before launching a new native test process. Preserve the retained acceptance applications and their identities. The entrypoint below is separate from the production entrypoint.

Use a separately qualified test build with these compile-time values.

```sh
flutter run --no-pub -d macos -t tool/mock_shop_app.dart \
  --dart-define=MOCK_SHOP_TEST_APP=true \
  --dart-define=MOCK_SHOP_FIXTURE_DIRECTORY="$PWD/test/fixtures/mock_shop"
```

The test entrypoint refuses a missing opt-in or relative fixture path before opening a database. It creates a fresh owned directory and prints its public database path and import counts. Application support, documents, photos, backup, reset, and replacement database paths remain inside that directory.

Open Jobs to inspect five active Jobs. The other two source Jobs are archived. All seven are persisted. Their original workflow stages, schedules, crew, and history remain in notes. The source's seven business stages do not become new native workflow states.

Open Catalog to inspect 59 sellable variants and 66 supplier listings. Retailer SKU, online listing ID, model, pack conversion, and source observations remain distinct. Missing prices remain null. A ten-pack stores package quantity ten, and a wire roll stores package quantity 500 with the Part unit in feet.

Open Warehouse to inspect 11 locations and absolute on-hand observations. Reservations and available stock remain reference metadata. The adapter does not replay the 106 source movements into those observations.

The editor starts unlocked under an ephemeral synthetic test PIN. The PIN is neither printed nor embedded in source. Automated tests can lock and unlock their own workspace. A manual inspection run does not provision the source's eight staff identities or roles.

## Preserve a local native profile

The default entrypoint creates a new temporary shop each launch. For process-cold readback, launch the same separately qualified mock binary with both public environment values set:

```sh
MOCK_SHOP_PROFILE_MODE=create MOCK_SHOP_PROFILE_ID=ponderosa-local-a \
  /path/to/qualified-mock.app/Contents/MacOS/wired_parts
```

Use `create` only once. It refuses an existing profile. The identifier selects an owned directory under the native process's resolved temporary directory; it cannot select an arbitrary database path. Package the frozen fixture inside the qualified app bundle before signing and compile its absolute resource path into `MOCK_SHOP_FIXTURE_DIRECTORY`. Verify the bundle identity, signature, embedded hashes and actual runtime before crediting native acceptance. The default Runner bundle identity is not a qualified isolated build.

While the first run is unlocked, use More > Change PIN to choose an operator-known synthetic PIN through the existing UI. Keep that PIN ephemeral. Make the deliberate synthetic edit, save public record exports, attach the normal-exit observer, and quit through the app. Relaunch the same binary with `MOCK_SHOP_PROFILE_MODE=resume` and the same `MOCK_SHOP_PROFILE_ID`. Resume refuses a missing or incomplete profile rather than importing a replacement. The existing PIN service starts locked; use the normal PIN gate to unlock it.

Resume checks ownership, path redirects, fixture binding, schema, device ID, PIN state, company markers and relationships through read-only SQLite before opening a writable connection. It holds an exclusive profile claim for the app lifetime. No PIN, verifier or protected-store state goes into the public profile binding or startup receipt. It does not call the importer, replace the PIN, repair the device ID or migrate a refused target.

Named profiles must close and use explicit resume. The temporary workspace's same-process `reopen()` helper refuses named profiles.

Compare the same seven Job IDs, device ID, catalog/material relationships and deliberate edit after relaunch. A same-process database reopen or backup restore into a fresh shop does not establish this result. Preserve the native profile and receipts for review; they are not automatically synchronized to another host.

## Run the company Job profile

`mock_shop_sync_test.dart` creates two different file-backed app databases and synthetic protected stores. It creates exactly seven Jobs through production company commands, enrolls the second installation through normal Pair and Match, and runs production company sync over real loopback TCP.

The suite checks initial exchange, independent offline Job-detail edits, duplicate-safe repeats, and persisted readback after closing and reopening the databases. This is same-host controller and SQLite evidence. It does not establish physical Windows/Mac acceptance, native secure-store behavior, or an application process cold restart.

Company enrollment deliberately disables the local catalog, material-line, and warehouse paths. Keep the local and company profiles separate. The adapter never seeds legacy rows around that guard.

For current ownership, delivery status, exact evidence, and the queued physical native lane, use [issue #176](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/176). The [standing synthetic-test authorization](agent-test-authorization.md) covers routine isolated testing while preserving the native owners and platform controls.
