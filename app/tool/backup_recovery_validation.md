# Synthetic native encrypted backup recovery

Issue #33 requires evidence from installed native builds. Unit tests and SQLite snapshots do not satisfy this gate. This target mounts the production WiredPartsApp and calls its existing AppScope.restoreFromBackup callback. Production app.dart checks the SQLite schema before closing the live database. No test seam is added.

Build from app in the isolated recovery branch. Use a fresh run identifier on each host.

```powershell
flutter build windows --debug -t tool/backup_recovery_validation.dart --dart-define=RECOVERY_RUN=windows-recovery-20261007a
```

```sh
flutter build macos --debug -t tool/backup_recovery_validation.dart --dart-define=RECOVERY_RUN=mac-recovery-20261007a
```

Record the source revision and uncommitted diff digest, build command/result, actual executable path/digest, host and launch time. On Mac, copy to a dedicated synthetic validation installation and independently verify its bundle identifier, signature, sandbox and file entitlements. Preserve the same application identity and executable for the second launch. Do not launch from the normal application installation.

The target redirects all path-provider directories into two owner-marked, process-locked temporary workspaces. It reuses the Nearby synthetic fixture without changing Nearby. The roots are wired-parts-lan-recovery-RUN-sender and wired-parts-lan-recovery-RUN-receiver. It refuses foreign directories, symlinks and interrupted initialization. Real database files or device credentials are never selected or copied. Fixture setup uses the development PIN authorized for this validation through production PinService. Receipts omit the PIN and its hash.

The source fixture includes every domain table. Its registry records all IDs, values, sync metadata and relationships. These include Category, Style, Type, compatibility Device, Brand, Supplier, Part, PartDevice, BrandVersion, SupplierListing, Job, JobLine and OrderSplit. A soft-deleted Job retains its revision, deletion timestamp and origin. The local PNG has a byte digest. Source and receiver IDs differ, so replacement cannot pass as a merge.

The first launch performs the following scenario automatically while displaying the production UI.

1. Seed both synthetic shops once. Checkpoint WAL, collect with BackupStore, encrypt with the default production BackupCodec and atomically save shop.wpbackup outside replaceable shop storage.
2. Call the production restore callback with a wrong password, a damaged authenticated archive and an encrypted unsupported-schema database. Each rejection must preserve the complete domain registry, safe settings, synthetic PIN, photos and every device-profile field including creation time. All rejected cases must retain the exact checkpointed SQLite digest.
3. Restore the original encrypted archive. Require all source domain records and photo hashes, replacement of the receiver sentinel, preserved receiver identity, configured synthetic PIN and backup history metadata.
4. Write a completed recovery-scenario.json manifest only after every comparison passes. Each step writes a before/after JSON receipt with archive digest, schema version, expected/actual callback outcome and separate validation result. A callback return alone cannot create a passing validation receipt.

Close the app completely, then launch the same installed executable again. It detects the completed manifest and performs restart readback only. It must write a passing restart receipt. Missing evidence, archive digest mismatch or changed records must fail. It never reseeds an initialized workspace. RECOVERY_ACTION=restart can be set when building an explicitly readback-only artifact; it refuses missing workspaces/evidence.

Preserve the archive, manifest and all five selected passing receipts. Record the production UI state and the actual process restart separately. Receipts contain the native platform and executable path, but cannot alone prove installation identity or operator actions. The printed RECOVERY exercise PASS and RECOVERY restart PASS must both occur on each host before closing its native recovery gate.

Backup header version 1 identifies the encrypted container. SQLite user_version identifies its database schema. They are separate. The production callback checks the SQLite header before closing or reopening the live database. BackupStore checks it again at its direct-call boundary before touching the live directory or interrupted-restore state. Versions 1 and 2 are supported. The real schema 1 test removes the version 2 columns, restores through staging and verifies every fixture ID, relation and photo after the existing migration. Unknown or zero versions reject. There is no schema bump or new migration.

Keep the native installation and restart evidence separate from automated test results. This target does not authorize a merge or unlock Phase 5.

Automated checks run from app.

```sh
flutter test --no-pub test/features/backup/backup_schema_test.dart test/tool/backup_recovery_validation_test.dart
flutter analyze --no-pub
```

The affected Windows suite passed 88 tests across backup, nearby_wifi_test.dart and backup_recovery_validation_test.dart. Its command excluded the existing test named `failed recover rename keeps staging and marker`, which invokes POSIX chmod and failed on Windows before this change. This exclusion is a remaining platform-specific test limitation, not a passing interruption test. Run it on a supported POSIX host and retain its result separately.
