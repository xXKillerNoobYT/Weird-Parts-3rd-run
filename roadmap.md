# Weird Parts / WiredPart — Roadmap

Living tracker. End goal is saved under `docs/end-goal/`; details get worked out as we build.

## Product north star

**WiredPart** — outdoor / field construction ops app (jobs, notebooks, parts, warehouse, scheduling, chat, fleet, people/Hats, etc.).

**Foundation first.** Authorized company devices keep a durable offline database, portable company users, Parts and Jobs, genuine two-way Sync Now and encrypted recovery. Baseline local MCP uses the same validated commands and permissions. Notebook follows Parts and Jobs. No internet or cloud is required.

The current plan is [issue #33](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/33), extended by [the offline sync and extension plan](docs/sync/foundation-plan.md). [Issue #45](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/45) contains the scoped five-design and 195-scenario documentation increment. Those scenarios are proposals, not passed tests or immediate release gates.

Reference drafts (rough, not binding detail yet):

- `docs/end-goal/DESIGN-AUDIT.md` — modules, UI standards, build workflow
- `docs/end-goal/MERGE-PLAN.md` — Hats, accessibility, screen merge order
- `docs/end-goal/PARTS-MODEL.md` — parts / warehouse / JPO / restock / returns
- `docs/end-goal/WiredPart.dc.html` — UI prototype
- `docs/end-goal/Panel Schedule Builder.dc.html` — panel schedule prototype
- `docs/end-goal/screens/` · `docs/end-goal/screenshots/` — visual references

---

## Locked decisions (foundation)


| Decision | Choice and current evidence boundary |
| --- | --- |
| Users | Company crews and shops. Company, location, user and enrolled device are separate identities. |
| Platform targets | Windows, Mac, Android and iOS. Current native evidence covers isolated Windows and Mac only. Mobile support is unverified. |
| Stack | Flutter and Drift/SQLite. Current local schema is v2. |
| Current Nearby draft | Wi-Fi on the house LAN, UDP discovery port 41000. Pair, Match, Send this shop and Accept shop perform one-way whole-shop replacement. It is not merge sync. |
| Foundation sync | Changes-only, bounded and recoverable. One Sync Now exchanges changes in both directions, with atomic tracking, receipts, tombstones and visible conflicts. Not implemented or verified yet. |
| Later radios | Router-free Bluetooth or direct Wi-Fi can use the same transport-independent rules after the core. No radio or hybrid platform support is claimed now. |
| Company enrollment | Each installation belongs to one company. Create Company or Join Existing Company through an authorized enrolled approver. Join grants permitted company-network participation, not trust in every nearby app. Reset cannot bypass enrollment. |
| Users and PINs | Users must sign in offline on authorized company devices after protected, versioned user-auth provisioning. That security design is open in issue #38. Keep today's local catalog PIN gate until reviewed migration. Never clone device private keys. |
| Permissions | Company and user authorization are foundation requirements. Full Hats administration remains later. Catalog writes remain PIN-gated. |
| Catalog | Company-wide sourceable parts, distinct from per-location stock. Stable IDs and Category to Type to Variant remain required. General part identity, optional brand versions and supplier listings stay. |
| Job lines | Requested and shop-pull quantities remain separate from supplier order splits. Later actual pickups and returns need attributed events, not invented history from aggregates. |
| Photos | Portable asset IDs and hashes. First two-way milestone's media-versus-pending policy remains open. Current one-way photo proof does not settle that policy. |
| MCP and AI | Baseline local MCP in issue #37 shares UI validation, permissions and audit. Optional device-native AI is later and retains a non-AI fallback. |
| Auto sync | Phase 7, after dependable manual two-way sync. |
| Partner and internet sharing | Later, explicitly selected data, permissions and provenance. Neither is needed for the offline foundation. |
| Scope | Resolve module details when pulled into work. A future scenario does not become an immediate foundation blocker. |


---

## Where we are

- [x] Brainstorm started; empty repo + foundation spec
- [x] End-goal draft imported to `docs/end-goal/`
- [x] Approach chosen: Flutter + SQLite
- [x] Foundation design spec written (`docs/superpowers/specs/2026-09-11-parts-foundation-design.md`)
- [x] User review of foundation design spec
- [x] Implementation plan for Phase 1 (`docs/superpowers/plans/2026-09-11-phase-1-local-core.md`)
- [x] App scaffold
- [x] **Phase 1 — Local core** complete (`feature/phase-1-local-core`)

**Current focus.** Phase 4 closeout under [issue #39](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/39) and draft [PR #36](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/36). Main was observed at `a4546d3ae30030bb8884ab31db4167408d1e1ec2`. The feature candidate is `95a06a96994ec03014a37075ce4406f183e3c12e`; it is not assumed merged.

Historical isolated encrypted recovery and one Mac-to-Windows replacement with restart passed. The fresh candidate has build, unit-test, analysis, configured-baseline and discovery evidence. Its required three-leg same-open-page native acceptance is still pending. Phase 5 implementation remains on hold until that gate passes. See the [dated evidence and limits](docs/sync/foundation-plan.md#current-evidence-and-its-limits).

---

## Foundation build phases

### Phase 1 — Local core

- [x] Flutter multi-platform project
- [x] SQLite schema: jobs, job lines, catalog (part / brand version / supplier), taxonomy, device ID, sync metadata columns (`revision`, `modifiedAt`, `deletedAt` tombstones) — no separate change-log table
- [x] Jobs CRUD + job parts list (general part by default; optional brand; needed · shop pull · **order splits** by supplier; soft-delete remove)
- [x] Catalog browse/add/edit (name / description / UOM / default supplier / active) + brand versions / listings; taxonomy maintenance (categories, styles, types, devices, brands, suppliers)
- [x] Editor PIN gate for catalog writes
- Historical implementation note. `AppSettings`, the local PIN verifier and device credentials remain local. Phase 5 must separate business data from protected portable user authentication; generic settings replication is not that design.

### Phase 2 — Catalog tree, Variance, job qty

Isaac’s shop walk (approved plan). Old “search, filters, media” wording is replaced.

- [x] File-tree catalog + Types listing share one tree (Category → Type → Variant → brand or general → Variance → part number)
- [x] Category is a folder, not a part; hang general parts on the tree (no brand)
- [x] Devices chip gone; **Variance under Brands** (main + other options; colors per brand + own MPN)
- [x] Job line: **Requested**, Split (shop / Supply A / Supply B / …), **Left to Pull/Order**
- [x] Search / filter that respects the tree
- [x] Part photos (compress, store, attach) — after the tree
- [x] Custom part → promote to catalog (editor) — after the tree (#6)
- [x] Catalog remove (parts + empty folders, PIN) + local reset / wipe all data

### Phase 3. Encrypted backup

- [x] Encrypted export and import implementation is present in main.
- [x] Backup date and source device are part of the backup flow.
- [ ] Clear the current combined recovery/Nearby PR's remaining gates before calling that candidate ready.

Isolated recovery proof is recorded in issue #33 and PR #36. Repeat safe backup and restore before any real-shop migration. Bad passwords, damaged files and unsupported schemas must leave existing data unchanged.

### Phase 4. Nearby one-way engineering gate

- [x] Historical actual Mac-to-Windows whole-shop replacement and restart proof.
- [ ] Finish exact-candidate Mac to Windows, Windows to Mac, then Mac to Windows without recreating the receiving Nearby controllers.
- [ ] Fresh verified pairing, per-leg domain and local identity checks, photos and final restart admission by independent review.

Keep [PR #29](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/29) and PR #36 draft until their own gates pass. No merge is authorized by this plan. One-way replacement is distinct from genuine two-way merging.

### Phase 5. Company-scoped two-way foundation

Begin implementation only after the current issue #39 gate passes.

- [ ] Separate company, location, portable user and enrolled device identities. Enforce enrollment, removal, recovery and the chosen offline freshness policy.
- [ ] Resolve protected company-user authentication and PIN rotation in [issue #38](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/38).
- [ ] Shared validated commands commit edits with outgoing operations. Incoming apply, deduplication, audit and receipt intent commit atomically.
- [ ] One changes-only Sync Now exchanges both ways. Bound batches, dependencies and custody; persist resumable progress where needed.
- [ ] Preserve causality, IDs, relationships, independent actions, tombstones and attributed conflicts. Original editors answer questions; authorized manager resolution preserves both answers.
- [ ] Negotiate protocol and semantic capabilities. Preserve unknown data only under understood authenticated carrier contracts; fail closed on unknown required authorization.
- [ ] Define photo apply and pending-media states. Keep device credentials and unrelated local settings out of business sync.
- [ ] Provide baseline [local MCP operations](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/37) through the same permissions, validation and audit.
- [ ] Verify actual offline edits, both-direction exchange, restart, conflict/delete, stale restore, retries, interruptions and rejected devices. Measure larger synthetic limits and verify each mobile target separately.
- [ ] Add extension conformance fixtures so later registered entities reuse the core. Repeat native tests for changes to platform, persistence, transport, credentials or lifecycle boundaries.

Then migrate existing Parts and Jobs usage gradually with rollback. Notebook is next. The [scenario matrices](docs/sync/scenarios-foundation.md) and [workflow scenarios](docs/sync/scenarios-workflows.md) describe proposed acceptance, not completed work.

### Phase 6. Additional hardening and scale

- [ ] Broaden measured scale, platform stress and long-duration multi-device tests beyond Phase 5's mandatory correctness, permission and recovery acceptance. Those safety checks must already pass in Phase 5.

### Phase 7 — Auto / background nearby sync (later)

- [ ] Auto background syncing between known/paired nearby devices (still local-first; no internet required)
- [ ] User controls: enable/disable, which peers, battery/Wi‑Fi preferences
- [ ] Safe with conflicts: never silent discard; surface issues like manual sync

---

## End-goal backlog (later — detail while building)

Do **not** fully spec these now. Pull from `docs/end-goal/` when a phase starts.

- [ ] Hats data layer + admin (roles from MERGE-PLAN; confirm with Bob)
- [ ] Warehouse stock, locations, movements
- [ ] Restock orders / receiving / returns
- [ ] Notebook after Parts and Jobs usage migration, using the foundation contract
- [ ] Dashboard, clock and panel schedule
- [ ] Scheduling, chat, fleet, tools
- [ ] People, reports, office, full settings
- [ ] Outdoor a11y pass (56px actions, photo/voice capture)
- [ ] Preferred brand on a part, and/or preferred brand for a job (after general-part + optional brand works)
- [ ] Auto / background nearby sync (Phase 7 — after two-way manual sync works)
- [ ] Router-free Bluetooth or direct Wi-Fi transport, including explicit pending-media limits
- [ ] Selected partner-company or future supplier-app sharing, with permissions and provenance
- [ ] Scripted redacted diagnostics and reviewed submission under issue #40
- [ ] Optional on-device AI assistance, with a non-AI fallback
- [ ] Optional internet peer and company cloud

---

## Open items to resolve when we hit them

From end-goal drafts — park here, decide in context:

1. Hats role set (Admin, Office, Foreman, Journeyman, Apprentice, Warehouse, …)
2. Part numbering + color-as-distinct-part vs brand-version model (merge carefully)
3. Auto-restock when JPO pull hits order level?
4. Smart Cards vs chip filters on lists
5. SF Symbols vs Material icons
6. Tablet/Mac: sidebar+detail vs scaled phone layout

---

## How to use this file

1. Check off items when done.
2. When starting a new end-goal module, add a short “In progress” note under **Where we are** and open the matching `docs/end-goal/` doc.
3. Don’t expand the whole WiredPart UI into the foundation spec — keep foundation lean; grow the roadmap instead.
