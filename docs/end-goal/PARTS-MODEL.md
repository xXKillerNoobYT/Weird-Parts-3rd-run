# WiredPart — Parts / Inventory Data Model

> Source of truth for how **Parts, Warehouse, JPOs, restock Orders, and Returns** relate.
> From Bob (2026-07): "make sure we got parts managing right."

## Core entities

### Part (catalog SKU) — the master record
- **Part Number** on *every* part (unique key).
- Name, **Brand**, Category, **Color**, unit, price, image.
- ⚠️ **Color variants are DISTINCT parts** — same function, different color = different Part Number. (Color matters.)
- Linked **Supplier(s)** — who provides it (one part can have more than one supplier).

### Supplier ↔ Brand coverage
- Each **Supplier carries a set of Brands**, and **not every supplier carries every brand**.
- **Several suppliers can cover the same brand.** (Many-to-many.)
- A part's **eligible suppliers = the suppliers whose brand-coverage includes that part's brand** — pick a preferred one among them. This drives restock-order sourcing and supplier-site search inside JPO creation.

### Warehouse stock — what's physically on the shelf
- Per Part: **quantity on hand**, shelf **location(s)**, and thresholds:
  - **Reorder / order level** — at or below this, a restock Order should be made.
  - **Low (warning) level** — running low but *not yet* at order level / no order placed.
- Full **stock tracking**: every movement (pulled for a job, received, returned, transferred) changes on-hand and is logged.

### JPO — Job Parts List (parts we'll NEED for a job)
- Belongs to a **Job**. The list of parts required to do that job.
- Pulling a JPO's parts **decrements Warehouse on-hand** (staged/consumed for the job).

### Restock Order ("JO") — parts we need / prefer to ORDER
- To **restock the shelf**: because usage is high, to **replace what we took off the shelf** for jobs, or because stock **hit its limits** (order level).
- Goes to a **Supplier**; **Receiving** increments Warehouse on-hand.

### Returns — parts going back
- Each returned part is **tracked to the Supplier that sent it** and **where it needs to go**.
- Two destinations:
  1. **Back to the shelf** — to replace shelf parts that are **low but haven't hit order level** / have no restock order yet.
  2. **Back to the Supplier** that provided that part.

## The flow (how it connects)
```
Job ──needs──> JPO (parts list) ──pull──> Warehouse (on-hand −)
                                              │
                        on-hand ≤ order level │ triggers
                                              ▼
                                       Restock Order ("JO") ──> Supplier
                                              │ receiving
                                              ▼
                                     Warehouse (on-hand +)

Returns ──trace to Supplier that sent it──> back to shelf (if low, no order yet)
                                        └──> back to Supplier
```

## Open questions (need Bob) — see the question form
1. **Terminology → app mapping.** Today "Orders" has *Job Orders (JPOs)*, *Procurement*, *Purchase Orders*. Is your **"JO" = the restock/Procurement order** (and JPO = the job parts list)? Or is "JO" a separate thing?
2. **Auto-restock:** when a JPO pull drops a part below its order level, should the app **auto-suggest/queue a restock Order**?
3. **Two thresholds?** Track both a **low/warning** level and an **order** level (as above), or just one?
4. **Returns destination:** always route back to the **original supplier**, or **shelf-first** when the shelf is low? (Both, with a choice?)
5. **Part-number scheme:** house numbering, or manufacturer/supplier number? **Color suffix** convention?
6. **Module split:** Parts = master catalog + pricing; Warehouse = physical stock + locations + movements; Orders = JPO + restock + returns. Confirm.
