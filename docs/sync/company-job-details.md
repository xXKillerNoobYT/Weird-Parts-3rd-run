# Causal company Job details

Governing [#116](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/116), within [#61](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/61). Base `d0413b76d7f137ff66192df1ac373bdb32d68ead`, branch `codex/issue116-job-details`. This is the implementation contract; unchecked acceptance remains NOT_RUN. Root owns coordination, independent review and native integration. This builder owns common source and the sole Windows SDK lease after root's design clearance.

## Functional increment and throughput checkpoint

One editor saves the five existing Job fields offline: customer, location, job number, status and notes. One signed details family and one finite Job-specific registry serve all five. Independent fields combine; a conflicting field retains attributed alternatives until explicit resolution. Status is `active` or `archived`; archiving is not deletion. Job names retain their existing contract.

One coupled milestone is active. Finish domain, typed protected admission, schema/fences, sync and actual-widget behavior before freezing the public API for root's native work. Reuse existing fixtures, controller, installation kernel and tools. No per-field engine copies, generic extension framework, new transport, SDK installation or native-adapter work. Prove the first production command RED/GREEN before broadening checks. Preserve failed attempts and exact command logs. Stop at a concrete tested/reviewable source handoff, not preparation or a unit-test proxy for native acceptance.

## Command, field observations and derived state

`PatchJobDetails` binds company/shop/Job/request IDs, SHA-256 of the complete immutable signed create-operation bytes, a typed `JobDetailsPatch`, and an immutable map from changed `JobDetailField` values to their sorted observed operation heads. A typed resolution-field set is a subset of changed fields. The five registry entries own wire key, label, validation and baseline decoding. They do not accept arbitrary property names or JSON writes.

Reuse `FieldPatch<T>` omitted/set semantics. Customer, location, job number and notes accept explicit null; omission leaves that field untouched. Status uses a typed active/archived enum and cannot be null. The initial byte bounds are 1,024 UTF-8 bytes each for customer/location, 256 for job number and 16,384 for notes. Canonical operation bytes remain at most 65,536, including authorization/signature. Never truncate values. Empty text and explicit null remain distinguishable in the domain; the editor explicitly clears a nullable field.

The canonical `job.details.patch@1` operation contains only changed fields, each with its own value and observed parents. Signatures bind the exact field set, per-field observations, resolution intent, creation digest, stable identity, original user/device and explicit authorization. A parent must be a verified details operation for the same company/shop/Job/creation which actually changed that field. The transfer dependency set is the sorted union of these parents plus the immutable creation dependency. Bound each field frontier and the union to 32 parents. Missing dependencies refuse transactionally; frozen authenticated inventories order creation and parents before children. Keep the current no-relay dependency eligibility closure, including transitive descendants and the already-held foreign-parent case.

Each field reduces over its own causal edges. Omitted-field conflicts never resolve as a side effect of another edit. Equal concurrent values can display once while preserving every operation. Differing maximal values retain all attributed candidates. Find the last agreed value by walking common ancestry backwards until the maximal common field values agree; test nested earlier conflicts rather than copying the Job-line reducer's different fallback.

Ordinary stale edits can create conflicts. Local resolution uses the captured displayed frontier, refuses if that field acquired an unseen head before admission, and never refreshes parents behind the caller. A valid incoming resolution concurrent with a locally unseen edit remains in history and cannot hide that alternative. Resolution affects only explicitly changed fields.

Store append-only details history separately. Extend `CompanyJobView` with typed derived details and field conflicts. Never update the immutable Jobs row or change existing `CompanyJobs` operation/projection/receipt/audit bytes or `CompanyJobNames` signed bytes. Existing whole-row creation validators remain strict.

## Authorization and protected atomicity

Add explicit `editJobDetails` capability issuance for a newly authorized company and the normal signed Join intersection. Both original user and original device must hold it. Preserve existing signed create-only and create/name membership profiles, old owner fact profiles and their rights. They can still read current company Jobs but cannot author details; UI explains unavailable permission. No local migration edits a signed grant and no grant-upgrade feature is included.

Expand strict member capability maximum from two to three known entries and add the exact new recoverable owner profile while retaining all existing accepted profiles. Include `company_protocol.dart`, `company_membership.dart` and `company_join.dart`; this is not createJob/renameJob implication.

Add explicit outgoing/incoming details command families, signing/assertion domains, receipts, receipt lookup, witness, commit validation, held-peer incoming validation, sealing and reconciliation branches in the existing installation kernel. Family keys are disjoint from create/name requests and ACKs. Before beginning a protected intent, verify the saved creation receipt and every dependency's typed receipt/signature. Reuse the existing top-level SQL transaction, installation-binding lock, protected CAS, witness, final live checks and recovery rules. No raw signing API, skip flag or smaller security check.

Exact retry binds the same request, field set, values, parents and resolution flags and returns its saved receipt without mutation. Changed content under that request refuses. Incoming append/audit/derived conflict state/receipt commit atomically, preserving the original author. Pre-commit failure yields no success ACK; post-commit interruption reconciles the committed receipt before acknowledgment.

## Schema, protocol, capacities and backup fences

Schema **9 to 10** adds `company_job_details` and `company_job_detail_peer_acks` transactionally. The history stores scoped identity/request, operation/command commitments, canonical signed operation, distinct receiver receipt key/bytes, original audit and outgoing flag. The ACK table uses the existing exact peer/device/store binding shape, scoped to this family. Existing tables and signed rows are unchanged. Update Drift registration/generated output and migration tests.

Use strict `company.job.sync@3`. Dispatch create, name and details explicitly throughout inventories, descriptors, record lookup/admission, ACK domains/tables, cached confirmation, held checks and confirmed-peer counts. Unknown kinds must not fall through to create. A details descriptor binds exact signed payload digest/length, creation, the changed-field set and the sorted parent union. Do not repeat per-field parent lists in the descriptor; validate the compact summary against the signed payload after reassembly and measure five fields sharing 32 parents against the existing 4,096-byte descriptor/ACK and page caps. Unsupported protocol peers refuse before unsafe exchange and cannot report convergence.

Keep the existing aggregate inventory limit **1,024 records**. Preserve the 512-create bound and use a **shared 512 mutable-history budget across name plus details**, with a shared 128 mutable operations per Job. Existing name-only stores remain admitted unchanged. All new local/incoming name/details admission observes the aggregate budget; exact verified retries remain allowed at capacity. Existing over-capacity or missing/unverifiable state refuses honestly rather than truncating or silently dropping history. Do not add another independent 512-record allowance.

Keep frame/chunk limits, adaptive page validation, aggregate page bytes, request retirement, disclosure/revocation guards, 128 shared received nonces and five-minute Pair lifetime unchanged. Calculate progress from both frozen operation sets and distinct family ACKs; budget exhaustion/unsupported dependencies remain incomplete.

Update `company_store_markers.dart` exact table/column fences, company-bootstrap fresh/preflight paths, backup schema/header/table fences and existing recovery checks. A separately frozen schema-9 app must refuse a real schema-10 store without mutation. No old pending create/name intent or receipt is reinterpreted as details. Test migration with old evidence and exact retry.

## Editor and behavioral acceptance

The editor marks dirty fields and captures each field's observed frontier when opened. Save signs only those fields. After an uncertain result, retry uses the identical pending command; changing text requires resolving that pending outcome first. Field conflicts show original user/device/operation and values, including explicit clear. Resolve one field through the same command while retaining every other field's conflict. Archived Jobs remain inspectable/editable; restoration means a normal status edit to active, not tombstone resurrection.

- [ ] Production command and widget tests save all five fields, distinguish omitted/null/text, and archive/reactivate while creation/name bytes remain identical.
- [ ] A changes customer to Acme and status to archived; B independently changes notes to Gate 3. One Sync Now retains all three changes on both devices. Repeat is 0/0 without history or unnecessary revision changes.
- [ ] Both arrival orders preserve different notes, equal-value concurrency, nested last-agreed values and independent field resolution. Stale ordinary edits remain visible; stale resolution cannot hide unseen alternatives.
- [ ] Exact retries, changed-request collisions, missing creation/parents, already-held foreign dependencies and transitive blocked descendants behave correctly; unrelated eligible work continues.
- [ ] Wrong scope/baseline, missing/revoked permission, stale authority, tampered operation/receipt/dependency, unsupported version and oversized/capacity input refuse without mutation or false ACK.
- [ ] Pre/post-commit interruption, restart reconciliation and lost acknowledgment preserve committed truth. Existing safe Close/drain/retry remains supported.
- [ ] Focused domain, sync, widget, schema-9 migration, frozen-old-binary refusal and backup/recovery tests plus scoped analysis pass. Root selects any broader gate from affected risk after focused GREEN; independent source/security review addresses findings.
- [ ] After API/source freeze, root and Mac use the existing actual-widget native flow for the affected mixed-field, conflict, repeat/interruption and cold-readback acceptance. Both artifacts are qualified before launch; normal sign-in and fresh Pair/Match/one mutual Verify/both explicit Enables remain required. Keep source tests, native proof, current CI, readiness and merge separate.

## Rollback and delivery

Keep d041/j61, old fixtures, binaries and manifests frozen. New schema/protocol state is append-only and cannot be downgraded for an older binary. Retain receipts/history if the UI feature is disabled. No history/tombstone compaction, real-shop data, shared-user provisioning, mesh/mobile/radio work or merge is included. Root creates the reviewed draft PR stacked on #115 and updates canonical issue/memory records. A ready flag requires this increment's own tests, independent review and exact-build native evidence.

A new ordinary write must not collapse divergent values in its referenced field frontier: both outgoing and incoming admission reduce those parents and require explicit resolution intent if values differ. Equal-valued parents can be superseded by an ordinary edit. Exact verified retries run before current-frontier freshness checks.
