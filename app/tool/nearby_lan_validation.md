# Synthetic Nearby native acceptance

This target invokes the production UI after redirecting every path-provider directory into a dedicated OS temporary directory. It does not change production startup or the Nearby protocol. It does not automatically match, send, or accept a shop.

Build from `app` with the same run identifier on both hosts. Use a new identifier for each fresh experiment. Roles are exactly `sender` and `receiver`.

```sh
flutter build macos --debug -t tool/nearby_lan_validation.dart --dart-define=LAN_VALIDATION_RUN=house-lan-20260922a --dart-define=LAN_VALIDATION_ROLE=sender
```

```powershell
flutter build windows --debug -t tool/nearby_lan_validation.dart --dart-define=LAN_VALIDATION_RUN=house-lan-20260922a --dart-define=LAN_VALIDATION_ROLE=receiver
```

On Mac, copy the built app to the designated synthetic test location and use the independently verified sandbox identity `com.weirdtoo.wiredparts.lanvalidation.mac20260922`. Verify that copied app's signature, bundle identifier and sandbox/network entitlements before launch. Do not launch a build from the normal application location. On Windows, launch the validation executable from its dedicated build location. Record command, exit status, source revision, executable path, network interface and local LAN address per host.

The runner derives its root from the native OS temporary directory plus `wired-parts-lan-<run>-<role>`. It accepts no custom storage root. It refuses pre-existing directories without a matching initialized ownership marker, interrupted initialization and symlinks. It holds a process lock while the app is running. Do not delete roots to retry. Use a fresh run identifier. A stopped app's original run/role can be relaunched to read the same fixture. Keep the same native bundle identity across launches. OS temporary storage is suitable only for this bounded validation, not long-term archives.

Each role starts with its own synthetic job, Category, Type, Variant, part and locally generated PNG. Fixture IDs include the role, so receiver replacement is distinguishable from a merge. The fixed role-specific device ID remains local. The ownership marker and receipts live outside the shop's support directory and survive a shop replacement.

1. Launch both validation builds. Record their printed synthetic roots and initial receipts. In the normal application UI, set a synthetic catalog PIN on each device. Do not record PIN values or hashes. Close and relaunch both apps to obtain PIN-configured baseline receipts and clear the in-memory unlock grant.
2. Confirm each screen shows its role-specific synthetic shop. Open More, then Nearby. Verify discovery on the house Wi-Fi using UDP 41000. Compare the six-digit Match code on both screens manually. Record only that the comparison passed, never the code or PIN.
3. Use normal Match, Send this shop and Accept shop controls. Record that the receiver displayed the PIN prompt and accepted its synthetic PIN. Confirm the replacement warning applies to the synthetic receiver shop. Do not select any real shop, backup or photo.
4. Record both devices' visible transfer result. Close and relaunch each same validation executable. Each launch writes a new JSON receipt under the printed root's `receipts` directory. These receipts contain queried database values, local device IDs and actual photo-byte SHA-256 hashes. They omit the PIN hash and code.
5. Copy the four operator-selected receipts into the evidence folder and compare them using the command below. Preserve operator evidence for the interface/IP, both-screen Match comparison, PIN prompt, warning and transfer result separately. The comparison proves persisted content and identity; it cannot prove which physical devices or network carried the transfer.

```sh
python3 tool/verify_nearby_lan_receipts.py source-before.json source-after.json receiver-before.json receiver-after.json
```

The verifier requires configured PINs, unchanged sender fixture data and photos, replaced receiver sentinel, identical copied content and photo hashes, and stable receiver identity. The readback occurs before production UI startup, after reopening the persisted database. Receipts are validation artifacts, not Phase 5 two-way synchronization proof. No merge authority is granted by this target.
