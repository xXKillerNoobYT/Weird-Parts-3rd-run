# Parts Foundation Design — Local-First WiredPart Slice

**Date:** 2026-09-11  
**Status:** Phase 1 implemented (local core)  
**Stack:** Flutter + SQLite (Drift)  
**Platforms (v1):** iOS, Android, Windows, Mac  

Related: `roadmap.md` (progress tracker) · `docs/end-goal/` (WiredPart north-star drafts; detail later)

---

## 1. Purpose

Build the **foundation** of WiredPart: a local-first, server-free app where every device holds a full working copy of jobs and the parts catalog. Nearby devices exchange **changes** over Bluetooth and/or local Wi‑Fi with **no internet required**. Encrypted backup is separate from sync.

This spec covers only the foundation. Full WiredPart modules (warehouse ledger, Hats, scheduling, chat, fleet, MCP, company cloud, etc.) are tracked on `roadmap.md` and detailed as we build.

---

## 2. Goals and non-goals

### Goals

- Offline-capable jobs + job parts lists (JPO) + parts catalog on all four platforms
- Crew/shop sharing via manual nearby sync
- Catalog structure that separates **general part** identity from optional **brand versions** and **supplier listings**
- Track **needed**, **shop pulls**, and **order splits** (per supplier) separately on each job line
- Part photos in v1 (prefer Wi‑Fi for media transfer)
- Catalog write protection via shared shop PIN (v1)
- Hooks so local users, Hats, MCP, company IDs, and auto-sync can land later without a schema rewrite

### Non-goals (foundation)

- Cloud accounts or central server
- Auto sync (manual only at first)
- Full warehouse on-hand ledger, receiving, returns automation
- Hats admin UI / logged-in users (PIN only for now)
- MCP bridge and on-device AI features
- Preferred brand on part or job (parked on roadmap)
- Building the full 14-module WiredPart UI

---

## 3. Architecture

```
Flutter UI (Jobs · Catalog · Sync · Backup · Sync Issues)
        ↓
App services (Jobs · Catalog · PIN · Media · Backup · Sync orchestrator)
        ↓
┌─────────────────────┬──────────────────────┐
│ SQLite (Drift)      │ Local media store    │
│ Full local copy     │ Compressed photos    │
│ Change log          │ by part / media id   │
│ Tombstones          │                      │
│ Sync receipts       │                      │
│ Conflict queue      │                      │
└─────────────────────┴──────────────────────┘
        ↓ sync only (user-initiated)
┌─────────────────────┬──────────────────────┐
│ Bluetooth transport │ Local Wi‑Fi transport│
│ Discover · verify   │ Same LAN / hotspot   │
│ Approve · small     │ Bulk changes + photos│
│ sets · fallback     │ No internet required │
└─────────────────────┴──────────────────────┘
```

**Hard rules**

- No account or central server required for foundation use
- Every device is a complete working copy
- Sync is user-initiated from a visible Nearby Sync screen
- Backup ≠ sync
- Never silently discard user data

**Identity (now vs later)**

- **Now:** unique `device_id` at install; shared editor PIN for catalog writes
- **Reserved:** nullable `user_id` / role fields for local user profiles and Hats
- **Later (sooner than cloud):** MCP tools gated by logged-in user + MCP settings
- **Much later:** optional **paid** company cloud + web client (monetization; free local-first + nearby sync remains base); company IDs; auto nearby sync

---

## 4. Data model

### Sync metadata (every syncable record)

| Field | Purpose |
|---|---|
| `record_id` | Stable unique id |
| `record_type` | Entity kind |
| `origin_device_id` | Device that created it |
| `created_at` / `modified_at` | Timestamps |
| `revision_number` | Monotonic per-record revision |
| `deleted_at` | Tombstone when set; row not hard-deleted while peers may still sync |

Sync metadata lives **on each syncable row** (no separate change-log table in Phase 1). `AppSettings` (PIN hash, device prefs) is local-only for now; making settings sync-shaped is Phase 5 prep.

### Taxonomy (editable, not hard-coded)

- Category → Style → Type
- Devices (many-to-many with parts)
- Brands
- Suppliers

### General Part (default catalog identity)

What the item **is** — not a manufacturer SKU:

- Name, description, category, style, type
- Compatible devices (many)
- Unit of measure, specifications, search keywords
- Photo (optional)
- Active / discontinued
- **Default supplier** (for “we don’t care which brand” ordering)
- **No manufacturer part number** on the general part

### Brand version (optional)

Used when brand matters for a job or catalog entry:

- Brand, manufacturer part number, model number
- Brand-specific description / specs
- Preferred / equivalent / substitute flags (as needed)
- **Supplier listings** under the brand version (who actually carries it)

### Supplier listing (on a brand version)

- Supplier, supplier SKU, description, package qty
- Last-known price (optional), stock status (manual, optional)
- Preferred supplier flag, notes, last verified date

### Job

- Name; optional customer, location, job number
- Status: Active | Completed | Archived
- Notes; created/modified; origin device
- Reserved: future `user_id` / company hooks

### Job line (parts list / JPO line)

- Job id
- **General part id** (or custom/temp part payload until promoted)
- **Brand version id** — optional; omit when brand doesn’t matter
- Needed quantity
- **Shop pull quantity** (how many taken from the shop for this job)
- Notes, uom, added-by device, modified

### Order splits (child rows of a job line)

Orders are **not** a single supplier field on the line.

| Field | Purpose |
|---|---|
| `job_line_id` | Parent line |
| `supplier_id` | Who this slice is ordered from |
| `quantity` | How many on this slice |
| Sync metadata | Same as other records |

Rules:

- A line may have **zero or more** order splits (split an order across suppliers)
- If a brand version is selected, eligible suppliers = listings for that brand version
- If general-only, default to the part’s default supplier; user may still override/split
- Shop pull qty is independent of order splits (pulls vs orders never mixed into one number)

### Custom / temporary parts

- Field users can add a custom line when the catalog lacks the item
- Editors (PIN) can later promote a custom entry into a general catalog part

### Local-only / device tables

- Device profile (`device_id`, display name)
- Editor PIN: store only a salted hash/verifier. Sync the verifier as a settings record so the shop PIN stays consistent across devices after sync; never store or transmit the raw PIN. Each device verifies locally before catalog writes.
- Sync receipts (peer device, last successful sync point)
- Conflict queue (Sync Issues)
- Media files keyed by part/media id

---

## 5. Permissions (v1)

- Anyone can create/edit jobs and job lines (including custom parts and shop-pull / order-split fields)
- **Catalog create/update/delete** (and taxonomy/brand/supplier maintenance) requires unlocking with the **shared shop PIN**
- Hats and per-user permissions replace/extend this later (see roadmap)

---

## 6. Sync and conflicts

### Workflow

1. Open Nearby Sync on both devices  
2. Discover → select → matching verification code → approve both sides  
3. Prefer local Wi‑Fi for bulk + photos; fall back to Bluetooth  
4. Exchange last successful sync point; send changes since then  
5. Validate and apply locally; save sync receipt on both  

### Conflict rules (initial)

| Situation | Behavior |
|---|---|
| Different records | Merge automatically |
| New job lines from both devices | Keep both |
| Quantity / shop-pull / order-split conflicts on same line | Flag for Sync Issues |
| Catalog edits on different fields | Merge |
| Same field edited both sides | Show both versions in Sync Issues |
| Delete vs later edit on another device | Require confirmation; never silent discard |

Photos sync with catalog changes; prefer Wi‑Fi for media payloads.

---

## 7. Foundation screens

| Area | Capabilities |
|---|---|
| Jobs | Create, search, open, archive |
| Job parts list | Add catalog or custom part; needed qty; shop pull qty; optional brand; order splits (supplier + qty); edit/remove |
| Parts catalog | Browse, search, filter (category, style, type, device, brand, supplier); add/edit general parts; optional brand versions + supplier listings; photos |
| Catalog maintenance | Categories, styles, types, devices, brands, suppliers (PIN-gated writes) |
| Nearby Sync | Find, pair, sync now, last sync status |
| Sync Issues | Review and resolve flagged conflicts |
| Backup & Restore | Encrypted export/import; show backup date + source device |

UI polish (outdoor/glove targets, photo/voice capture, Smart Cards, etc.) follows end-goal drafts as we build — not blocking foundation structure.

---

## 8. Backup

- Encrypted backup file export and import
- Show backup date and source device
- Not a substitute for sync; recovery if all synced devices are lost

---

## 9. Build phases

Aligned with `roadmap.md`:

1. **Local core** — schema with per-row sync metadata, jobs, catalog, PIN, job lines with pulls + order splits  
2. **Search, filters, media** — photos; custom → catalog promote; part taxonomy/device assignment UI  
3. **Backup** — encrypted export/import  
4. **Nearby link** — pair + one-way test transfer (dev stepping stone only)
5. **Two-way sync** — single Sync Now exchanges changes both ways (not two one-way syncs); deltas, tombstones, conflicts, photo policy; optional AppSettings sync shape  
6. **Hardening** — performance, recovery, multi-device tests
7. **Later** — auto/background nearby sync (see roadmap Phase 7)

---

## 10. Testing (foundation)

- CRUD jobs/catalog offline on each platform target as available  
- Order splits: multiple suppliers on one line; eligibility respects brand version listings  
- Shop pull vs needed vs ordered sums display correctly on a parts list  
- PIN gates catalog writes; jobs remain editable without PIN  
- Sync: two devices exchange deltas; conflict cases appear in Sync Issues  
- Backup round-trip restores data on a clean device  
- No feature requires internet access  

---

## 11. Out of scope but reserved

Documented on `roadmap.md` / `docs/end-goal/`:

- Hats, local users, MCP, company IDs, auto sync, cloud  
- Warehouse stock movements, restock automation, returns  
- Preferred brand on part or job  
- Full WiredPart module set  

Schema should leave nullable identity/permission hooks and avoid painting into a corner for warehouse movement logs later.

---

## 12. Success criteria

Foundation is successful when a crew can:

1. Maintain a shared-style catalog (general parts + optional brands/suppliers) on device  
2. Build job parts lists with needed qty, shop pulls, and split orders by supplier — fully offline  
3. Manually sync changes between nearby devices without internet  
4. Resolve conflicts without silent data loss  
5. Restore from an encrypted backup  
6. Grow toward WiredPart using `roadmap.md` without rewriting the local-first core  
