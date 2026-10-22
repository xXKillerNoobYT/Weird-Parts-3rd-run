# Weird Parts / WiredPart — Roadmap

Living tracker. End goal is saved under `docs/end-goal/`; details get worked out as we build.

## Product north star

**WiredPart** — outdoor / field construction ops app (jobs, notebooks, parts, warehouse, scheduling, chat, fleet, people/Hats, etc.).

**Foundation first** — local-first, server-free Parts + Jobs/JPO on every device, nearby sync, encrypted backup. No cloud required. Nearby proof uses real devices on the same local network; a cloud machine is never a nearby peer. Accounts and product AI/MCP are parked until Isaac asks; company cloud is much later.

Reference drafts (rough, not binding detail yet):

- `docs/end-goal/DESIGN-AUDIT.md` — modules, UI standards, build workflow
- `docs/end-goal/MERGE-PLAN.md` — Hats, accessibility, screen merge order
- `docs/end-goal/PARTS-MODEL.md` — parts / warehouse / JPO / restock / returns
- `docs/end-goal/WiredPart.dc.html` — UI prototype
- `docs/end-goal/Panel Schedule Builder.dc.html` — panel schedule prototype
- `docs/end-goal/screens/` · `docs/end-goal/screenshots/` — visual references

---

## Locked decisions (foundation)


| Decision           | Choice                                                                                                                                             |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Who uses it        | Crew / shop — shared jobs + catalog                                                                                                                |
| Platforms (v1)     | iOS, Android, Windows, Mac                                                                                                                         |
| Stack              | Flutter + SQLite (Drift)                                                                                                                           |
| Sync               | Local nearby only; the current Phase 4 proof is Wi‑Fi between the Mac and Impure on the house LAN. Bluetooth remains a later fallback; Impure has no Bluetooth. **No internet required; cloud is never a nearby peer.** |
| Catalog edits (v1) | Trusted editors via **shared shop PIN**; field can add custom/temp parts on jobs                                                                   |
| Photos             | In v1 — capture and sync (prefer Wi‑Fi for media)                                                                                                  |
| Identity now       | Device ID; no accounts                                                                                                                             |
| Identity later     | Local user profiles, peer sync + backup (before cloud)                                                                                             |
| Permissions later  | **Hats** (admin-assigned roles) — replace/extend PIN                                                                                               |
| Product AI/MCP     | Parked until Isaac asks. Do not turn developer app-control tooling into a custom WiredPart MCP.                                                     |
| Dev app control    | Enable the official Dart/Flutter MCP on Impure and Mac, debug-only. Use that cheaper path for non-UI tests; UI tests remain the visual pass.        |
| Catalog identity   | **General Part** is the default (info, no MPN). Brand versions optional when brand matters. Part has a **default supplier**.                       |
| Job line tracking  | Needed / shop-pull separate from orders. **Order splits**: multiple supplier+qty rows per line. Brand optional on the line; else default supplier. |
| Cloud              | Far future, optional                                                                                                                               |
| Company IDs        | Future — local company identity shared across crew devices (before/alongside cloud)                                                                |
| Auto sync          | **Later (Phase 7)** — auto/background nearby sync after manual **two-way** Sync Now is solid; still local-first, no internet |
| Detail policy      | End goal saved; work out screen/module detail **as we build**                                                                                      |


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

**Current focus:** Phase 4 acceptance proof for draft [#29](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/29). Do not merge it until the Mac and Impure copy a shop over Wi‑Fi on the house LAN.

Recent merged truth:

- [x] Encrypted backup and restore, including backup date and source device — [#13](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/13)
- [x] Deleted catalog parts keep job-line names and order splits — [#14](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/14)
- [x] Job Promote can add missing Category / Type / Variant and supplier data — [#24](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/24)

---

## Foundation build phases

### Phase 1 — Local core

- [x] Flutter multi-platform project
- [x] SQLite schema: jobs, job lines, catalog (part / brand version / supplier), taxonomy, device ID, sync metadata columns (`revision`, `modifiedAt`, `deletedAt` tombstones) — no separate change-log table
- [x] Jobs CRUD + job parts list (general part by default; optional brand; needed · shop pull · **order splits** by supplier; soft-delete remove)
- [x] Catalog browse/add/edit (name / description / UOM / default supplier / active) + brand versions / listings; taxonomy maintenance (categories, styles, types, devices, brands, suppliers)
- [x] Editor PIN gate for catalog writes
- Note: `AppSettings` (PIN hash, etc.) is **local-only** in Phase 1; sync-shaped settings / PIN sync are Phase 5 prep — do not overbuild now.

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
- [x] Deleted-part snapshots preserve job-line names and order splits ([#14](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/14))
- [x] Promote can create missing Category / Type / Variant and supplier data ([#24](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/24))

### Phase 3 — Backup

- [x] Encrypted export / import ([#13](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/13))
- [x] Show backup date + source device ([#13](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/13))

### Phase 4 — Nearby link (one-way test only)

- [ ] Manual discover / pair / verify code — implemented on draft [#29](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/29), not accepted or merged
- [ ] One-way Wi‑Fi shop copy — engineering step only, not the product sync UX
- [ ] **Merge gate for #29:** the Mac and Impure must copy a shop on the house LAN using Wi‑Fi only. Impure has no Bluetooth. Never use a cloud machine as the nearby peer, and do not merge before this physical-device proof.

### Phase 5 — Two-way sync (one session, both directions)

**Later:** Phase 5 has not started. The one-way Phase 4 draft does not satisfy this phase.

- [ ] **True two-way sync in a single Sync Now** — both devices send and receive changes; users should not have to run two one-way syncs
- [ ] Change-set sync, tombstones, sync receipts
- [ ] Conflict rules + Sync Issues screen
- [ ] Photo sync policy (Wi‑Fi preferred)
- [ ] Prep: decide whether `AppSettings` / PIN material becomes syncable (Phase 1 keeps it local-only)

### Phase 6 — Hardening

- [ ] Permissions, performance, sync recovery, multi-device testing

### Phase 7 — Auto / background nearby sync (later)

- [ ] Auto background syncing between known/paired nearby devices (still local-first; no internet required)
- [ ] User controls: enable/disable, which peers, battery/Wi‑Fi preferences
- [ ] Safe with conflicts: never silent discard; surface issues like manual sync

---

## Parked until Isaac asks

Do not pull these into the current Phase 4 acceptance work:

- [ ] Backup leftovers and large-catalog/platform follow-ups — [#22](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/22)
- [ ] Catalog follow-ons — [#25](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/25), [#26](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/26), [#27](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/27), [#28](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/28)
- [ ] Hats
- [ ] Warehouse
- [ ] Product AI/MCP

Developer remote control is separate from the parked product MCP: enable the official Dart/Flutter MCP on Impure and Mac in debug builds only. Do not build a custom WiredPart MCP unless Isaac explicitly asks.

---

## End-goal backlog (later — detail while building)

Do **not** fully spec these now. Pull from `docs/end-goal/` when a phase starts.

- [ ] Hats data layer + admin (parked; roles from MERGE-PLAN)
- [ ] Local user profiles (peer sync + backup)
- [ ] Product AI/MCP bridge (parked until Isaac asks; tool permissions per user / settings)
- [ ] Warehouse stock, locations, movements (parked)
- [ ] Restock orders / receiving / returns
- [ ] Dashboard, clock, notebooks, panel schedule
- [ ] Scheduling, chat, fleet, tools
- [ ] People, reports, office, full settings
- [ ] Outdoor a11y pass (56px actions, photo/voice capture)
- [ ] Preferred brand on a part, and/or preferred brand for a job (after general-part + optional brand works)
- [ ] Company IDs (crew/company identity on devices)
- [ ] Auto / background nearby sync (Phase 7 — after two-way manual sync works)
- [ ] Optional company cloud

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
4. Update this roadmap whenever implementation, validation, merge, parking, or sequencing status changes.

