# Offline warehouse counts

Issue [#130](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/130) adds local warehouse locations and count history under Goal 1. This increment is for legacy local shops. Company-marked shops continue to refuse the legacy path. The Editor PIN gates warehouse mutations; it does not grant company or location authority.

Open **More > Inventory**, create a warehouse, select a catalog Part, and record the quantity physically counted. Zero is a count; no saved observation means **Not counted**. History retains each observation, its recorded unit, observation time, recording time, device, and note. The observation time is supplied by the device and is not a trusted global ordering clock.

Counts are absolute observations, not stock movements. Two counts of 12 do not mean 24. A new count must name the previous count it observed. A stale edit refuses instead of silently overwriting a newer count. Each request keeps its permanent ID across retries. Exact authorized retries return the original result once, including after later counts or a catalog unit change. Reusing an ID with different input refuses.

A catalog unit change does not convert or relabel historical stock. The recorded unit remains visible and the current figure needs recount. Deleted catalog Parts retain readable history, but cannot receive new counts. Renaming Parts or locations does not change their IDs or references.

Schema 12 adds `warehouse_locations` and `warehouse_counts` transactionally. The count ordinal orders commits within a local Part/location history only. It is not an arrival-time or clock-based conflict rule for future synchronization. Future sync must preserve stale-base alternatives rather than sum physical observations or silently select one.

Backups and Nearby copies carry the whole SQLite image, including warehouse history. Restore and Nearby remain replacements, not two-way merges. Incoming structure and warehouse relationships must pass staged validation before replacing live data. Unsupported schemas refuse. Keep a pre-upgrade backup: schema 12 has no downgrade migration. Rollback uses a matching older app with its explicit pre-upgrade whole-shop backup, never an older writer against a schema-12 database.

Receiving, reservations, transfers, returns, Job deductions, location authority and warehouse synchronization are separate work. A last physical count is not a promise of stock currently available for collection. Platform/native acceptance and exact test results are tracked in #130; code or widget tests alone do not establish device support.
