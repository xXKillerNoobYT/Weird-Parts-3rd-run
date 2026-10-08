# Offline company sync foundation and extension plan

Date: 2026-10-08. Governing plan: [issue #33](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/33). This documentation increment: [issue #45](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/45).

**Goal:** Give authorized company devices a durable offline database and one manual Sync Now that exchanges changes in both directions. Later features reuse its identity, permissions, history, validation, compatibility, and delivery rules.

**Architecture direction:** Typed domain operations over an immutable, byte-preserving operation store. Derive local views only from supported, authorized operations. Separate custody from semantic application and business acknowledgment. This is a recommendation for a discriminating experiment after the current native gate, not an implemented engine or selected library.

**Tech stack:** Existing Flutter and Drift/SQLite. No new dependency, radio implementation, wire encoding, signature suite, or CRDT library is selected.

**Design inputs:** [Foundation spec](../superpowers/specs/2026-09-11-parts-foundation-design.md), [five-design comparison](architecture-comparison.md), [foundation scenarios](scenarios-foundation.md), [workflow scenarios](scenarios-workflows.md), and [roadmap](../../roadmap.md).

**Global constraints:** Synthetic isolated data only. Preserve each builder's source and evidence. No real-shop migration, legal acceptance, approval-control automation, merge, or release. Do not begin Phase 5 implementation until issue #39's exact-candidate native gate passes. Later feature scenarios do not become predecessors to that gate.

**Review focus:** Lost edits, false acknowledgments, company-data disclosure, unknown-field loss, credential cloning, stale-restore replay, deletion resurrection, and misleading capacity or platform claims.

## Current evidence and its limits

Repository main was observed at `a4546d3ae30030bb8884ab31db4167408d1e1ec2`. Feature evidence below refers to draft [PR #36](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/36), candidate `95a06a96994ec03014a37075ce4406f183e3c12e`. Source and pending PR behavior are not assumed merged into main.

| Evidence | Recorded result | Limit |
| --- | --- | --- |
| Encrypted backup recovery on isolated Windows and Mac installations | Admitted PASS at recovery parent `1a4459d`; backup implementation unchanged in the combined candidate. IDs, relationships, supported schema, photos and local identity checked. Bad password, damage and future schema reject safely. | Synthetic data only. Repeat preservation and recovery before any real-data migration. |
| Actual Mac-to-Windows whole-shop replacement and normal restart | Admitted PASS at `dbedcca736e5cc942027236a01f28cdf8352c11c`. Thirteen domain tables, fourteen rows, sixteen references, tombstone, full local profiles and photo evidence. | One-way replacement of a tiny fixture. No two-way merge, company membership, capacity or mobile proof. |
| Nearby lifecycle fix at candidate `95a06a9` | RED `5975f94865be14ac5753c674467579fe58fab7cb`, unchanged regression tests GREEN. Independent source review, Mac 265 tests, Windows 263 tests, clean analyses and native builds. | Windows has one symlink privilege skip and a separate POSIX-only exclusion. Tests and builds do not replace actual affected-flow acceptance. |
| Fresh configured test installations | Mac and Windows actual processes, configured PIN gates and pre-leg schema/domain/profile/photo baselines observed. Both Nearby pages discover the other device. | Baseline and discovery only. No fresh Pair or transfer is claimed by this document. |
| Exact-candidate same-open-page receive then send | Pending in [issue #39](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/39). | Three explicit one-way replacements are required. They still do not count as genuine two-way sync. |
| Company enrollment, portable users, semantic two-way sync, unknown-data carriage, MCP and later modules | NOT_IMPLEMENTED or NOT_VERIFIED. | Scenario rows, diagrams, architecture ratings and preparation are not executed tests. Android and iOS support remains unverified. |

Private native receipts retain exact builds, process identities, collector hashes, complete rows, profiles, assets and test logs. Shared records omit credentials, raw databases and pairing codes. Current status belongs in issues #33 and #39; this dated evidence is not a live readiness badge.

## Delivery stages

Scenario stages describe delivery, not test results. Every newly proposed scenario is **NOT_RUN**. The matrices contain thirteen areas with fifteen scenarios each. Their 195 rows are a planning inventory, not 195 current release gates.

| Stage | Work pulled into that stage | Completion signal |
| --- | --- | --- |
| F0, current Phase 4 closeout | Finish issue #39. Preserve exact processes and Nearby pages through Mac to Windows, Windows to Mac, then Mac to Windows. Fresh pairing comparison for each leg. Explicit PIN and replacement acceptance. Normal restart after the three legs. | Both operators and an independent reviewer admit complete per-leg domain, relationships, tombstone, full local profile, settings boundary, physical photos and final restart evidence. PR #36 stays draft until its required gates pass. |
| F1, Phase 5 foundation | Company/device enrollment and revocation, portable user identity and protected offline authentication, shared validated commands, durable operations/outbox/inbox, typed merge registry, tombstones, receipts, compatibility negotiation, bounded changes-only Sync Now and visible Sync Issues. | A minimal registered catalog/job command path in actual isolated Windows and Mac test builds proves offline edits, both-direction exchange, restart, correct records or visible conflicts, and duplicate-free retry. Minimum enrollment and portable-user sign-in/permission behavior must pass. Unauthorized or revoked peers get no protected data under the chosen freshness policy. Recovery passes. Broad migration of existing editors remains F2. |
| F2, gradual usage migration | Migrate all existing Parts and Jobs edit paths through the already proven foundation first. Preserve local behavior and rollback. Complete their user-facing integration, then add Notebook through the same registered operations and conflict contract. Baseline local MCP uses those commands and permissions. | Each small increment passes domain/compatibility tests and actual user workflows. Native tests repeat where the increment changes platform, transport, persistence, enrollment or recovery boundaries. |
| R, later layers | Location inventory and master authority, receiving/returns/restocking, supplier tools, permits, scheduling, fleet and reports. Router-free Bluetooth or direct Wi-Fi, partner sharing and internet peers. Device-native AI and audible assistance. Scripted diagnostic collection and approved submission retain issue #40's own scope. | Separately scoped issues, deliberate permissions and measurable acceptance. None is silently added to F0. |

The baseline MCP contract is [issue #37](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/37), company users and PINs are [issue #38](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/38), and diagnostic reports are [issue #40](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/40). Existing notes #41 through #44 remain source material for later scoped decisions. This plan does not authorize every idea in them as immediate feature work.

## Shared data contract

Company is the security namespace. Shop or location is a scoped place within that company. User is a portable human identity. Device is one enrolled installation with its own credentials, belonging to one company. A second company cannot join that installation by changing an active-company parameter. Equal company ID strings or knowledge of a catalog PIN grant no membership.

The company catalog names parts that can be sourced. It is not warehouse inventory. Catalog, taxonomy, brands and suppliers retain company-wide stable IDs. Jobs, lines, requests, future notes and blocks retain their own IDs and references. Names, row positions and display paths never identify records. Category to Type to Variant remains required.

| Shape | Required distinction |
| --- | --- |
| Entity reference | Company, entity kind, permanent entity ID and entity schema. Job/location scope where relevant. |
| Authored operation | Permanent operation ID, entity/field/line/block target, original user and device, installation generation, causal base/dependencies, atomic group, required semantic capabilities, authorization evidence and content commitment. |
| Carrier state | Original authenticated bytes, verified outer scope, bounded storage and resume state. Carrier identity is a separate receipt and never replaces authorship. |
| Apply outcome | Applied, already applied, waiting for dependencies, unsupported capability, conflicted, or rejected. Each reason survives restart. |
| Delivery evidence | Saved locally, stored by a carrier, applied by a recipient, accepted by the intended shop, and explicitly acknowledged by a human are separate facts. |
| Conflict and resolution | All alternatives and authors, covered causal heads, questions, answers, authorized resolution and history. A later unseen alternative is not resolved by an earlier answer. |
| Asset | Portable asset ID, byte digest, versioned manifest and references. Another computer's file path is never a portable identity. |

Capture edits at the command boundary. A local transaction commits the operation, its validated local effect and its outbox entry together. Incoming application commits the effect, applied-operation marker, audit and receipt intent together. Durable custody must precede a custody acknowledgment. Files and resumable chunks need an explicit journal and committed manifest; SQLite cannot make an unrelated file write atomic by itself.

An operation ID with identical authenticated content is a retry. The same ID with different content is an integrity error. Distinct IDs with similar wording or quantities are independent actions until an authorized review says otherwise. Missing causal dependencies stay visible. Wall-clock timestamps describe observations; they never choose a winning edit.

## Automatic combination and explicit disagreement

Independent physical actions accumulate once by operation identity. Ten requested with actual pickups of six and seven means thirteen picked up and three excess. Replaying either receipt leaves thirteen. Workers do not need to split a request before leaving. Pickup, custody, delivery and an actually received return are separate events. A return proposal adds no stock.

Those logistics examples prepare the operation contract. They do not require a warehouse module in F1. Existing scalar `shopPullQty` is a legacy aggregate, not historical proof of individual pickups. Migration must label a baseline honestly instead of inventing users or events.

Structured edits merge only when their declared independent fields and invariants compose. Different fields can still be coupled, such as quantity and unit. Concurrent incompatible edits and edit-versus-delete keep attributed alternatives. A tombstone prevents ordinary visibility from being restored by a stale peer. An explicit authorized restoration is a new operation, not an accidental replay.

Notebook later uses stable blocks and editing units. Safe independent changes can combine automatically. Conflicting intent remains visible in separate highlighted, attributed bubbles for all authorized readers. Questions follow the original editing users onto any authorized company device. Both answers remain history. An authorized manager can resolve remaining disagreement under an explicit company policy. An unavailable editor or conflicting manager decisions need a visible exception, not a clock winner.

AI may later explain or propose wording. It does not fabricate physical actions or silently decide semantic truth. Deterministic and manual paths remain usable without a model or internet. Audible preferences are local. A disconnected device cannot alert about a change it has not received.

## Mixed app versions

Version application/UI capability, local database schema, transport and envelope framing, entity/operation semantics, backup format, and authorization policy independently. The five-design comparison expands these boundaries. A single app version string is insufficient.

| Encounter | Safe behavior |
| --- | --- |
| Known compatible fields, older UI | Apply supported operations through the same validators. Submit narrow field patches. Never rewrite a whole partially understood entity. |
| Unknown optional field or entity | Preserve exact original bytes and explicit dependencies. Carry them only when understood outer authentication, scope, required carrier capabilities and quotas permit it. Show pending/incomplete state where relevant. |
| Unknown required business semantics | Do not apply or assert business acceptance. Supported opaque custody may be permitted by the known carrier contract. Hold coupled atomic groups together. |
| Unknown required authentication, company authorization or envelope semantics | Reject before protected company data disclosure or accepted custody. Do not downgrade to backup replacement. |
| Missing or unsupported dependency | Retain a bounded waiting state and reason. Do not invent a complete projection or stock availability. |
| Full storage or work budget | Refuse further custody visibly before acknowledgment. Keep already acknowledged bytes. Resume with verified IDs, manifests and holes. |
| A binary predating the carrier contract | It may require upgrade before participating. No promise can retrofit unknown-data carriage into existing unsupported binaries. |

Capabilities describe read, author, resolve, relay and apply separately. Derive advertised capabilities from installed registered contracts. Capability does not confer permission. The parser validates lengths, identities, hashes, reference types, quantities, units and critical flags before mutation. No executable adapter is downloaded from a peer.

Preserving unknown bytes is useful but not unlimited forward compatibility. Unknown authentication cannot be safely interpreted by a generic database. New required invariants need a new required capability or semantic generation. Unknown bytes, tombstones and dependency groups must survive backup, migration, supported-field edits and upgrade without silent stripping.

Protocol Buffers documents unknown-field preservation in binary form and losses caused by JSON conversion or rebuilding messages field by field. This is a design lesson, not a selected serialization format. [Official unknown-field guidance](https://protobuf.dev/programming-guides/proto3/#unknown-fields).

## Users, PINs and device credentials

Users and their permitted offline sign-in must work across authorized company devices. Public user/profile/role changes and protected user-authentication provisioning are different data classes. The latter needs a versioned, encrypted, permissioned company authentication contract with rotation, revocation, stale-device handling and recovery. Its exact mechanism remains a security design decision in issue #38.

That design must bind the authenticated user and permitted session to the operation's committed bytes, including its entity, action and causal context. A device signature proves which installation asserted a user, not independently which human touched a shared tablet. Define the allowed trust and compromised-device threat model honestly. Commands and MCP must not accept an arbitrary caller-supplied author ID. Specify session scope, expiry, replay prevention, reset and stale offline authorization behavior. Exercise substituted users, expired or replayed sessions and MCP impersonation through USERS-02, USERS-12 and MCP-10.

The portable-authentication threat model must include offline guessing against stolen app data, a stolen backup and exported protected authentication state. UI attempt limits alone do not protect an offline verifier. Review encryption, key custody, provisioning scope and recovery together before choosing the mechanism. This is a dependent F1 security decision, not a new F0 blocker.

Never transmit raw PINs in business records or logs. Device private keys stay local and are never cloned through sync or backup. A protected company-user authentication mechanism must not be confused with cloning a device's enrollment credentials. An unconditional ban on any portable user-authentication state would contradict the user's required cross-device sign-in, so that gap must be resolved explicitly before dependent code.

Keep today's local catalog PIN gate until the reviewed migration exists. Development authorization covers user-supplied public PINs only in isolated synthetic on-device installations. Do not repeat the same project permission request or record PIN values in shared documentation. Mandatory computer-control restrictions remain separate from project authorization.

Known revocations and authority epochs cannot roll backward with business restore. Reset does not enroll a device. A device with no valid company authority must rejoin through an authorized approver before receiving company data. A disconnected peer cannot know an unseen revocation; choose an explicit stale-membership policy and do not claim immediate global revocation.

## Extension contract and actual source boundaries

Paths in the current column exist at candidate `95a06a9`. Paths in the proposed column are suggestions, not created source or assigned ownership.

| Current boundary | Required change or proposed boundary | Proof before adoption |
| --- | --- | --- |
| `app/lib/data/app_database.dart` and `data/tables/` | Versioned migrations preserve every stable ID/reference and separate device-local security state from business projections and replication state. | Old-schema populated fixtures, unsupported-version refusal, rollback and exact data comparison. |
| `app/lib/data/daos/jobs_dao.dart` and `app/lib/data/daos/parts_dao.dart` | Route user actions through validated domain commands. Persist fine-grained operation intent with the effect. Preserve existing UI behavior while migrating callers. | Command validation, permission denial, transaction fault injection and actual Parts/Jobs usage. |
| `app/lib/features/pin/pin_service.dart` and local device profile | Retain today's gate, then introduce issue #38's portable users and separate enrollment/authentication service. | Cross-device user sign-in, role denial, credential rotation/revocation and reset/recovery rejection. |
| `app/lib/features/nearby/nearby_page.dart`, controller, protocol and codecs | Preserve one-way replacement as a clearly named operation. Add a distinct sync coordinator and transport-independent operation exchange. | Both directions in one Sync Now, interruption/retry, same-page lifecycle and no accidental restore call. |
| `app/lib/features/backup/` and `app/lib/app.dart` restore binding | Back up business history, unknown bytes, assets and consistent applied state. Restore never clones enrollment or rolls back known security state. | Bad password/damage/future schema, older-state restore, stale receipt recovery and revoked-device denial. |
| No current semantic engine | Proposed `app/lib/domain/` and `app/lib/features/sync/` own command validation, entity registry, causal merge, durable inbox/outbox, conflicts, compatibility and receipts. Final paths follow implementation review. | Same operations through UI and local MCP, deterministic reordered/replayed replicas and crash-safe commit boundaries. |
| No current Notebook engine | Later registered job/general notes and stable blocks reuse the common command and sync path. Evaluate finer text merge only if its semantic and native tests pass. | Concurrent edit/delete, detailed alternatives, editor questions, manager resolution and usage rollback. |

Each future feature declares stable entity and operation IDs, company/scope permissions, references, quantity/unit rules, causal editing units, merge policy, tombstone and resolution behavior, required versions/capabilities, migration, asset policy, audit and bounded-resource behavior. Add shared conformance fixtures before UI code. A Notebook row is not automatically syncable because it has a company ID.

Ordinary additions that satisfy this contract can rely on the shared automated compatibility and convergence suite. Physical tests remain necessary when transports, storage/transaction boundaries, native credentials, application lifecycle, media, protocol negotiation or supported platform behavior change. The goal is fewer redundant device checks, not a promise that all future features need no device verification.

## Proof and measured limits

After F0, start with the smallest isolated three-replica experiment. Two replicas author different fields and independent actions offline. An older carrier forwards exact supported envelopes and unknown optional content. A capable recipient applies supported changes, preserves conflicts and returns distinct receipts. Include bad authorization, unknown required semantics, duplicate IDs with differing hashes, missing parents, stale deletion, restore and crashes around each commit boundary. Stop a candidate on a hard safety failure.

Then exercise one actual authorized Windows and Mac pair plus an unauthorized synthetic peer. Use a minimal registered catalog/job command path in isolated native test builds, with minimum enrollment, portable-user sign-in and permission checks. This proves the foundation lane; F2 must separately migrate and validate the complete existing Parts and Jobs editors. Test both offline edits, concurrent same-field edits, edit/delete, delete followed by stale restore, restart, dropped acknowledgment, interrupted batch and repeated Sync Now. Compare complete records/relationships, operation IDs, tombstones, conflict alternatives, full local identity and asset hashes. Admit unresolved conflicts only when visible and durable. Android and iOS each need their own actual acceptance before being called supported.

Use increasing synthetic record and history sizes after correctness. Proposed experiment tiers are 1,000, 10,000 and, only when safe, 100,000 records. These are workloads to try, not capacity claims. Record hardware, OS, exact build, schema/protocol/contract versions, record and history counts, asset bytes, batch/chunk budgets, dependency depth, peak memory/disk, transfer/apply time, retry behavior and limit refusals. Report the largest actually measured passing workload and observed failure boundary. No infinite storage or permanently offline peer promise.

Tombstone/checkpoint retirement needs a supported-participant and rejoin policy. A retired or excessively stale device must reconcile from an admitted checkpoint and review stale edits. Finite storage, unlimited historical losslessness and indefinitely absent peers cannot all be guaranteed.

## Migration, review and rollback

Before any schema change, record exact source/build/schema and isolated installation ownership. Preserve an encrypted backup and prove restore. Export old populated schema fixtures and verify IDs, references, tombstones, assets and unknown bytes after migration. Drift's tooling distinguishes schema validation from checking preserved data, so both are required. [Official migration-testing guidance](https://drift.simonbinder.eu/migrations/tests/).

Use one issue and owner per atomic branch. The Mac retains Nearby/native ownership and Windows retains its integration/native ownership. New domain boundaries and platform lanes need explicit readback before concurrent writers start. Each PR states tested commit/build, commands, actual platforms, skipped or excluded cases, unresolved policy choices, risks and rollback. Independent review challenges data-loss and authorization assumptions. Draft status remains until that PR's gates pass.

Rollback can restore a local projection/checkpoint while preserving immutable acknowledged operations and current security state. It cannot retract business effects already accepted by another device. Corrections to shared history use authorized compensating operations. A restored installation must prove sequence continuity or obtain a fresh authorized operation generation; no reused ID with different bytes.

## Decisions scoped to dependent work

| Decision | Owner and affected stage | Current state |
| --- | --- | --- |
| Enrollment approvers, removal and lost-admin recovery | Company owner, before F1 enrollment | Open. Pairing alone is not approval. |
| Offline membership freshness and authority for unseen historical edits | Company owner with security reviewer, before privileged F1 apply | Open. No instant revocation claim while disconnected. |
| Portable user/PIN authentication and credential rotation | Issue #38 owner with security review, before cross-device sign-in | Open. Public profiles alone do not meet the requirement. |
| Conflicting editors, unavailable editors and manager authority | Product owner, before conflict-resolution commands | Original editors and manager escalation direction accepted. Detailed authority/concurrent-manager policy open. |
| Tombstone, custody/history retention and retired-device rejoin | Sync and company owners, before compaction or expiry | Open. No silent deletion of acknowledged data. |
| First-milestone photo apply versus pending-media states | Product and sync owners, before F1 media acceptance | Open. Preserve portable identity and honest status either way. |
| Carrier read/relay scopes and metadata exposure | Company owner with security review, before opaque forwarding | Open. Company membership alone is not every permission. |

These are not seven new F0 blockers. Resolve each before its dependent implementation, using a scoped needs-user issue only when an actual human product decision is required. Continue independent evidence and planning work meanwhile.
