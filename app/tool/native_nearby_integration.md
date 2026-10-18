# Native Nearby bootstrap probe

Governing issue [#49](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/49).
This first experiment checks Flutter integration testing inside an actual native
Windows or macOS application. It does not clear the lifecycle gate in #39.

The entrypoint is `integration_test/nearby_bootstrap_probe_test.dart`. Before
initializing Flutter or opening a database, it requires Windows or macOS,
`NATIVE_NEARBY_TEST_MODE=true`, a `LAN_VALIDATION_RUN` beginning with
`nearby-integration-probe-`, and `LAN_VALIDATION_ROLE=sender` or `receiver`.
Run names contain at most 48 lowercase letters, digits or hyphens. The suffix
must be nonempty. Use a fresh run suffix for this experiment. Never supply the
existing lifecycle run or its initialized fixture.

After those guards, the existing synthetic validation entrypoint isolates all
path-provider directories, claims its workspace lock and seeds only an
uninitialized probe fixture. It preserves an already initialized probe root.
Its ownership, interrupted-initialization and symlink refusals still apply.

WidgetTester verifies the synthetic Jobs screen, taps More and verifies its
Nearby control. It does not open Nearby. The probe calls the real
`wired_parts/nearby_wifi` platform channel through `readNearbyWifiNetwork`.
It supplies no transport or channel mocks and starts no Nearby listener,
discovery, Pair or transfer. Its bounded `reportData` contains platform/run/role
and boolean outcomes. It contains no network addresses, pairing codes or PINs.

The intended desktop test command, after review and isolated native installation
planning, is run from `app` with the correct host device selection.

```text
flutter test integration_test/nearby_bootstrap_probe_test.dart -d windows --dart-define=NATIVE_NEARBY_TEST_MODE=true --dart-define=LAN_VALIDATION_RUN=nearby-integration-probe-20261008a --dart-define=LAN_VALIDATION_ROLE=receiver
```

For macOS select `-d macos` and `LAN_VALIDATION_ROLE=sender`. The native owner
must first verify that the runner uses a separate probe application location
and the intended sandbox identity. Do not overwrite or stop either retained
lifecycle installation. A successful probe proves bootstrap, Flutter widget
interaction and native Wi-Fi enumeration on that host. It proves no LAN
reachability, Pair/Match/PIN flow, shop replacement, restart or two-way sync.

# Resident lifecycle acceptance

The second entrypoint is `integration_test/nearby_resident_test.dart`.
It admits only Windows receiver or macOS sender, the explicit test flag, and
the existing `nearby-lifecycle-20261007a` run. The separate
`nearby-resident-probe-20261009a` run is admitted only if its fixture was already
initialized. This entrypoint never seeds a database. It holds the fixture lock
and opens SQLite read-only to verify declared schema 2, 3 or 4, required
table/column names, integrity and the exact local device profile before
production startup. Schemas 3 and 4 require all seven company-history tables to be
empty. Snapshot proofs keep their exact schema/count pairs, `(2, 13)` or
`(3, 20)` or `(4, 20)`. Earlier proofs never establish acceptance of a newer schema.

`tool/native_nearby_test_host.dart` starts the stock Flutter native test runner.
Its only argument is `--run=<one of those runs>`. It privately discovers the
authenticated localhost VM service and one actual isolate. It accepts only
`info`, configure-once public session data, and typed finite `command` requests
over bounded JSON lines on standard input. It exposes no runtime evaluation,
arbitrary RPC method, path, executable or VM-service URL argument. Raw runner
output and exceptions are discarded rather than included in public receipts.
The fixed runner arguments include --no-dds, so the host does not compete with
a DDS proxy for the first direct VM-service endpoint. Localhost authentication
remains enabled. Discovery skips worker isolates with no registered extensions
and isolates reported collected, while rejecting ambiguous matches and malformed
identities. Failure diagnostics contain only fixed reason/method values and a
byte count when known. VM discovery replies for getVM and getIsolate have a
separate fixed 1 MiB limit because Flutter metadata can exceed 64 KiB. Other
RPC replies and stdin retain the 64 KiB limit. Both paths reject oversized
strings before UTF8 allocation. The connected receipt reports the largest
accepted discovery response in bytes. Isolate and startup bounds are unchanged.
These changes do not establish the cause of the original native disconnection.

The coordinator must independently acquire the native PID, start time, exact
image/kernel/source hashes, run, role, device IDs and host/isolate connection.
It validates two distinct reciprocal sources before sending public session
configuration. `tool/native_nearby_test_coordinator.dart` retains its private
encryption and signing keys only in memory. It decrypts both freshly observed
rendered codes internally and issues short-lived signed Match grants only if
they match. Neither codes nor PIN-derived digests are printed. Match rechecks
the current attempt, code and deadline after asynchronous work and immediately
before the rendered button receives pointer-up.

The resident test uses actual More, Nearby, Pair, Match, Editor PIN, Send and
Accept controls. It keeps the same Nearby page state throughout three whole-shop
copies, Mac to Windows, Windows to Mac, then Mac to Windows. The real UI offers
fresh Pair/Match from the receiving device after each receipt. Receive success
clears the visible pairedPeer, while send success retains it. Mac initiates the
first pairing, Windows the second, and Mac the third. After each of the first
two receipts, a fixed synthetic job-note marker proves the next send reads the
replacement database. Those markers are test-only database mutations. They do
not prove offline UI edits or genuine two-way merge.

Commands have monotonically increasing sequence numbers, absolute local
deadlines and bounded cached outcomes. Identical retries return the same result;
changed or evicted old requests cannot execute again. An expired running action
remains UNKNOWN and busy until its original future settles. Snapshot responses
include schema, row/reference checks, hashes excluding PIN settings and a sealed
private proof for full settings/PIN equality. Device profiles and fixture
ownership must remain local. The app reacquires its current database after each
replacement.

`finish` writes a witness and keeps the app resident. `normalExit` requests the
public Flutter platform-channel cancelable application-exit API with exitCode 0.
The ServicesBinding convenience method is intentionally avoided because the
integration test binding overrides it to cancel without native communication.
A native channel reply alone is not proof of cancellation or exit, including
Windows' immediate response before its asynchronous exit callback. A witness or disconnected test
runner does not prove exit. Independently verify PID disappearance, collect cold
SQLite/assets/settings evidence, restart the same isolated installation and
read it back. A stock test-runner cleanup is not normal-quit evidence.

`launcherExit` includes elapsed milliseconds since stock-runner launch and fixed
booleans for observed SDK timeout, out-of-band failure, cleanup, and sanitized
`NativeTestFailure` markers. Raw stdout/stderr are discarded; each diagnostic
line buffer is limited to 4096 characters. `launcherOutputComplete` is false if
the streams fail or do not finish within two seconds after launcher exit.
These flags report text markers, not a verified termination cause or OS crash.
Missing markers do not establish success, and OS crash evidence remains a
separate native-owner check.

A rejected configuration also writes one fixed-prefix diagnostic containing
only its known rejection reason, owner-loop/pump counters, `pumpPending`, and
the age of the last published public snapshot (null before publication).
The host validates the exact schema from each bounded line, emits at most eight
`diagnostic` records immediately, and retains the last accepted record in
`launcherExit.configureDiagnostic`. Operator readers must accept these records
between normal replies. Counters cover the resident owner-loop pump, not nested
command pumps; completions count settled awaits, including errors, and do not
prove a successful frame. A live info clock does not prove loop progress.
Diagnostic sink failures do not affect configuration outcomes. The v1 RPC
schemas, one-attempt latch and three-second configure expiry remain unchanged.
Unit parsing tests do not prove delivery through the native app and stock runner;
that stream path requires a new native observation.

The native owner must preserve original bundles and fixture contents, bind the
actual test process, and verify narrowly scoped network rules for its exact
executable. Flutter's desktop integration runner builds and launches the
candidate's `app/build` executable. On Windows this requires an additional
exact-program Private/LocalSubnet/Wi-Fi rule, rather than overwriting the retained
original bundle. Preserve existing rules, adapter state and network defaults.
No Wi-Fi disconnect, driver reset or legal-term acceptance is part of this test.

Source/unit review and a successful native bootstrap do not clear #39. The three
physical transfers, both normal quits, cold/readback checks and recipient-owned
evidence at the exact reviewed commit remain separate acceptance gates. Company
membership, changes-only two-way sync and mobile acceptance are outside this
test harness and remain unfinished under #33.

# Existing-installation restart acceptance

`integration_test/nearby_restart_test.dart` is the finite restart target for
issues #33 and #49. It admits only the existing `nearby-lifecycle-20261007a`
installation, Windows receiver or macOS sender, and explicit native test mode.
It never seeds, repairs, migrates, restores, opens Nearby, or writes a fixture
receipt. Missing auxiliary directories, a pending restore marker, an ownership
mismatch, or a database outside the frozen schema are rejection conditions.

The coordinator must first complete all three physical replacement legs and
independently prove both native apps quit normally and their PIDs disappeared.
Preserve cold evidence before building or launching this target. Keep the same
isolated native app location, identity and fixture root. Bind the exact source,
tree, image/kernel and owner evidence externally. This target does not replace
those admission checks or authorize rebuilding either owner's app.

Supply `NATIVE_NEARBY_TEST_MODE=true`, the exact `LAN_VALIDATION_RUN` and
`LAN_VALIDATION_ROLE`, `NATIVE_NEARBY_SOURCE_REVISION`,
`NATIVE_NEARBY_SOURCE_TREE`, and `NATIVE_NEARBY_RESTART_EXPECTATION` as Dart
defines. The last value is an absolute canonical path to a controlled private
JSON file, at most 8192 bytes. Do not put the file or its contents in Git or
public logs. Its exact envelope keys are `format` (1), `run`, `role`,
`sourceRevision`, `sourceTree`, `stage` (`postLeg3`), `ownerDigest` and `proof`.
`proof` uses the existing `PrivateSnapshotProof.fromJson` schema. Supply each
role's authenticated final post-leg3 proof, including full settings and PIN,
and the unchanged local ownership digest. Baselines and post-leg1 proofs are
not valid restart expectations. The source fields bind the restart build;
retain the transfer build's separate source binding in coordinator evidence.

The actual native app runs production startup and compares its live AppScope
database, full rows and relations including tombstones, assets, local profile,
settings and PIN against that private proof. It renders the received Jobs and
part screens, decodes the managed photo, unlocks through the existing Editor
PIN dialog using the synthetic fixture PIN, cancels New part, locks the catalog,
and verifies exact state again. No catalog change is saved. The final PIN is
the persisted PIN after replacement, not a promise that an original receiver
PIN survives transfer. Only bounded booleans and fixed failure codes leave the
target. Private digest comparisons never appear in assertion diagnostics.

Ordinary test return closes the database and releases the workspace lock.
Subsequent stock runner cleanup is expected and is not prior normal-quit proof.
A passing target proves native restart/readback on that host only. Require the
stock test result, external process/binary binding and recipient-owned evidence
on both hosts before counting restart acceptance. Current preparation alone
leaves the physical gate incomplete and Phase 5 held.

Expectation preparation has a supported file-only route in
`tool/native_nearby_restart.dart`. After normal quit and before restart, the
native owner supplies an independently accepted cold archive with this layout:
`validation-owner.json`, `support/wired_parts.sqlite`, any retained SQLite
sidecars, and `support/part_photos/`. Keep the original owner bytes and paths in
the archived marker. Verify its retained hash/manifest first. This archive must
come from the stopped final installation, not a capture taken after reopening.

Call the helper from a private local Dart preparation script using the existing
package configuration. It needs the role's accepted native post-leg3
`NativeTestSnapshotResult` and the independently accepted final PIN digest from
the approved import-policy/source-PIN evidence. Those inputs are private local
records. The coordinator CLI has no plaintext proof export and none is added.

```dart
await prepareNativeRestartExpectation(
  archive: Directory(acceptedColdArchive),
  role: ValidationRole.receiver,
  postLeg3: acceptedRolePostLeg3Snapshot,
  acceptedPinDigest: independentlyAcceptedFinalPinDigest,
  sourceRevision: restartBuildRevision,
  sourceTree: restartBuildTree,
  destination: File(controlledExpectationPath),
);
```

For the Mac use `ValidationRole.sender` and its own archive and native snapshot.
The helper copies into its own disposable scratch workspace, opens that copied
SQLite read-only with Drift migrations disabled, and reuses
`NativeFixtureSnapshot.capture`. It matches native domain/assets/shared-settings/
profile/count/source/timestamp commitments and the separately supplied private
PIN digest. It then writes the complete private expectation to a new controlled
file outside the archive. It exclusively creates that file at the final write,
so a racing preparation cannot overwrite it. It rejects an existing destination.
It never prints the expectation or opens the live installation, and it deletes
only its own scratch directory. Tests prove accepted/rejected preparation leaves
archive bytes unchanged. Reopening and deriving both sides from that reopened
state would be self-comparison and must not count as restart proof.

## Isolated Job details acceptance, issue #116 under #61

This extension uses `integration_test/company_join_native_test.dart`, the existing
resident RPC, guarded native taps, fresh PIN sign-in, Pair/Match, mutual Verify,
both explicit Enables, Sync Now, and safe Close/drain/retry. It does not coordinate
hosts. Qualify both native artifacts against the reviewed frozen source before
either first launch. Preserve `j61-created-v19`, its source, stores and evidence.

Require `COMPANY_JOIN_NATIVE_MODE=true`, `COMPANY_CREATED_JOB_NATIVE_MODE=true`,
`COMPANY_JOB_DETAILS_NATIVE_MODE=true`, `COMPANY_JOB_NAME_NATIVE_MODE=false`,
`COMPANY_JOIN_NATIVE_RUN=j116-details-v1`, the ordinary role/source/tree/adapter
defines, and `COMPANY_CREATED_JOB_NATIVE_PRODUCT_REVISION` equal to the new source
revision. Details mode requires schema 10 and a separate synthetic details custody
namespace. The old recovery-manifest defines must be absent.

`COMPANY_JOB_DETAILS_NATIVE_MANIFEST` points to a frozen manifest readable inside
the app sandbox. Its sibling `source/` contains the frozen source copies, using
repository-relative paths. No entitlement change or access to the live checkout
is needed. The exact source inventory is `sourceLfSha256`, a map of relative paths
to SHA-256 of UTF-8 text with CRLF normalized to LF. Copy all reviewed app/lib and
app/tool Dart files, this adapter, app/pubspec.yaml and app/pubspec.lock. The bundle
rejects symlinks, unexpected files, missing required product/adapter files and
hash differences. Product, build and binary qualification remains an external gate.

The manifest has exactly `format: 1`, `kind: j116.details.source@1`,
`run: j116-details-v1`, `revision`, `tree`, `adapterSha256`, `productRevision`, and
`sourceLfSha256`. `COMPANY_JOB_DETAILS_NATIVE_MANIFEST_SHA256` is SHA-256 of its
exact raw immutable bytes, bounded to 65536 bytes and decoded from the same verified
buffer. The adapter hash equals its LF-normalized entry in the source map. Generate
deterministic JSON once after freeze, then move the same bytes and source bundle
inside the sandbox without rewriting them. Paths and hashes never authorize changes
to a retained fixture or a new product revision.

The sole new wire action is `jobDetailsUi`, with exactly one `step` argument.
No field/value/script arguments are accepted. These finite steps use a shared,
deterministically selected Job after both original Jobs have synced:

| Step | Required state and effect |
| --- | --- |
| `inspect` | Zero details operations; save each device's shared Job and immutable creation/name baseline. |
| `editMixedOffline` | Zero details operations; owner uses the real editor for customer Acme/status archived; member saves notes Gate 3 on the same Job. |
| `inspectMixed` | Two typed operations, Acme/archived/Gate 3, no field conflict. |
| `checkpointMixed` | Same state after actual 1/1 then 0/0 complete results on the same Pair page within 300000 ms; save a locked cold checkpoint. |
| `editNotesOffline` | Two operations; each device saves its distinct synthetic notes through its real editor. |
| `inspectConflict` | Four operations, two visibly attributed notes alternatives and last agreed Gate 3. |
| `checkpointConflict` | Same state after completed sync; save unresolved cold checkpoint. |
| `resolveNotes` | Owner selects an actual notes candidate and saves only that field; preserves all other field frontiers. |
| `inspectResolved` | Five operations, resolved notes, unchanged Acme/archived fields. |
| `checkpointResolved` | Same state after completed sync; save resolved cold checkpoint. |

Run the mixed 1/1 exchange and its 0/0 repeat before invoking a UI inspection,
because each UI step stops the LAN controller, signs in through the production
gate and returns to a fresh Pair page. Every save verifies its signed changed
field set, captured parents, resolution flags and immutable creation/name bytes.
An uncertain save fails the command and retains the production pending editor;
the adapter never retries or abandons it automatically. `finish` keeps its original
enrollment and Close/drain transitions; details completion uses the explicit
checkpoint steps. Cancellation evidence keeps actual confirmed counts and requires
fresh Pair and history reverification before continuing.

Checkpoint filenames are immutable `join-details-checkpoint-PID-SEQUENCE.json`.
After normal native quit, relaunch with `COMPANY_JOB_DETAILS_NATIVE_CHECKPOINT`
and `COMPANY_JOB_DETAILS_NATIVE_CHECKPOINT_SHA256`, the exact raw checkpoint byte
hash. No existing details root is admitted without this explicit checkpoint.
Admission checks schema 10 and a read-only SQL hash before opening custody/Drift.
Saved protected bytes/revisions compare before legitimate PIN sign-in, which itself
advances custody revisions. Typed creation/name/details receipts, all three family
ACKs, original bytes, identity and derived views compare after sign-in, before any
Nearby controller is created. Cold readback writes a separate evidence file and
allows the next bounded stage. All checkpoint records retain `passed: false`;
cross-device native acceptance, process quit, source review, CI and merge remain
separate gates. This does not establish mesh, mobile, OS reboot or general power-loss
recovery.
