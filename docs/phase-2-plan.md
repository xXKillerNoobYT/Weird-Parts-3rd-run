# Phase 2 — Catalog tree, Variance, job qty, photos

Isaac’s shop walk (approved). Replaces the older “search / filters / media” Phase 2 wording.

## Built

1. **File-tree catalog** — Category → Type → Variant → general part → Brand → Variance → part number. Catalog and Maintenance **Types** share one tree.
2. **Category is a folder**, not a part. Job picker only accepts a part or a Variance row.
3. **General parts** hang on the tree with no brand and no brand colors.
4. **Devices chip removed.** Variance lives **under Brands** (main + other options). Colors are per brand; each row has its own MPN.
5. **Job line:** **Requested**, **Split** (shop + each supplier), **Left to Pull/Order**. Delivered / Brought are a “later” note only.
6. Tree search keeps matching leaves and their ancestor folders.
7. PIN still gates catalog / tree writes. Jobs still do not ask for a PIN.
8. **Part photos** — compress to JPEG (max edge 1600), store under Application Support, attach on the part screen (PIN).
9. **Custom job line → catalog promote** — PIN editor creates a general part, hangs it on the tree, and points the job line at it (including add-mode).
10. **Catalog remove** — PIN-gated soft-delete for parts (tombstone + photo files) and empty category/type/variant folders.
11. **Local reset** — More → Reset / wipe all data (confirm, then PIN if set) clears sqlite + photos + PIN to an empty shop.

## In this promote PR

- Promote sets `_saving` so Save cannot race and overwrite the new catalog link.
- Promote from **Add line** (no `lineId` yet) creates the job line as a catalog part — backing out does not drop a custom-only leftover.
- **Edit-mode promote** writes the form's Requested / shop / splits onto the line (same values add-mode already persisted). Backing out after promote keeps those qty edits.

## In this remove + reset PR

- PIN-gated **Remove part** (tree + part screen) soft-deletes the part, brand versions, listings, and photo files. Job lines that pointed at it stay on the job.
- PIN-gated **Remove folder** only when the category / type / variant has no live children.
- More → **Reset / wipe all data** asks to confirm (then PIN if set), deletes sqlite + photos **and a Documents leftover DB**, then restarts into an empty shop. That leftover clear matters now that #7 copies Documents → Application Support.

## Still other Phase 2 PRs (not this one)

- Search expands matching folders ([#8](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/8)) — skip; identity already in #5.

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
- Catalog or More → edit → PIN **1234** unlocks (no red screen)
- Attach / replace / remove a part photo (Windows: Choose photo; phone: camera OK)
- Promote a custom job line (including from Add line before the first Save); it stays on the job as a catalog part
- Edit an existing custom line's Requested / shop / splits, then Promote without Save — qty edits stay on the job line
- Catalog tree → Remove part (PIN + confirm); empty folder Remove; occupied folder stays
- More → Reset / wipe all data → confirm → empty catalog and jobs
