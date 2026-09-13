# Phase 2 — Catalog tree, Variance, job qty

Isaac’s shop walk (approved). Replaces the older “search / filters / media” Phase 2 wording on the roadmap for this slice.

## In scope

1. **File-tree catalog** — Category → Type → Variant → general part → Brand → Variance → part number. Catalog and Maintenance **Types** share one tree builder (`catalog_tree.dart`). Rename once, both views update.
2. **Category is a folder**, not a part. Job picker only accepts a part or a Variance row.
3. **General parts** hang on the tree with no brand and no brand colors.
4. **Devices chip removed.** Variance lives **under Brands** (main + other options). Colors are per brand; each row has its own MPN (`BrandVersions.varianceName` / `isMain`, schema v2). Old `Devices` table stays in the DB, unused.
5. **Job line:** **Requested**, **Split** (shop + each supplier), **Left to Pull/Order** (`Requested − shop − sum(splits)`; negative if over-split). Delivered / Brought are a “later” note only.
6. Tree search keeps matching leaves and their ancestor folders.
7. PIN still gates catalog / tree writes. Jobs still do not ask for a PIN.

## Out of scope (parked)

- Part photos (compress, store, attach)
- Custom part → promote to catalog (editor)
- Delivered / Brought fields
- Backup / sync
- Seed catalog
- Isaac’s local leftover cleanup

## Verify

- Shop walk: Wire → Romex → 12/2 → general or a brand → a color → part number
- Same part under Types listing and Catalog; rename once, both change
- Job: Requested 10, shop 4, A 3, B 3 → Left 0
- Cannot add a category folder as a job line
