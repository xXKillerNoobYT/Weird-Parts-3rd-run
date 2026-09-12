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

| Decision | Choice |
|---|---|
| Who uses it | Crew / shop — shared jobs + catalog |
| Platforms (v1) | iOS, Android, Windows, Mac |
| Stack | Flutter + SQLite (Drift) |
| Sync | Bluetooth discover/approve + local Wi‑Fi bulk; BT fallback; **no internet required** |
| Catalog edits (v1) | Trusted editors via **shared shop PIN**; field can add custom/temp parts on jobs |
| Photos | In v1 — capture and sync (prefer Wi‑Fi for media) |
| Identity now | Device ID; no accounts |
| Identity later | Local user profiles, peer sync + backup (before cloud) |
| Permissions later | **Hats** (admin-assigned roles) — replace/extend PIN |
| AI | On-device later; **MCP + 3rd-party AI** sooner than cloud, permissioned by logged-in user + MCP settings |
| Catalog identity | **General Part** is the default (info, no MPN). Brand versions optional when brand matters. Part has a **default supplier**. |
| Job line tracking | Needed / shop-pull separate from orders. **Order splits**: multiple supplier+qty rows per line. Brand optional on the line; else default supplier. |
| Cloud | Far future, optional |
| Company IDs | Future — local company identity shared across crew devices (before/alongside cloud) |
| Auto sync | Future — after manual sync is solid; still nearby / local-first, not internet-required |
| Detail policy | End goal saved; work out screen/module detail **as we build** |

---

## Where we are

- [x] Brainstorm started; empty repo + foundation spec
- [x] End-goal draft imported to `docs/end-goal/`
- [x] Approach chosen: Flutter + SQLite
- [x] Foundation design spec written (`docs/superpowers/specs/2026-09-11-parts-foundation-design.md`)
- [ ] User review of foundation design spec
- [ ] Implementation plan for Phase 1
- [ ] App scaffold

**Current focus:** review the foundation design spec, then write the Phase 1 implementation plan.

---

## Foundation build phases

### Phase 1 — Local core
- [ ] Flutter multi-platform project
- [ ] SQLite schema: jobs, job lines, catalog (part / brand version / supplier), taxonomy, device ID, change log, tombstones
- [ ] Jobs CRUD + job parts list (general part by default; optional brand; needed · shop pull · **order splits** by supplier)
- [ ] Catalog browse/add/edit + maintenance (categories, styles, types, devices, brands, suppliers)
- [ ] Editor PIN gate for catalog writes

### Phase 2 — Search, filters, media
- [ ] Search / filter catalog and jobs
- [ ] Part photos (compress, store, attach)
- [ ] Custom part → promote to catalog (editor)

### Phase 3 — Backup
- [ ] Encrypted export / import
- [ ] Show backup date + source device

### Phase 4 — Nearby link (one-way)
- [ ] Manual discover / pair / verify code
- [ ] One-way test transfer (BT and/or local Wi‑Fi)

### Phase 5 — Two-way sync
- [ ] Change-set sync, tombstones, sync receipts
- [ ] Conflict rules + Sync Issues screen
- [ ] Photo sync policy (Wi‑Fi preferred)

### Phase 6 — Hardening
- [ ] Permissions, performance, sync recovery, multi-device testing

---

## End-goal backlog (later — detail while building)

Do **not** fully spec these now. Pull from `docs/end-goal/` when a phase starts.

- [ ] Hats data layer + admin (roles from MERGE-PLAN; confirm with Bob)
- [ ] Local user profiles (peer sync + backup)
- [ ] MCP bridge (tool permissions per user / settings)
- [ ] Warehouse stock, locations, movements
- [ ] Restock orders / receiving / returns
- [ ] Dashboard, clock, notebooks, panel schedule
- [ ] Scheduling, chat, fleet, tools
- [ ] People, reports, office, full settings
- [ ] Outdoor a11y pass (56px actions, photo/voice capture)
- [ ] Preferred brand on a part, and/or preferred brand for a job (after general-part + optional brand works)
- [ ] Company IDs (crew/company identity on devices)
- [ ] Auto sync (nearby; after manual sync is proven)
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
