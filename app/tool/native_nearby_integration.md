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
and opens SQLite read-only to verify schema 2, required table/column names,
integrity and the exact local device profile before production startup.

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
