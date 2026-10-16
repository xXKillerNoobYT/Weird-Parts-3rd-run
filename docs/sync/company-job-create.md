# Company owner creates a Job

Governing issue: #99 under #33 and #61. Base: `3e0e52e2f74f53a0821e20b46202395b7abcb31d`.

## Compatibility decision, frozen before implementation

Only a new company bootstrap grants the explicit `createJob` capability to both its first user and its installation device. Existing #97 signed facts and authority packages remain valid with exactly their original capabilities. Recovery preserves the source capability profile for both replacement grants. Recovering an old package never grants `createJob`.

Existing owners without this capability see an unavailable, upgrade-needed message. An explicit authorized upgrade of existing grants and authority packages is pending and outside this increment. Fresh-company support does not complete that upgrade requirement.

## Contract and ownership

`CreateJob(companyId, shopId, jobId, requestId, name)` supplies UUID scope and identity plus a trimmed, bounded, nonblank name. The current opaque owner session supplies the actor, installation and generation. `job.create@1` freezes its timestamp and complete initial projection in signed operation bytes. New operation and receipt domains remain distinct from the unchanged job-line domains.

Names contain at most 100 grapheme clusters, matching the UI counter, and at most 4,096 UTF-8 bytes. A code-unit bound precedes encoding and grapheme segmentation to reject pathological input cheaply. Names are not Unicode-normalized; existing accepted names keep their command bytes. The operation and authorization limits remain 65,536 bytes. Finalized audit evidence must equal the complete expected canonical record; unknown fields or changed serialization refuse without repair.

The protected command intent dispatches between two named families. A new durable company Job record binds company, shop and Job identity to the immutable operation, outgoing state, audit, sealed receipt and initial projection. Its SQL transaction also inserts the Job projection. Exact authorized retry returns the original receipt. A reused request with a changed actor or command, or any existing Job ID, refuses without business writes.

The new signature domains are `wiredpart.job.create.authorization@1:`, `wiredpart.job.create.operation@1:` and `wiredpart.job.create.receipt@1:`. The existing job-line domains and old protected-intent encoding remain unchanged. Protected seal and reconciliation require the embedded operation family to match the intent. The signed timestamp uses whole seconds, matching persisted Drift date precision.

Company Jobs are read through the owner permission boundary. Legacy DAOs remain fenced. Line editing, Join, transport, relay and sync are outside this increment. Pending outgoing means prepared locally, never delivered.

## Throughput checkpoint

- Blocking first steps: this compatibility decision, production authority path, bounded protected intent and additive schema.
- Independent workstreams: root owns review and GitHub; this single owner owns all coupled source; root coordinates later native Windows and Mac checks.
- Shared mutable state: only the issue #99 checkout and its focused SDK lease. Prior #97 checkouts and native fixtures stay frozen.
- Smallest safe decomposition: one owner because authorization, schema, recovery, reconciliation and UI share one atomic invariant.

## Verification and rollback

Focused tests must use production enrollment and sign-in. They cover authorization refusal, scope, exact retries, collisions, atomic rollback, committed lost reply and reopen, old-package profile preservation, schema compatibility and company-only widgets. Native Create, normal quit and cold restart remain separate acceptance gates until executed against one frozen candidate.

This increment supports at most 512 Jobs per company shop. Create refuses at that same bound before writes; an exact authorized retry remains available at capacity. Paging and a larger measured capacity are pending.

Schema 6 is additive. Keep the previous source/build and encrypted authority packages. Older production database code must refuse schema 6 without mutation. Authority packages restore authority only, never Job history. Company-history backup/copy remains refused pending its own reviewed migration. No merge or downgrade into legacy editing is authorized.

## Implementation handoff

The owner delivered the V2 correction candidate for independent root review with no commit or push. The focused company, backup-schema, job-line and receipt batch passed 185 tests. The affected native-fixture, restart and backup-validation batch passed 86 tests. The three targeted post-hook tamper tests passed, and focused static analysis of ten changed targets reported no issues.

Shared finalization requires a nonnull protected after-witness and compares it with the current SQL evidence after `beforeCommit`. Both Create Job and job-line new-intent paths use this check before commit. The witness covers the exact previously verified receipt seal and complete family-specific evidence. Changed SQL refuses and rolls back; the code never repairs or re-signs it. Tests prove rollback, recoverable intent cleanup and success with the same request after receipt-seal tampering in both families and audit-only tampering in Create Job.

Existing native fixture guards admit only known schemas 2, 3, 4, 5 and 6 with their separate exact table sets. Their domain counts are respectively 13, 20, 20, 21 and 22, excluding local settings and profile tables. Schema 6 has 24 actual tables and requires `company_jobs`. Unknown schema 7, a missing required table and populated company history refuse. Frozen older proofs keep their declared schema and cannot be relabeled as schema 6.

The original frozen #97 production `AppDatabase` separately passed the root-owned schema-6 refusal check without changing database bytes, rows, settings or declared version. V2 retains schema 6, so that proof was not rerun. The root's V1 full-suite result and independent review remain preserved separately from V2 focused evidence. The full V2 suite and independent V2 review remain pending root gates.

The capacity test injects cloned journal rows to prove the count guard refuses without writes and exact retry remains available. It does not establish performance or correctness with 512 independently valid Jobs. The widget test uses real enrollment, sign-in and Create, then simulates a lost reply. Retry retains the original command and renders one Job. A narrow presentation double exercises the terminal capacity status separately.

Native acceptance is prepared in the existing bootstrap harness with `COMPANY_JOB_VALIDATION=true`. It creates one original-installation Job through the production UI and records public identity, provenance, outgoing count and receipt hash. Authority recovery on the replacement installation must leave its Jobs empty. The existing cold-process restart and normal-exit mechanism remains the acceptance method. Frozen Windows and Mac acceptance, draft PR and required review remain root-owned pending gates.
