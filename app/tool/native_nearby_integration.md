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
