# Parts Foundation Design — Local-First WiredPart Slice

**Date:** 2026-09-11  
**Status:** Local core implemented. Phase 4 native closeout pending; Phase 5 implementation held. Updated 2026-10-08 under issue #45.
**Stack:** Flutter + SQLite (Drift)  
**Platform targets:** iOS, Android, Windows and Mac. Actual current native evidence is isolated Windows and Mac; mobile support is unverified.

Related: [roadmap](../../../roadmap.md), [current foundation plan](../../sync/foundation-plan.md), [five-design comparison](../../sync/architecture-comparison.md), and [end-goal drafts](../../end-goal/). The new plan distinguishes merged source, pending PR behavior and future contracts.

---

## 1. Purpose

Build the local-first, server-free foundation of WiredPart. Authorized company devices keep usable offline Parts and Jobs and exchange missing changes through a single manual Sync Now. Company, location, portable user and enrolled installation have separate identities. Encrypted replacement and recovery remain distinct from merging.

Current draft Nearby uses local Wi-Fi, UDP discovery port 41000 and explicit paired whole-shop replacement. The actual same-open-page gate in issue #39 must pass before Phase 5 implementation. Router-free Bluetooth and direct Wi-Fi are later adapters on the same safety contract. They do not block this gate.

## 2. Goals and non-goals

### Goals

- Preserve permanent IDs, relationships, Category to Type to Variant and today's data through versioned migrations and isolated encrypted recovery.
- Support offline Parts and Jobs with the existing general-part, optional-brand and supplier-listing model.
- Enroll devices into one company network. Reject unenrolled or revoked peers under an explicit offline freshness policy.
- Let company users sign in on authorized company devices through protected, versioned authentication provisioning. Preserve today's local catalog PIN gate until issue #38 migration.
- Exchange changes both ways with atomic edit tracking, retries, interruption recovery, tombstones and visible attributed conflicts.
- Reuse registered operations, permissions, validation and audit through the UI and baseline local MCP in issue #37.
- Keep the shared data layer suitable for all platform targets and later registered modules. Parts and Jobs usage migration comes first, then Notebook.

### Non-goals for the first sync milestone

- Cloud accounts, a central server or automatic background sync.
- Warehouse stock, receiving, return automation, scheduling, fleet and the full WiredPart module set.
- Full Hats administration and embedded AI assistance.
- Bluetooth, direct Wi-Fi, partner-company sharing or internet transport implementation.
- A promise of unlimited capacity or compatibility with binaries predating the carrier contract.

Photo identity and honest incomplete-media states are required design boundaries. The first two-way milestone's media policy remains open. Later modules retain their own acceptance and do not become immediate native-gate blockers.

---

## 3. Architecture

The existing Flutter application uses Drift/SQLite, local photos, local PIN checks and encrypted backup. Per-row revision metadata does not provide durable semantic replication. Main and draft PR behavior are separated in the current foundation plan.

The proposed direction is shared domain commands and a typed operation registry above durable authored history, local projections, inbox/outbox, tombstones, conflicts and receipts. UI and local MCP call the same commands. A transport adapter carries bounded authenticated operation envelopes and asset manifests. Transport cannot grant membership or choose merge outcomes.

The five-design comparison recommends a small experiment after the current native gate. No engine, serialization, signature suite, CRDT dependency or new source layout is selected by this spec.

**Hard rules**

- No internet or central server is required for foundation use.
- Equal company ID strings or a catalog PIN do not authorize device enrollment.
- Never silently discard an edit, unknown supported-carrier bytes or an unresolved conflict.
- Keep device private keys, active sessions and unrelated local preferences separate from business sync and backup.
- Acknowledged custody, applied changes, intended-shop receipt and human acknowledgment are different facts.
- Version local schema, backup format, envelope/protocol and domain semantics independently.

**Identity and authentication**

Current code has a local device profile and catalog PIN gate. The required foundation adds company, location, user and enrollment identities with persistent IDs. User profiles and roles are separate from protected portable user-authentication state. Issue #38 must resolve that versioned, permissioned contract, including rotation and stale-device handling. Raw PINs never enter business records or logs. Device private keys never clone.

Reset does not re-enroll a device. Restore must not roll back known revocation or authority state. Offline peers cannot know revocations they have not received; the allowed offline interval and historical-action policy need an explicit decision before dependent privileged behavior.

---

## 4. Data model

### Existing row metadata and required history

These are the current Drift `SyncColumns` getters, not a semantic operation log.

| Dart getter | Purpose |
| --- | --- |
| `id` | Permanent record ID |
| `originDeviceId` | Original creating device |
| `createdAt` and `modifiedAt` | Observed timestamps, never a conflict winner |
| `revision` | Existing row revision, insufficient for concurrent causal history |
| `deletedAt` | Tombstone, retained under the future rejoin and compaction policy |

Entity kind and entity schema belong to the required operation registry contract. They are not existing `SyncColumns` getters.

Historical Phase 1 metadata lives on each syncable row, with no separate operation log. Revision numbers and timestamps alone cannot detect all concurrent edits. Phase 5 must commit each edit and authored operation together, then commit incoming effects and receipts together. Current `AppSettings` and device credentials stay local; portable company-user authentication needs the separate issue #38 contract.

### Taxonomy (editable, not hard-coded)

- Category → Type → Variant
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

### Device-local state and planned replication state

- Current local device profile preserves its own `id`, `display_name` and `created_at`. One installation belongs to one company after enrollment.
- Current editor PIN uses a local verifier and gates catalog writes. Do not replicate the verifier as an ordinary settings record. Protected portable company-user authentication is an open issue #38 design, separate from nonportable device credentials.
- Phase 5 must add durable operation, receipt and conflict storage. These are requirements, not current implemented tables.
- Local physical media uses portable asset identity and manifests in the required sync contract.

---

## 5. Permissions

Today's local job editing does not require the catalog PIN. Catalog and taxonomy create, update and delete remain PIN-gated. Foundation company/user authorization must apply at the shared command boundary, including local MCP, rather than relying on hidden UI actions. Full Hats administration remains later.

## 6. Sync and conflicts

The current Nearby engineering flow is discover, Pair, compare the fresh six-digit Match code, approve both sides, Send this shop and Accept shop. It replaces the whole shop and is not a merge or genuine two-way sync. Its Wi-Fi draft must pass the actual issue #39 gate before Phase 5 code begins.

The required Phase 5 flow authenticates company membership, negotiates supported capabilities and exchanges missing changes both ways in one Sync Now. Validate references, quantities, units, versions, hashes and authorization before commit. Persist effects, deduplication and receipt intent atomically. Bound batches and dependency groups; persist progress for interruption and safe retry. Unknown required security semantics reject before disclosure. Unknown domain data may enter bounded opaque custody only under an understood authenticated carrier contract.

| Situation | Required behavior |
| --- | --- |
| Independent authored physical actions | Apply each operation once and derive totals. Similar wording does not prove duplication. |
| New job lines from different devices | Preserve distinct IDs and authors. Ask about business duplication only when needed. |
| Structured edits on independent fields | Merge only if declared invariants compose. Quantity and unit may be coupled. |
| Competing edits to one fact | Preserve attributed alternatives and causal bases. Wall-clock time never picks the winner. |
| Edit versus delete | Retain the tombstone and conflicting edit visibly. A stale peer or restore cannot silently resurrect data. |
| Later Notebook edits | Use stable blocks and detailed editing units. Keep both disputed versions highlighted for authorized readers. |
| Resolution | Ask original editors on any authorized company device. Preserve both answers; an authorized manager can resolve disagreement under explicit policy. |

Photos use portable asset IDs, hashes and manifests. File writes require staging and recovery journals; a SQLite transaction cannot make unrelated files atomic. Pending media must remain visible until the chosen milestone policy is met.

---

## 7. Foundation screens

| Area | Capabilities |
|---|---|
| Jobs | Create, search, open, archive |
| Job parts list | Add catalog or custom part; needed qty; shop pull qty; optional brand; order splits (supplier + qty); edit/remove |
| Parts catalog | Browse, search, filter (category, style, type, device, brand, supplier); add/edit general parts; optional brand versions + supplier listings; photos |
| Catalog maintenance | Categories, styles, types, devices, brands, suppliers (PIN-gated writes) |
| Nearby, current draft | Find, Pair, Match and explicit one-way Send/Accept shop replacement |
| Sync Now, required Phase 5 | Authorized changes-only exchange in both directions, progress and honest pending status |
| Sync Issues, required Phase 5 | Attributed alternatives, editor questions, manager resolution and history |
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
5. **Two-way foundation**. After issue #39, add company enrollment, portable users, atomic operation tracking, changes-only exchange, causal conflicts, tombstones, receipts, compatibility and baseline local MCP. Define media states and keep local credentials separate.
6. **Hardening** — performance, recovery, multi-device tests
7. **Later** — auto/background nearby sync (see roadmap Phase 7)

---

## 10. Testing

Use isolated synthetic data, explicit installation ownership and exact builds. Before migration, prove encrypted restore preserves IDs, references, schema and assets. Bad passwords, damaged files and unsupported versions must leave existing data unchanged.

Phase 5 acceptance requires two authorized computers to edit independently offline, run one Sync Now, restart and retain matching correct records or explicit unresolved conflicts. Exercise competing edits, edit/delete, stale deletion, retries without duplicates, interruptions, crashes, restore and unauthorized devices. Verify full local identity and unrelated settings stay local. Each mobile target needs its own actual acceptance.

The [foundation scenarios](../../sync/scenarios-foundation.md) and [workflow scenarios](../../sync/scenarios-workflows.md) contain 195 proposed cases across thirteen areas. Every row is NOT_RUN. They prepare later acceptance without expanding the current one-way native gate.

New entities declare IDs, references, permissions, semantic capabilities, merge/delete rules and migrations, then pass shared conformance fixtures. Physical tests repeat when changes affect transports, persistence, native credentials, lifecycle, media or platform behavior. Larger synthetic workloads need measured limits, not unlimited-capacity claims.

---

## 11. Out of scope but reserved

Documented on `roadmap.md` / `docs/end-goal/`:

- Full Hats administration, automatic background sync, internet and cloud
- Router-free Bluetooth or direct Wi-Fi, partner sharing and embedded AI
- Warehouse stock movements, restock automation, returns  
- Preferred brand on part or job  
- Full WiredPart module set  

Company users, enrollment, shared permissions and baseline local MCP are foundation requirements. Later inventory and Notebook use the registered extension contract rather than nullable identity hooks alone.

---

## 12. Success criteria

Foundation succeeds when authorized company devices independently work offline, exchange changes both ways in one Sync Now, restart and keep correct IDs and relationships or visible unresolved conflicts. Repeating sync adds no duplicate effect. An unrelated or rejected device receives no protected data. Encrypted recovery passes without credential cloning, stale replay or deletion resurrection.

Parts and Jobs retain usable offline behavior through gradual command migration. Notebook follows through the same extension contract. Later modules reuse automated conformance where appropriate, with native verification for changed system boundaries. The current one-way transfer, test count or scenario count does not satisfy these criteria.
