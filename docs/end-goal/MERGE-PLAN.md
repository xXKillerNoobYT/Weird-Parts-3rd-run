# WiredPart — Merge + "Hats" Plan

Working plan for folding the **original WiredPart (Swift) app's** richer detail into the
**rebuilt prototype** (`WiredPart.dc.html`), adding the **Hats** permission system, and making
the whole app work for outdoor / low-text field users. We go **screen by screen**.

---

## Principles (locked with Bob)
- **Keep the current color scheme.** Don't touch the palette.
- **Outdoor construction reality:** high contrast, big touch targets, fast navigation, readable in sunlight.
- **Low-text users:** every action = **icon + short label**; **photo / voice capture** instead of typing wherever possible.
- **Hats = admin-assigned permission roles.** The app shows only what the current user's Hat needs, hides the rest, keeps it findable. **Not user-switchable** — an admin assigns the Hat.
- **Merge = pull the original's richer detail** into the rebuild, **and keep the rebuild's additions** (Panel Schedule Builder, JPO nesting, Preview Lab, dark mode).
- **Persist per user:** device + appearance (done) and the assigned Hat.

---

## Hats (permissions) — proposed role set  ⚠️ NEEDS BOB'S OK
A **whole permissions system.** Proposed starting roles:

- **Admin / Owner** — everything; assigns Hats to people.
- **Office / Dispatch** — scheduling, orders, people, reports; no field clock actions.
- **Foreman** — full job & crew control, clock the crew, notebooks, job orders.
- **Journeyman** — assigned jobs, clock self, notebooks, scan / stock.
- **Apprentice** — assigned jobs (mostly read), clock self, scan, photo capture; limited edit.
- **Warehouse** — parts, inventory, POs, transfers; no job clock.

**Model:** each Hat → a **per-module visibility** map **+ per-action allow/deny**. Admin-assigned.
The bottom tab bar, Quick Actions, and detail-screen buttons all filter by the current Hat.

---

## Accessibility upgrades (apply on every screen)
- **Action tiles:** icon + label, **min 56px** tall, high contrast.
- **Text:** body min ~17pt; key numbers larger.
- **Glove-friendly:** larger hit areas, more spacing, min 44px anywhere tappable.
- **Capture:** camera/photo + voice-note affordance on entry fields (vs. typing).

---

## Method — repeat per screen
1. **Read the original Swift screen** and list what it does that the rebuild doesn't.
2. **List what the rebuild has** that the original doesn't (keep these).
3. **Merge** into one screen; apply **Hats** visibility + **accessibility**.
4. **Verify** (screenshot + console + Hat/device/theme states).

---

## Screen order
1. **Dashboard**
2. **Jobs** + **Job detail**
3. **Notebooks** (+ Panel Schedule)
4. **Orders / JPOs / Procurement**
5. **Warehouse / Parts**
6. **Scheduling**
7. **Chat**
8. **Fleet / Tools**
9. **People / Office**
10. **Settings** — includes the **Hats admin** (assign roles to people)

The **Hats admin UI** is built alongside People/Settings, but the Hats *data layer* (role → visibility)
lands first so every screen can filter as we go.

---

## Status
- [x] Plan written
- [ ] Bob confirms Hats roles
- [ ] Hats data layer
- [ ] Accessibility component pass
- [ ] Screen-by-screen merge (Dashboard first)
