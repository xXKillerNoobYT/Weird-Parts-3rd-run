# Synthetic identity and Nearby receipts (#49 under #33)

Use `tool/installation_identity_validation.dart` on the reviewed candidate.
The opt-in `IDENTITY_NEARBY_ROLE` is `source` on Mac and `receiver` on Windows.
An empty role preserves the legacy identity/backup behavior. No transport,
import callback, consent, or native UI action is injected by these receipts.

1. Build each host once with its role and a fresh `RECOVERY_RUN`, for example
   Mac `r49-mac-20261011-a`, Windows `r49-win-20261011-a`. Preserve the earlier
   r90 apps, workspaces, backups, and receipts. The fresh launch first runs the
   existing synthetic recovery exercise in its guarded workspace and isolated
   `synthetic.identity.<run>.receiver` native namespace. Both visible apps use
   their local receiver fixture. The word `source` selects the receipt role.
2. Mac prints `IDENTITY NEARBY source EXPORTED` and writes
   `identity-nearby-source.json` in its receiver workspace root. This is the
   actual visible sending shop before transfer. Record the candidate commit,
   exact bundle path/hash, PID, and SHA-256 of this file. Keep this shop unchanged
   until transfer finishes. The export includes every business table, stable IDs
   and relationships, settings, and photo names and SHA-256 values.
3. Windows prints `IDENTITY NEARBY awaiting expected source`. Copy the Mac
   receipt bytes to `identity-nearby-expected-source.json` in the Windows
   receiver workspace root printed by the harness. Verify its SHA-256 equals
   Mac's recorded value. Windows validates provenance and distinct fixture runs,
   confirms its original state is unchanged, writes `identity-nearby-baseline.json`,
   and prints `IDENTITY NEARBY receiver PINNED`. Wait for PINNED before transfer.
   The baseline embeds the expected source and its hash plus recipient identity,
   security floors, receiving binding, local profile, PIN evidence, and shop.
4. Use the real Nearby UI over local Wi-Fi. Observe discovery, Pair, Match,
   Send, and receiver Accept. Record both peers and the transfer result. This
   is one actual Mac to Windows copy. The harness performs no backup import
   during this phase. After the UI settles, create the ordinary UTF-8 file
   `identity-nearby-request.json` in the Windows receiver root.

   ```json
   {
     "format": 1,
     "run": "r49-win-20261011-a",
     "root": "<exact Windows receiver root printed by the harness>",
     "phase": "capture-copy",
     "expectedSourceRun": "r49-mac-20261011-a",
     "expectedSourceSha256": "<recorded Mac receipt SHA-256>",
     "attempt": 1
   }
   ```

   JSON-escape Windows path backslashes. The path is a comparison value and is
   never opened. Additional paths, wrong run/version/phase/source, or a symlink
   request are refused. Each changed request is attempted once. After a refusal,
   correct the cause and increment `attempt`; existing proof is preserved.
5. Require `IDENTITY NEARBY copy PASS` and `identity-nearby-copy.json`. The
   comparison uses the pinned Mac source, verifies full rows/settings/photos,
   recipient identity/floors/profile, the imported shop PIN, a changed receiving binding,
   and Nearby import metadata. It does not infer LAN transfer from those fields.
   Whole-shop copy imports the source's legacy catalog PIN setting. The receipt
   requires configured PIN, successful synthetic `1234` unlock, wrong `9999`
   rejection, and a source-matching fingerprint of the stored verifier. No raw
   verifier is exported. The checked PIN service is left locked. Installation
   credentials and security floors remain local. Restart requires the imported
   PIN fingerprint to remain stable and repeats the usability checks.
6. Quit Windows normally using the app. Record successful exit and PID. Launch
   the same bundle with the same defines, without rebuilding or changing receipt
   files. A valid copy receipt selects dedicated Nearby restart validation and
   prints `IDENTITY NEARBY restart PASS`, writing `identity-nearby-restart.json`.
   It rechecks the pinned source, original protected/local state, post-copy
   binding stability, and every business row/photo across launch. Receipt PID
   observations supplement the operator's normal quit/fresh process evidence.

All new receipts are outside the replaced `support` tree. Receipt writes refuse
to overwrite existing files. The original identity manifest, recovery manifest,
backup, and receipts remain intact. A later default legacy run still checks its
original backup scenario and can correctly refuse the subsequently replaced
shop. New Nearby PASS labels refer only to the new comparisons. Pair/Send/Accept,
source hash agreement, exact bundle provenance, and normal quit/fresh process
remain separate operator gates. This is synthetic one-way copy validation and
does not establish enrollment, two-way sync, or mesh acceptance.
