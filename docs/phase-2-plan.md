# Phase 2 — Catalog tree, Variance, job qty, photos, promote

Isaac’s shop walk (approved). Replaces the older “search / filters / media” Phase 2 wording.

## Built

1. **File-tree catalog** — Category → Type → Variant → general part → Brand → Variance → part number. Catalog and Maintenance **Types** share one tree.
2. **Category is a folder**, not a part. Job picker only accepts a part or a Variance row.
3. **General parts** hang on the tree with no brand and no brand colors.
4. **Devices chip removed.** Variance lives **under Brands** (main + other options). Colors are per brand; each row has its own MPN.
5. **Job line:** **Requested**, **Split** (shop + each supplier), **Left to Pull/Order**. Delivered / Brought are a “later” note only.
6. Tree search keeps matching leaves and their ancestor folders (search expands ancestors).
7. PIN still gates catalog / tree writes. Jobs still do not ask for a PIN.
8. **Part photos** — compress to JPEG (max edge 1600), store under Application Support, attach on the part screen (PIN).
9. **Custom job line → catalog promote** — PIN editor creates a general part, hangs it on the tree, and points the line at it.

## Bugbot fixes (this completion)

- Upgrade copies a Phase 1 Documents `wired_parts.sqlite` into Application Support when the dest file is missing (plus WAL/SHM).
- Inactive catalog parts keep their real name on job lines; the job picker omits inactive parts.
- Searching uses a new ExpansionTile key so matching folders actually expand.

## Out of Phase 2

- Delivered / Brought fields
- Backup / sync
- Seed catalog
- Isaac’s local leftover cleanup

## Verify (Isaac user test)

- Shop walk: Wire → Romex → 12/2 → general or a brand → a color → part number
- Same part under Types listing and Catalog; rename once, both change
- Job: Requested 10, shop 4, A 3, B 3 → Left 0
- Cannot add a category folder as a job line
- Attach / replace / remove a part photo
- Promote a custom job line; it appears on the tree
- After a Phase 1 install, existing jobs/catalog/PIN are still there (Documents DB migrated)
