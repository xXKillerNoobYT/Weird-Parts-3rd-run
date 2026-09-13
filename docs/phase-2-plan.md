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

## In this photos PR

- PIN unlock no longer crashes catalog folders (`ExpansionTile` Theme left dependents when the PIN keyboard rebuilt the still-mounted Catalog tab).
- Wrong PIN stays on the dialog with an error instead of silently closing.
- Mac sandbox can open the user-selected file picker (`files.user-selected.read-only`).
- Desktop hides **Take photo** (no camera delegate); Choose photo is the Win/Mac path.
- Photo add/replace/remove does not wipe unsaved name / tree / active edits.
- Stored photo id is a relative filename; replace uses a new filename so the preview is not a stale `Image.file` cache.
- JPEG compress runs off the UI isolate.

## Still other Phase 2 PRs (not this one)

- Custom job line → catalog promote ([#6](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/6))
- Documents sqlite → Application Support copy ([#7](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/7))
- Search expands matching folders ([#8](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/pull/8)) — tree identity in this PR also unblocks expand-on-search

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
