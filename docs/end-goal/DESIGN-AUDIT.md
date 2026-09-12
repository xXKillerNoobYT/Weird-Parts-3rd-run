# WiredPart — Full Design Audit & Build Workflow

> Cross-references the **rebuild** (`WiredPart.dc.html`) against the **plans/** folder
> (master index: `ios-page-review-tracker.md`) and the original Swift source.
> Goal: one coherent design + layout system, then build every screen out fully.

---

## 1. Design language (the "feels like Apple" foundation)

**Color — now implemented (adaptive Apple system colors).**
Per `SemanticColors.swift`: *build on system colors, never raw hex, adapt to light/dark.*
- Semantic tokens are CSS vars that shift per mode:
  green `#34C759`→`#30D158`, blue `#007AFF`→`#0A84FF`, orange `#FF9500`→`#FF9F0A`,
  red `#FF3B30`→`#FF453A`, pink/purple/indigo/teal/mint/yellow likewise.
- `tint()` = color at 15% via `color-mix` (badges/chips); backgrounds adapt automatically.
- Grouped backgrounds + label ink already match Apple exactly
  (`systemGroupedBackground`, `secondary/tertiary`, label 60,60,67 / 235,235,245).

**Type:** SF (-apple-system) — matches. Scale: keep iOS sizes (17 body, 15 secondary, 13 caption, 34/28 titles).
**Surface:** grouped cards, 12–16px radius, hairline separators, subtle shadow. Matches.
**Icons:** currently Material Symbols Rounded. ⚠️ Apple uses SF Symbols — see Q.

---

## 2. Information architecture (14 modules)

Bottom tabs: **Dashboard · Jobs · Chat · Scheduling · More**. Everything else via More.

| Module | Sub-pages (from plans) |
|---|---|
| **Dashboard** | Overview · Clock · Daily Report · QR Scanner |
| **Jobs** | List · Detail(dashboard) · Create/Edit · Clock · Daily Reports · Questionnaire · Labor |
| **Notebooks** | List · Detail · Job Notebooks · Templates · Panel Schedule Builder |
| **Orders** | POs · JPOs · JPO Creation · Procurement · Receiving · Returns · Approvals · Parts Order Mgmt |
| **Warehouse** | Dashboard · Inventory grid · Locations · Movements · Staging · Receiving · Audit · Floor Plan · Returns · Settings |
| **Parts** | Catalog · Categories · Brands · Suppliers · Pricing · Companions · Forecasting · Import/Export |
| **Scheduling** | Calendar · Dispatch board · Time-Off · Availability · Pipeline(short/long) · Templates |
| **Chat** | Channels/Inbox · Thread · Q&A · RFI · Create Channel |
| **Tools** | Dashboard · Registry · Checkouts · Maintenance · Kits · Management |
| **Fleet** | Dashboard · My Vehicle · Vehicles · Detail · Fuel · Mileage · Maintenance · Inspections · Trailers · Telematics |
| **People** | Employees · Customers · Contractors · Contacts · Hats · Permissions · Teams |
| **Reports** | Timesheets · Labor · Pre-Billing · Bookkeeper Export · Spending · Profitability · Daily Summary · Public |
| **Office** | Manage Jobs · Spending · Warehouse Exec · Deletion Approvals · Approvals queue |
| **Settings** | 10 groups, ~25 pages (General…Advanced) + Hats admin |

---

## 3. Program-wide standards (mandated by plans — apply to EVERY page)

1. **Smart Cards as filters** — stat cards (count + tap-to-filter, tap again = all) **replace horizontal chip bars** on ALL list pages. *(PROGRAM STANDARD)*
2. **Help/Info button** on every page (`PageHelpSheet`) — what it does + how to use it.
3. **Standard filter bar** on date-relevant pages: This Week / Last Week / This Period / Last Period / This Month / Custom.
4. **Priority color timeline:** Green ok · Yellow 4 days · Orange 24 hrs · Red overdue · Gray resolved.
5. **44px+ touch targets** everywhere (Bob wants bigger for gloves — see a11y).
6. **One AI button per page** — floating orange circle, bottom-right. (Have it.)
7. **Hat-based permissions** — `hasPermission()`, never hardcoded roles.
8. **Auto-fill job context when clocked in** — all relevant forms.
9. **Audit trail** on parts (`part_change_log`, PartHistoryView).

---

## 4. Accessibility layer (Bob: outdoor construction app)

- Icon **+ label** on every action; bigger icons.
- Larger touch targets & text (≥56px key actions), high-contrast / glove-friendly.
- **Photo / voice capture instead of typing** wherever possible.

---

## 5. Gap analysis — built vs. required

**Built well:** Dashboard, Notebook detail + block editor, Panel Schedule Builder, JPO detail,
Chat (iMessage), AI Assistant panel, Preview Lab (device+theme), adaptive color system.

**Built but conflicts with plans:**
- List pages use **horizontal chip filters** → plans mandate **Smart Cards**. ⚠️ (Bob earlier said "these are smart cards & filters" — need direction.)

**Missing / stub (high level):**
- Smart-card filter pattern · Help buttons · Priority timeline · Standard date filter bar
- **Hats** permission system (data layer + admin) — planned, not built
- Rich per-page layouts for most modules (currently generic row lists):
  Warehouse, Parts (8 pages), Scheduling (dispatch board), Fleet (My Vehicle), Tools,
  People (detail pages), Reports, Office (approvals), Settings (grouped)
- Job detail depth (stage bar, dual progress, AI summary, warranty, financial)
- Clock flow (to-do picker, work type, live timer, switch job)

---

## 6. Build workflow (proposed order)

**Phase 0 — System (do first, benefits every screen):**
Smart Card component · Help sheet · Priority-timeline tokens · Standard filter bar · Hats data layer + gating · a11y control sizes.

**Phase 1 — Core field flows:** Dashboard → Jobs+Detail+Clock → Notebooks → Chat *(mostly done)*.
**Phase 2 — Materials:** Orders/JPO/Procurement → Warehouse → Parts.
**Phase 3 — Ops:** Scheduling → Fleet → Tools.
**Phase 4 — Back office:** People (+Hats admin) → Reports → Office → Settings.
**Phase 5 — Verify:** device × theme × Hat matrix.

Each screen: read plan → list plan-required detail → merge with rebuild → apply standards + a11y → verify.

---

## 7. Open decisions (see questions)
- Deliverable: designed HTML audit/spec doc, or go straight to building screens?
- Smart Cards vs. chip filters (program standard vs. current build + Bob's earlier note).
- Icons: keep Material, or move to SF Symbols look for authenticity.
- Hats role set (still needs confirmation).
- Tablet/Mac: multi-column (sidebar + detail) or scaled phone layout?
- Build order / first module to fully detail.
