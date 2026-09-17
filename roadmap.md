# Weird Parts / WiredPart — Roadmap

Living tracker. End goal is saved under `docs/end-goal/`; details get worked out as we build.

## Product north star

**WiredPart** — outdoor / field construction ops app (jobs, notebooks, parts, warehouse, scheduling, chat, fleet, people/Hats, etc.).

**Foundation first** — local-first, server-free Parts + Jobs/JPO on every device, nearby sync, encrypted backup. No cloud required. Accounts/MCP later; company cloud much later.

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
| Sync               | Bluetooth discover/approve + local Wi‑Fi bulk; BT fallback; **no internet required**                                                               |
| Catalog edits (v1) | Trusted editors via **shared shop PIN**; field can add custom/temp parts on jobs                                                                   |
| Photos             | In v1 — capture and sync (prefer Wi‑Fi for media)                                                                                                  |
| Identity now       | Device ID; no accounts                                                                                                                             |
| Identity later     | Local user profiles, peer sync + backup (before cloud)                                                                                             |
| Permissions later  | **Hats** (admin-assigned roles) — replace/extend PIN                                                                                               |
| AI (external)      | **MCP + 3rd-party AI** sooner than cloud; permissioned by user + MCP settings — **external AI only**                                               |
| AI (internal / on-device) | Wanted: onboard/internal AI with access to **all read MCP tools** on the device (local shop data / context)                                 |
| Catalog identity   | **General Part** is the default (info, no MPN). Brand versions optional when brand matters. Part has a **default supplier**.                       |
| Job line tracking  | Needed / shop-pull separate from orders. **Order splits**: multiple supplier+qty rows per line. Brand optional on the line; else default supplier. |
| Cloud              | Far future, optional                                                                                                                               |
| Company IDs        | Future — local company identity shared across crew devices (before/alongside cloud)                                                                |
| Auto sync          | **Later (Phase 7)** — auto/background nearby sync after manual **two-way** Sync Now is solid; still local-first, no internet |
| Detail policy      | End goal saved; work out screen/module detail **as we build**                                                                                      |


### AI tracks (Isaac clarification)

Do **not** treat “MCP + 3rd-party” as the only AI story.

- **External AI** — MCP + 3rd-party AI sooner than company cloud; permissioned by user + MCP settings. The locked “AI (external)” row applies to this track only.
- **Internal / on-device AI** — Wanted: onboard/internal AI with access to all **read** MCP tools that run on the device (local MCP tool surface for reading shop data / context).
- **Platform onboard AI (parked research)** — Apple has OS-built-in AI; assume Android has something similar; Windows and Mac at least on some machines. Acknowledge as a track alongside external MCP AI — **not** a commitment of availability.

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

**Current focus:** Phase 2 — file-tree catalog, Variance under Brands, job Requested / Split / Left to Pull/Order.

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

### Phase 3 — Backup

- [ ] Encrypted export / import
- [ ] Show backup date + source device

### Phase 4 — Nearby link (one-way test only)

- [ ] Manual discover / pair / verify code
- [ ] One-way test transfer (BT and/or local Wi‑Fi) — engineering step only, not the product sync UX

### Phase 5 — Two-way sync (one session, both directions)

- [ ] **True two-way sync in a single Sync Now** — both devices send and receive changes; users should not have to run two one-way syncs
- [ ] Change-set sync, tombstones, sync receipts
- [ ] Conflict rules + Sync Issues screen
- [ ] Photo sync policy (Wi‑Fi preferred)
- [ ] Prep: decide whether `AppSettings` / PIN material becomes syncable (Phase 1 keeps it local-only)

### Phase 6 — Hardening

- [ ] Permissions, performance, sync recovery, multi-device testing
- [ ] Crash recovery prompt (finished / non–agent-debug): if the app crashes or dies unexpectedly, ask whether to restart — Yes → restart on homepage; No → stay closed. Intentional window **X** must quit with no restart (distinguish crash recovery vs normal close; no silent relaunch)

### Phase 7 — Auto / background nearby sync (later)

- [ ] Auto background syncing between known/paired nearby devices (still local-first; no internet required)
- [ ] User controls: enable/disable, which peers, battery/Wi‑Fi preferences
- [ ] Safe with conflicts: never silent discard; surface issues like manual sync

---

## End-goal backlog (later — detail while building)

Do **not** fully spec these now. Pull from `docs/end-goal/` when a phase starts.

- [ ] Hats data layer + admin (roles from MERGE-PLAN; confirm with Bob)
- [ ] Local user profiles (peer sync + backup)
- [ ] MCP bridge — external AI tool permissions per user / settings
- [ ] Internal / on-device AI with access to all read MCP tools on device (shop data / context)
- [ ] Warehouse stock, locations, movements
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
7. Platform onboard AI (Apple / Android / Windows / Mac) — research only; availability not committed

---

## How to use this file

1. Check off items when done.
2. When starting a new end-goal module, add a short “In progress” note under **Where we are** and open the matching `docs/end-goal/` doc.
3. Don’t expand the whole WiredPart UI into the foundation spec — keep foundation lean; grow the roadmap instead.

