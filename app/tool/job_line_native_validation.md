# Native atomic job-line validation

This is an opt-in phase of `installation_identity_validation.dart` for issue #94.
It uses the existing `ValidationWorkspace` ownership locks and two separate
synthetic database files. It never opens the app's production namespace or
business folders. Company pins, signed facts, and user assertions are fixture
inputs confined to the test/tool code. This does not prove enrollment or sign-in.

Build the existing target with a fresh 1-32 character lowercase run identifier:

```text
flutter build windows --target tool/installation_identity_validation.dart --dart-define RECOVERY_RUN=<fresh-run> --dart-define IDENTITY_JOB_LINE=true
flutter build macos --target tool/installation_identity_validation.dart --dart-define RECOVERY_RUN=<fresh-run> --dart-define IDENTITY_JOB_LINE=true
```

Run the binary. Wait for `Native job-line exercise PASS`. The sender and receiver
must use actual `NativeInstallationSecureStore` writes. The exercise proves local
apply/replay, incoming apply/replay, and wrong-shop refusal without logical row
changes. It injects a lost response after a committed second command and leaves
the sealed protected intent for recovery.

Quit through the normal window close action. Launch that same binary with the
same run identifier in a fresh process. `Native job-line restart PASS` requires a
different PID, unchanged logical history, complete pending-intent reconciliation,
the original durable receipt on replay, and the saved projection.
The restart verifies a matching sealed native intent before reconciliation.
It refuses later replay-only launches and preserves the first restart receipt.

Evidence is under the owned sender workspace's `receipts` directory in
`job-line-exercise.json` and `job-line-restart.json`. Receipts contain hashes,
counts, statuses, and PIDs. They contain no private keys or signed credential
bytes. Preserve both files and binary/source hashes as the acceptance record.
Logical hashes cover the declared Jobs and job-line command tables. They do not
claim catalog, photo, or whole-shop restore acceptance.

Without `IDENTITY_JOB_LINE=true`, the existing recovery and Nearby validation
behavior remains in its history-free synthetic stores.
