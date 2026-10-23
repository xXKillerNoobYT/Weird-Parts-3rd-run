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
`COMPANY_JOIN_NATIVE_RUN=j116-details-v3`, the ordinary role/source/tree/adapter
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
`run: j116-details-v3`, `revision`, `tree`, `adapterSha256`, `productRevision`, and
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
For a non-checkpoint details step, the final return to Nearby completes the
already-admitted UI step. It uses the existing bounded passive wait for route
build, State capture and controller readiness, even if the original command
deadline elapsed during saved-history verification. Lifecycle must remain current
before the route push and after completion. This starts discovery only: fresh
Pair, authentication and explicit Enable remain required before company exchange.
Save, Pair, Match, Verify and Enable retain their original deadline guards. Keep
the exact command wire while its result is UNKNOWN; late completion does not
authorize a second save or a replacement command.
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

### Same-v3 preserved creation baseline

This reuses the existing baseline contract for the independently preserved v3
creation baseline. Retired v2 roots, failures and signed edits remain separate;
they are not adopted as accepted evidence. No new recovery contract is added.

The `COMPANY_JOB_DETAILS_NATIVE_BASELINE_RECOVERY` path and
`COMPANY_JOB_DETAILS_NATIVE_BASELINE_RECOVERY_SHA256` admit only the audited
`j116-details-v3` owner/member roots stopped before any name/details operation.
The kind remains `j116.interrupted-baseline.recovery@1`. Each role has
its own private external raw-byte-hashed manifest and cold archive. No in-root
checkpoint is manufactured. The schema-9 name-recovery contract is unchanged.

The manifest has exactly these keys:

| Key | Required value |
| --- | --- |
| `format`, `kind`, `run`, `role`, `root`, `namespace` | `1`, the same kind, `j116-details-v3`, exact role and original canonical root/custody namespace. |
| `origin` | Revision/productRevision `6a417521bb80ed6614ef5a5ef71f7158c6e0f929`, tree `a3f403d4d8dfa4bcb630d481e006a722e5d9a3cd`, adapter `ae534fe3996ff64de481bf5364a9adbb1575b70f066c85a53bccde41929be8dd`, manifest `188758e654d61748851a82f7800ba02225f364d089e3b7f1308343d5fc196c39`; keys are `revision`, `tree`, `adapterSha256`, `productRevision`, `manifestSha256`. |
| `recovery` | Same five keys matching the reviewed recovery artifact and current source-manifest defines. |
| `originManifestPath` | Absolute path to the unchanged original raw manifest with its frozen sibling `source/` bundle, readable locally inside the app sandbox. |
| `coldArchive` | Absolute canonical path outside the original root, containing its independently accepted complete stopped-file copy. No private file crosses hosts. |
| `files` | Complete relative `{path, bytes, sha256}` inventory of the identical original/cold files; no links, missing/extra files, duplicates, traversal or checkpoints. The only permitted details evidence is exact `details-ui-PID-20.json` plus `details-shared-baseline-ROLE.json`. |
| `originalFiles` | Exactly `owner: validation-owner.json`, `ready: join-exercise-ready-PID.json`, `localCreation: created-local-job.json`, `priorSnapshot: created-before-retained-pair-PID.json`; original PIDs are owner 33960/member 87978. |
| `evidence` | Exactly `identity`, `sqlSha256`, `bindingSha256`, `companyJobCount: 2`, `createAckCount: 2`, `nameCount: 0`, `detailsCount: 0`, `nameAckCount: 0`, `detailsAckCount: 0`. The identity is the unchanged eight-field original public snapshot. SQL hash uses the existing sorted-table/sorted-row canonical digest; binding hash covers the exact stored binding string. |
| `retiredEpoch` | The original control epoch, which the resumed resident refuses to configure. |

Both source manifests must contain the same 95 paths, with every LF hash unchanged
except this adapter. This preserves all 17 frozen product files. Original public
identity/evidence files remain immutable and are checked against the pinned origin.
The first admission verifies the complete original and cold inventories, schema 10,
integrity/references, two Jobs/two create ACKs, empty name/details families, exact
SQL hash and public binding before opening Drift with migrations disabled.
No manifest fields are added. Both frozen inspection files must match their raw
inventory hashes and original source headers. Only `inspect`, with no UI save,
two typed creation receipts/two create ACKs, empty name/details records and empty
field heads/candidates, is admitted. Its identity and SQL hash must match the cold
manifest; the selected creation digest and creation/name hashes must match the
shared baseline. Saved, modified, unpinned or additional details evidence refuses.

Before production startup, both existing native protected namespaces must be
present. Their public installation/generation/key/store/path and company/shop/user/
device headers must match the original identity and SQL binding. The original local
creation receipt is verified with that public installation key. Only no pending
intent or a pending incoming creation for an already-held frozen operation is
allowed. The unchanged kernel validates the private signing material, custody,
trust, receipt and witnesses and performs its normal reconciliation. There is no
manual repair or write to protected bytes. Current protected hashes/revisions are
recorded locally before this call; these observations are not an independent trust
anchor and raw private bytes are never exported.

After normal PIN sign-in, the same identity, unchanged full SQL state, both typed
creation receipts, original local signed row, both signed family ACKs and the actual
two-Job UI must pass before any Nearby controller exists. Recovery does not decide
the original command outcomes; preserved terminal records remain separate evidence.
Continue with a new epoch and fresh Pair/Match/Verify/both Enables. Do not replay
an expired wire. Historical inspection terminals are not imported into the new
resident's details acceptance list. Later
real mixed/conflict/resolved checkpoints carry `detailsBaselineRecoverySha256` and
require this same pinned origin context. They use their own current checkpoint
hashes instead of comparing progressed state to the obsolete cold baseline.
The original shared-baseline file remains readable only through its exact
hash-pinned recovery member and original source provenance, including during later
checkpoint stages. General evidence readers and header checks stay unchanged.

### Same-v3 interrupted pending local details

`COMPANY_JOB_DETAILS_NATIVE_PENDING_RECOVERY` and
`COMPANY_JOB_DETAILS_NATIVE_PENDING_RECOVERY_SHA256` add one separate cold
admission state. Both existing baseline recovery defines remain required. This
state preserves each device's one genuine `editMixedOffline` save before actual
Sync. It does not create or substitute for a mixed checkpoint. The original
zero-details baseline and mixed 1/1 followed by same-page 0/0 gates are unchanged.

The external raw-byte-hashed manifest has exactly these keys:

| Key | Required value |
| --- | --- |
| `format`, `kind`, `run`, `role`, `root`, `namespace` | `1`, `j116.interrupted-pending-details.recovery@1`, `j116-details-v3`, exact original role/root/namespace. |
| `creationOrigin` | The unchanged five-key `6a41752` origin described above. |
| `savedOrigin` | Five keys `revision`, `tree`, `adapterSha256`, `productRevision`, `manifestSha256`; values are `f3a061e064bdc83585434dbaf479b42b06753ee0`, `ad1c7a95d6901ff40bf0e949d7b6f7af8de9f933`, `a7eca4365c2d9018d5beb2af0c551ec83d08bfc1ab959813830e581857129511`, the same `f3a061e` revision, and `7eae1b69e9eb5663feb971623cadf0173b3c42a6ddd8a79768a088e091fcc809`. |
| `recovery` | The same five keys matching the next reviewed build's defines and source manifest. |
| `savedManifestPath` | Absolute local path to the frozen f3 manifest and its sibling `source/` bundle. |
| `baselineRecoverySha256` | Exact unchanged baseline recovery hash, also present in the genuine saved UI record. The baseline manifest is validated against its original f3 recovery provenance. |
| `coldArchive`, `files` | Independent stopped-file copy outside the live root, plus complete relative `{path, bytes, sha256}` inventory. All original/live cold bytes must match. Required auxiliary directories must exist. Links, missing/extra/duplicate members, traversal, restore markers, backups and staging refuse. No protected custody bytes cross hosts. |
| `savedFile` | Owner `details-ui-29804-1.json`; member `details-ui-21403-1.json`. Their immutable whole-file hashes are owner `f4d3e91634535ca5059f2fb69ef202e6982178ad868269a12b9125c3aa843b91` and member `e13f6b77899035b1475bdfb621cec94e35919ec7838d5b33a0d42cec7b7c6cd1`. These are not typed-receipt hashes. |
| `evidence` | Same exact keys as baseline evidence, with `detailsCount: 1` and `detailsAckCount: 0`; creation 2/ACK 2/names 0 remain required. SQL and identity must also match the immutable saved evidence. |
| `retiredEpoch` | The interrupted f3 control epoch. Both this epoch and the original baseline retired epoch are refused. |

Creation, saved-edit and recovery source identities stay separate. The creation
and saved manifests, followed by saved and recovery manifests, must retain all
95 source paths and every LF hash except the adapter. All 17 product files remain
unchanged. Admission opens SQL read-only and checks the full canonical SQL hash,
schema 10, 32 tables, integrity/references, exact family counts and binding hash.
It never restores the old database or writes protected credentials.

Before production startup, the existing native identity, company custody and
database-path checks run, the original creation admission seal is verified, and
the one outgoing details receipt is verified with the original public key/store.
A pending command may be absent. Otherwise the pre-kernel guard requires that
exact already-committed local details operation, both witness fields, and matching
operation, row, receipt and command identifiers through the production commit
verifier. Unknown, unrelated, incoming or partial pending commands refuse.
Unchanged production startup verifies actual `afterWitness` equality before
installation readiness and controller creation. The prior `beforeWitness` is not
compared to current postcommit SQL. Normal production startup owns reconciliation.

Normal locked UI/PIN, original public identity, unchanged full SQL, both typed
creation receipts, signed creation ACKs and typed details/dependency verification
must pass before any Nearby controller is created. Actual signed operation units,
authorship and empty original field parents define the local edit. Production UI
is checked against production-derived views. Saved JSON claims are never a
substitute for receipt verification. The cold readback remains `passed: false`.

Continue with a fresh epoch, Pair/Match/Verify and both Enables. Do not save the
edit again or import old commands/Sync terminals. Later genuine checkpoints carry
both `detailsBaselineRecoverySha256` and `detailsPendingRecoverySha256`; they
require both frozen lineages while verifying their own current SQL and protected
bytes. Pending-edit restart is only accepted after both actual devices cold-open
and display the preserved local fields. Sync, conflict, restore and identity
acceptance remain separate required gates.

Keep caller tool slices inside the outer 30-second lifetime: use at most 8-second
command slices, 4-second observation slices and 250-ms polls. Catch timeout/errors
without losing the retained exact wire and command identity. Observe the same
in-flight command before deciding the next action; do not generate another command
or restart a native process to hide an uncertain result. Short tool returns do not
alter native deadlines, Pair lifetime, PIN lease or protocol budgets.
Keep Observe, signed comparison and Match in one caller operation inside the
outer 30-second lifetime. Use at most six seconds per native command slice and
two seconds per observation request; the existing signed HTTP request is bounded
at eight seconds. Retain the exact effect wire before dispatch and stop on UNKNOWN
for explicit reconciliation. These caller limits do not extend native deadlines
or the comparison TTL; do not insert a model/tool gap or automatically retry an
expired comparison. The retained successful v3 pipeline measured 8,312 ms.
