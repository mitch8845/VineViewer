# Vineyard Layout & Vine Data App — Master Plan

**Status:** Planning / pre-development
**Last updated:** 2026-07-24
**Document purpose:** Single source of truth for architecture decisions, open questions, and development sequencing. Update as decisions are made.

---

## 1. Product Summary

A cross-platform app for a winemaker to (a) draw a visual layout of a vineyard over an uploaded aerial image, and (b) attach a fully user-defined data schema to every individual vine, with full change history.

Two coupled subsystems:

1. **Drawing engine** — bulk-oriented tools for laying out rows and blocks quickly. Not a GIS tool. Accuracy is "good enough to recognize the vineyard," not survey-grade.
2. **Data engine** — user-defined fields with types, validation, and display rules. Event-log storage so every value change is timestamped and queryable historically.

### Primary user
A winemaker walking the vineyard with a tablet, making updates on the fly. Also drawing/editing layout on desktop or tablet.

### Explicit non-goals (v1)
- No georeferencing / GPS / lat-lon. Pixel-space only.
- No multi-user concurrent editing (but architecture must not preclude it).
- No RFID (future consideration).
- No cloud server initially.

---

## 2. Confirmed Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Flutter (Dart)**, not Python | Python on Android is a toolchain nightmare (Kivy abandoned). Flutter's `CustomPainter` handles thousands of interactive markers; single codebase covers Android, iOS, Windows, macOS, Linux. Dart syntax is familiar to a polyglot programmer. |
| D2 | **Local-first, no server for v1** | SQLite on device. Sync deferred but designed for. |
| D3 | **Offline-capable by default** | Field use. Connectivity at the vineyard is good but must not be required. |
| D4 | **Event-log data model** | Every field write is a timestamped record. Current value = latest event. Enables year-over-year comparison, which is the core value of the tool. |
| D5 | **Field types are immutable once created** | Changing an integer field to categorical is not supported. User creates a new field and imports data into it. Vastly simplifies the schema engine. |
| D6 | **Static vs. Tracked field flag** | User marks each field. Static = write-once, locked (variety, rootstock, plant date). Tracked = full event history (health, spray, water). |
| D7 | **Vine replacement = retire + new record** | Dead vine gets `end_date` + status `removed`, retains full history. New vine is a new UUID inheriting position and selected fields. `block.row.plant` label resolves to the *active* vine at that position. |
| D8 | **Full drawing capability on mobile** | Not desktop-only. Fire Max 11 has stylus support, which makes this viable. |
| D9 | ~~**Hierarchy fixed at `block.row.plant`**~~ | **SUPERSEDED 2026-07-29 by V3_PLAN.md.** `block.row.plant` was one vineyard's convention, not a law -- and hardcoding it put `blocks` and `vine_rows` in the schema as two spellings of the same idea. The hierarchy is now composed by the user: any field can be a drawn object, any object field can be a container, and the identifier is an ordered template over them. Sub-blocks are no longer a feature to add, they are a field to create. |
| D10 | **Multiple projects supported** | Each project = one vineyard, own image, own schema, own vines. |
| D11 | **Import format: `.xlsx`, first column `plantID`** | Subsequent columns must match existing field names and types, or the row/column is rejected. |
| D12 | **Image source: user-uploaded raster** | Google Maps screenshot expected. No tiling/GIS pipeline. |
| D13 | **Field events attach to vines only; bulk operations write one event per vine** | The user selects any combination — individual vines, whole rows, whole blocks, or a mix. A mixed selection has no single entity a row-level event could reference, so every selection resolves down to a vine set and writes per-vine. Keeps every read path a single query, keeps a vine's history complete even if it is later moved to another row, and keeps the log uniform for export and sync. Bulk writes share a `batch_id` so they are undoable as a unit. |

---

## 3. Target Platforms

### Primary test device
**Amazon Fire Max 11 (2023)**
- SoC: MediaTek MT8188J (2× A78 @ 2.2GHz + 6× A55)
- RAM: 4 GB
- Display: 2000×1200, 11"
- OS: Fire OS 8 (Android 11 base)
- **No Google Play Services** — sideload APK only
- Stylus supported (sold separately) — **recommend acquiring one for testing**

**Performance budget implications:**
- 4 GB RAM with Fire OS overhead → assume ~1.5 GB usable
- Target 60fps pan/zoom with 4,000 vines rendered
- Mid-tier GPU → avoid per-vine widgets; use a single `CustomPainter` with manual hit-testing
- Test on this device early and often; it is the floor, not the ceiling

### Full platform matrix
| Platform | Priority | Notes |
|---|---|---|
| Android (Fire OS) | P0 | Primary field device, sideloaded |
| Windows desktop | P0 | Development + large-screen drawing |
| Android (standard) | P1 | Phone use |
| iOS | P2 | Requires Mac + Apple Developer account ($99/yr) |
| macOS / Linux | P3 | Free with Flutter, low effort |

---

## 4. Remote Update Pipeline (build this FIRST)

The user's stated priority: push builds from home office to a tablet at a remote location.

### Recommended: GitHub Actions → GitHub Releases → in-app updater

```
Local dev machine
  └─ git push (tag: v0.3.1)
       └─ GitHub Actions
            ├─ flutter build apk --release
            ├─ sign APK
            └─ publish to GitHub Releases
                 └─ Tablet: in-app "Check for updates"
                      ├─ GET /releases/latest (version.json)
                      ├─ download APK if newer
                      └─ trigger Android package installer
```

**Why this works:**
- Free (public repo) or ~$0 (private repo, generous Actions minutes)
- Tablet needs only WiFi + one-time "Install unknown apps" permission
- No app store review, no cable, no ADB-over-network fragility
- Version history is automatic

**Implementation notes:**
- Consistent signing keystore — store in GitHub Secrets, back it up offline. Losing it means users must uninstall/reinstall.
- `version.json` in the release assets: `{"version": "0.3.1", "apk_url": "...", "notes": "...", "min_supported_db": 4}`
- Use `package_info_plus` to read installed version, `dio` to download, `open_filex` or `install_plugin` to trigger install
- Optional: auto-check on launch, manual "Check for updates" in settings

**Setup checklist:** ✅ all complete
- [x] Enable "Install unknown apps" for the updater on Fire Max 11
- [x] Generate + back up release keystore
- [x] GitHub repo — **public**, not private. Release assets on a private repo
      need an authenticated request, so the updater would have to ship an
      embedded token: extractable from the APK, and expiring within a year,
      at which point the updater breaks and cannot ship its own fix.
- [x] Actions workflow: build + sign + release on tag push
- [x] In-app update checker
- [x] End-to-end test: push a version bump, confirm tablet updates

**Alternatives considered:**
- *ADB over WiFi* — requires same network. Rejected.
- *Firebase App Distribution* — good, but adds Google dependency; Fire OS lacks Play Services. Workable but unnecessary.
- *Amazon Appstore* — review delays defeat the purpose. Rejected for dev; reconsider for eventual distribution.

---

## 5. Data Architecture

### 5.1 Storage

**SQLite** via `drift` (Dart, type-safe, migration support, reactive queries).
Alternative considered: `sqflite` (lower-level, more boilerplate). `drift` recommended.

Images stored on filesystem, referenced by path in DB. Never as BLOBs.

### 5.2 Core Schema (draft)

```sql
-- A vineyard/project
projects (
  id            TEXT PRIMARY KEY,      -- UUID
  name          TEXT NOT NULL,
  image_path    TEXT,
  image_width   INTEGER,
  image_height  INTEGER,
  created_at    INTEGER,
  updated_at    INTEGER,
  deleted_at    INTEGER                -- soft delete
)

-- Blocks: top level of hierarchy
blocks (
  id            TEXT PRIMARY KEY,
  project_id    TEXT NOT NULL,
  label         TEXT NOT NULL,         -- the "block" in block.row.plant
  boundary      TEXT,                  -- JSON polygon, pixel coords
  sort_order    INTEGER,
  created_at    INTEGER,
  updated_at    INTEGER,
  deleted_at    INTEGER
)

-- Rows within a block
rows (
  id            TEXT PRIMARY KEY,
  block_id      TEXT NOT NULL,
  label         TEXT NOT NULL,         -- the "row"
  start_x       REAL, start_y REAL,    -- pixel coords
  end_x         REAL,   end_y REAL,
  sort_order    INTEGER,
  created_at    INTEGER,
  updated_at    INTEGER,
  deleted_at    INTEGER
)

-- Individual vines
vines (
  id            TEXT PRIMARY KEY,      -- UUID, immutable, internal
  row_id        TEXT NOT NULL,
  position_idx  INTEGER NOT NULL,      -- the "plant" in block.row.plant
  x             REAL, y REAL,          -- pixel coords
  status        TEXT NOT NULL,         -- 'active' | 'removed' | 'missing'
  planted_at    INTEGER,
  ended_at      INTEGER,               -- set when retired
  predecessor_id TEXT,                 -- links replant to the vine it replaced
  created_at    INTEGER,
  updated_at    INTEGER,
  deleted_at    INTEGER
)

-- User-defined field definitions
field_defs (
  id            TEXT PRIMARY KEY,
  project_id    TEXT NOT NULL,
  name          TEXT NOT NULL,
  type          TEXT NOT NULL,         -- see 5.3
  is_static     INTEGER NOT NULL,      -- 1 = write-once/locked
  config        TEXT,                  -- JSON: options, min/max, colors, etc.
  sort_order    INTEGER,
  created_at    INTEGER,
  updated_at    INTEGER,
  deleted_at    INTEGER
)

-- THE EVENT LOG — every value write, ever
field_events (
  id            TEXT PRIMARY KEY,
  vine_id       TEXT NOT NULL,
  field_def_id  TEXT NOT NULL,
  value         TEXT,                  -- serialized per type; NULL = cleared
  observed_at   INTEGER NOT NULL,      -- when it was TRUE (user-editable)
  recorded_at   INTEGER NOT NULL,      -- when it was ENTERED (system)
  source        TEXT,                  -- 'manual' | 'import' | 'bulk'
  note          TEXT,
  deleted_at    INTEGER
)
CREATE INDEX ix_events_lookup ON field_events(vine_id, field_def_id, observed_at DESC);
```

**Design notes:**
- **UUIDs everywhere** — makes future multi-device sync possible without ID collisions.
- **`observed_at` vs `recorded_at`** — critical. Winemaker sprays on Monday, enters it Thursday. Both timestamps matter.
- **Soft deletes everywhere** — required for sync; also prevents accidental data loss.
- **`block.row.plant` is derived, not stored** — computed from `blocks.label` + `rows.label` + `vines.position_idx`. This is what makes renumbering possible without breaking foreign keys.
- **Current value query:** `SELECT value FROM field_events WHERE vine_id=? AND field_def_id=? AND deleted_at IS NULL ORDER BY observed_at DESC LIMIT 1`
- **Materialized current-value cache** will likely be needed for map coloring at 4,000 vines. Denormalize into a `vine_current_values` table, rebuilt on write. Flag as a performance task, not a v1 blocker.

### 5.3 Field Types

| Type | Storage | Config options | Validation |
|---|---|---|---|
| `text` | TEXT | max length, regex | pattern match |
| `integer` | TEXT (int) | min, max, color ramp | range |
| `decimal` | TEXT (double) | min, max, precision, color ramp | range |
| `boolean` | TEXT ('0'/'1') | true/false labels | — |
| `date` | TEXT (ISO 8601) | min, max | valid date |
| `datetime` | TEXT (ISO 8601) | — | valid datetime |
| `categorical` | TEXT | option list, per-option color, allow-other | must be in list |
| `multi_select` | TEXT (JSON array) | option list, colors | all in list |
| `rating` | TEXT (int) | scale (1–5, 1–10), color ramp | in range |

**Color ramp** — for numeric/rating types, user defines a gradient (e.g. 1=red → 5=green) used to color vines on the map. This is the killer visualization feature: "show me the map colored by health."

**Config JSON example (rating field):**
```json
{
  "scale_min": 1,
  "scale_max": 5,
  "color_ramp": {"1": "#d32f2f", "3": "#fbc02d", "5": "#388e3c"},
  "interpolate": true,
  "labels": {"1": "Dead", "5": "Excellent"}
}
```

---

## 6. Drawing Engine

### 6.1 Rendering approach

Single `CustomPainter` on a transformed canvas. **Do not use one widget per vine** — 4,000 widgets will not perform on the Fire Max 11.

```
Stack
 ├─ InteractiveViewer (pan/zoom, shared transform)
 │   └─ CustomPaint
 │        ├─ background aerial image
 │        ├─ block boundary polygons
 │        ├─ row lines
 │        ├─ vine markers (culled to viewport)
 │        └─ active tool preview overlay
 └─ Tool UI layer (palette, inspector, context actions)
```

**Performance techniques:**
- **Viewport culling** — only paint vines in visible bounds
- **LOD (level of detail)** — zoomed out: draw rows as lines, aggregate vine color; zoomed in: individual markers with labels
- **Spatial index** — quadtree or uniform grid for hit-testing. Linear scan of 4,000 vines per tap is ~fine but grid is cheap insurance
- **Cache the background image** as a decoded `ui.Image`, not re-decoded per frame
- **`shouldRepaint`** must be precise or you'll repaint on every pointer move

### 6.2 Tool Inventory

**Layout tools**
| Tool | Behavior | Inputs |
|---|---|---|
| Single Vine | Tap to place one vine | position |
| Row (count) | Drag start→end, place N evenly spaced vines | start, end, count |
| Row (spacing) | Drag start→end, place vines every X units | start, end, spacing |
| Multi-Row Array | Define one row, then perpendicular offset + count → generate N parallel rows | base row, row spacing, row count, direction |
| Block Polygon | Tap vertices to define block boundary | vertex list |
| Block Fill | Given a polygon + row angle + spacings, auto-generate rows and vines to fill | polygon, angle, row spacing, vine spacing |
| Freehand Row | Draw a curve, vines placed along it | path, count or spacing |

**Edit tools**
| Tool | Behavior |
|---|---|
| Select (tap / marquee / lasso) | Multi-select vines for bulk operations |
| Move | Reposition vine, row, or block |
| Insert Vine | Add a vine between two existing — **triggers renumber flow (§6.3)** |
| Delete Vine | Retire vine — **prompts about data (§6.4)** |
| Split Row | Break one row into two |
| Merge Rows | Combine two rows |
| Renumber Row | Re-sequence `position_idx`, with direction control |
| Reverse Row | Flip vine numbering direction |
| ~~Transfer Data~~ | **DROPPED 2026-07-29.** Move all field events from one plant to another. Not wanted: a plant's history belongs to that plant, and the case it was written for (a mis-entered plant) is served by undo. `FieldEventsDao.transferEvents` was written and tested before anyone asked whether it should exist; it and its tests are deleted rather than left looking like an unfinished feature. |

**View tools**
- Color-by-field (uses the color ramp)
- Filter (show only vines matching criteria)
- Label toggle (show/hide `block.row.plant`)
- Image opacity slider
- Measure

### 6.3 Renumbering — Design Detail

**This needs careful UX.** The scenario: winemaker inserts a vine between 3.12.6 and 3.12.7. Options presented to the user:

1. **Shift** — new vine becomes 3.12.7; everything after shifts +1. All labels downstream change. Data follows the *vine*, not the label, so nothing is lost — but printed maps / external spreadsheets referencing old labels are now wrong.
2. **Suffix** — new vine becomes 3.12.6a. No downstream change. Ugly but stable.
3. **Gap fill** — if 3.12.6 was previously removed and its slot is empty, reuse the number.

**Recommendation:** ~~Default to Suffix (non-destructive), offer Shift with a clear warning showing how many labels will change.~~ Provide an explicit "Renumber Row" tool for when the user *wants* clean sequential IDs and accepts the churn.

> **SUPERSEDED (Phase 3a).** Suffix is not expressible: plant numbers are integers assigned "next available", and `position_idx` is an `IntColumn`. Adding a suffix column would put a second sort key into every ordering, export, and import path.
>
> **The app asks instead, per insertion,** and names the cost: "Shifting renames 34 vines." Declining fills the lowest free number in the row, appending if there are no gaps — which renames nothing, at the cost of the number not matching where the vine physically sits. Only the user knows whether a printed map is in somebody's pocket, so neither option is defaulted.
>
> Implemented as `LabelService.insertAfter` and `countAffectedByShift`, with the Insert tool on the canvas toolbar.

**Critical invariant:** `vines.id` (UUID) NEVER changes. Only `position_idx` and derived labels change. All field events reference the UUID, so data is never orphaned.

> **~~OPEN QUESTION~~ Q1 — RESOLVED (Phase 3a): yes, full history.**
>
> It got more pressing than "leaning yes": labels are now explicitly mutable *and* reused from gaps, so `3.12.7` genuinely does mean different vines at different times.
>
> **No separate audit table was needed.** The undo journal already records the before and after of every `position_idx`, `row_id`, and `block_id` change, so it *is* the label history — `LabelService.historyOf(vineId)` derives the answer from it, folding in block and row renames so `3.12.7` → `3.13.7` shows up even when the vine itself was never touched. A second store would have been a duplicate source of truth for the same fact, and the two would eventually have disagreed.
>
> Two honest limits: it begins where the journal begins (v2, Phase 3a — nothing before that is recoverable), and undone operations are excluded, so undo means a rename did not happen rather than happened-and-was-reversed.

### 6.4 Vine Deletion / Replacement Flow

```
User deletes vine 3.12.7
  │
  ├─ "Vine 3.12.7 has 47 recorded observations."
  │
  ├─ [Mark as Removed]  → status='removed', ended_at=now
  │                        History preserved. Position stays (shown as empty slot).
  │                        Slot available for replant.
  │
  ├─ [Replace with New Vine] → old vine retired as above
  │                            new vine created, same position_idx, same x/y
  │                            predecessor_id = old vine id
  │                            → prompt: which static fields to inherit?
  │                              (variety: yes, plant date: no, rootstock: ?)
  │
  └─ [Delete Permanently] → soft delete, hidden from all views
                            requires typed confirmation
                            recoverable from trash for 30 days
```

---

## 7. Import / Export

### 7.1 XLSX Import

**Required format:**
| plantID | health | spray_date | notes |
|---|---|---|---|
| 3.12.1 | 4 | 2026-06-15 | |
| 3.12.2 | 3 | 2026-06-15 | leafroll suspected |

**Rules:**
- Column A must be `plantID`, matching `block.row.plant`
- Every other column header must exactly match an existing field name
- Values must validate against that field's type/config
- Unknown columns → warn and skip (do not fail whole import)
- Invalid values → reject that cell, report it, continue
- Empty cell → no event written (not the same as clearing a value)

**Import flow:**
1. User picks file
2. **Preview screen**: shows matched columns, unmatched columns, row count, and a validation report *before* anything is written
3. User sets `observed_at` for the batch (defaults to today, overridable, or read from a date column)
4. Confirm → writes events with `source='import'`
5. Import gets a batch ID → **fully undoable as a unit**

> Undo-able imports are non-negotiable. A bad import that silently writes 4,000 events with no rollback is the single most likely way to ruin this dataset.

**Library:** `excel` (Dart) or `spreadsheet_decoder`. Evaluate both — `excel` has broader support but has had memory issues on large files. 4,000 rows should be fine either way.

### 7.2 Export

- **XLSX** — current values, one row per vine, one column per field. Mirrors the import format (round-trip).
- **XLSX (history)** — long format: `plantID, field, value, observed_at, recorded_at, source`
- **Project archive** — `.zip` containing SQLite DB + image + manifest. This is the sneakernet sync mechanism for v1.
- **PDF/PNG map** — rendered layout, optionally colored by a field. Field-printable.

---

## 8. Sync Strategy

### v1: Manual project archive
Export `.zip` → transfer (USB, email, Drive, whatever) → import on other device. Full replace, not merge. Crude but honest: no silent conflict corruption.

### v2 (deferred): Real sync
The architecture already supports it because of D2's design constraints:
- UUID primary keys → no collision
- `updated_at` on every row → last-write-wins baseline
- Soft deletes → deletions propagate
- Event log → **field events are append-only, so they merge trivially.** Two devices adding observations to the same vine simply union. This is the big win of the event-log model.

Conflicts only arise on *structural* edits (moving a vine, renaming a field). Small surface area.

**When needed:** FastAPI + Postgres, ~$5–20/mo (Fly.io, Railway, Hetzner). Push/pull with a `since` cursor.

> **OPEN QUESTION Q2:** Is v1 archive-based sync actually sufficient for the real workflow, or will the tablet-and-desktop split create constant merge pain? Worth pressure-testing before committing.

---

## 9. Technology Stack

| Concern | Choice | Notes |
|---|---|---|
| Framework | Flutter 3.x | Stable channel |
| Language | Dart | |
| State management | Riverpod | Testable, compile-safe, good async story |
| Database | SQLite via `drift` | Type-safe, migrations, reactive streams |
| Canvas | `CustomPainter` + `InteractiveViewer` | |
| Image handling | `image_picker`, `image` | |
| XLSX | `excel` (evaluate `spreadsheet_decoder`) | |
| PDF export | `pdf` + `printing` | |
| File access | `file_picker`, `path_provider` | |
| Updates | `package_info_plus`, `dio`, `install_plugin` | |
| Geometry | `vector_math` (bundled with Flutter) | |
| UUIDs | `uuid` | |
| Testing | `flutter_test`, `integration_test` | |

### Project structure
```
lib/
  main.dart
  core/
    db/              drift schema, DAOs, migrations
    models/          domain entities
    geometry/        vector math, spatial index, row generation
  features/
    projects/        project list, create, archive import/export
    canvas/          painters, tools, gesture handling, viewport
    schema/          field definition CRUD, type configs
    data_entry/      vine inspector, bulk edit, event history
    import_export/   xlsx parse/validate/preview/write, pdf map
    updater/         version check, download, install
  shared/
    widgets/
    theme/
test/
```

---

## 10. Development Phases

### Phase 0 — Foundation & Update Pipeline ✅ COMPLETE (2026-07-27)
**Goal: prove you can push a code change from the office and see it on the tablet.**
- [x] Flutter installed, Android toolchain, Fire Max 11 in developer mode
- [x] Hello-world app sideloaded and running on the tablet
- [x] Git repo + GitHub Actions build workflow
- [x] Signing keystore generated and backed up
- [x] Automated release on tag push
- [x] In-app update checker
- [x] **Milestone: bump version, push, tablet self-updates over WiFi**
      *Verified: tablet went 0.1.2 → 0.1.3 unassisted, download to install.*

**Findings worth carrying forward:**
- `path_provider_android` is pinned to 2.2.23; 2.3.0 uses JNI bindings whose
  Gradle script breaks Flutter 3.44.8. Revisit when jni updates.
- `analysis_options.yaml` must exclude `build/`. Without it `flutter analyze`
  and `flutter test` walk ~5,000 artifacts and appear to hang forever.
- Android compares `versionCode`, not the version name, when deciding whether
  an install is an upgrade. Both must be bumped or the installer refuses.
- A debug-signed APK cannot update a release-signed install. CI enforces this
  with `apksigner` before publishing.

### Phase 1 — Data Core (2–3 weeks)
- [ ] drift schema, all tables, migration harness
- [ ] Project CRUD
- [ ] Field definition CRUD, all 9 types, config editors
- [ ] Field event write/read, current-value resolution
- [ ] Unit tests on the event log — this is the foundation, test it hard

### Phase 2 — Canvas MVP (3–4 weeks)
- [ ] Image upload, display, pan/zoom
- [ ] Single vine placement
- [ ] Row-by-count and row-by-spacing tools
- [ ] Vine selection and hit-testing
- [x] Render 4,000 vines at 60fps on the Fire Max 11 ← **hard performance gate**
      **PASSED 2026-07-28.** Worst case (fully zoomed out, all 4,000 visible):
      11.5ms average frame, 3.6ms raster, 10% jank. Budget is 16.67ms.

      First attempt failed at 23.7ms / 42fps / 100% jank, with raster alone at
      17.1ms — over the whole budget. The cause was 4,000 individual
      `drawCircle` calls; grouping by colour and using one batched `drawPoints`
      call per colour cut raster 3.9x. Nearly all of the cost was per-call
      overhead, not pixels.

      Build time (7.8ms) is now the larger half. If more headroom is ever
      needed, that is where to look — not the painting.
- [x] Basic vine inspector panel
- [ ] Choose an aerial image from the UI — still open. `file_picker` had to be
      dropped (its Gradle skips the Kotlin plugin under AGP 9, breaking the
      release build). The real Five Sisters aerial now ships in
      `assets/aerial/` and can be attached to a project from the picker, which
      covers the common case but is not a chooser.
- [ ] Non-categorical field config (min/max, precision, rating scale) — the data
      layer supports all of them; the editor exposes only options and colours.

### Phase 3 — Layout Tools (3–4 weeks)

**Phase 3a — the foundation, done first so no tool is written twice.**
- [x] Durable undo journal (`operations`, `operation_rows`, `undo_context`),
      schema v2 with a migration test against populated v1 data
- [x] Capture by SQLite trigger, generated from drift's table metadata — every
      existing mutating entry point became undoable without being touched
- [x] `OperationRecorder`: the unit of undo is a **gesture**, not a DAO call
- [x] Undo/redo with generic replay, capped at 100 operations per project
- [x] Survives the app being killed — proven by close-and-reopen, and to be
      confirmed by force-stopping on the tablet
- [x] Label history derived from the journal (Q1)
- [x] Insert Vine with the shift / gap-fill prompt (§6.3, superseded above)

**Phase 3b — the tools, each journaled from birth.**
- [ ] Multi-row array (perpendicular vector generation)
- [ ] Block polygon drawing — on a boundary edit, one prompt covering both
      directions: vines that fell outside (offered removal to block `0`) and
      vines swept in (offered assignment), each accepted or declined separately
- [ ] Block fill
- [ ] Move / delete flows (§6.4)
- [ ] Split, merge, reverse, renumber row

Three questions deliberately deferred until those tools are being built: which
half of a split row keeps the number sequence; which direction wins on merge;
and whether Reverse Row renumbers in place or flips a direction flag (a flag
keeps every `position_idx` stable, which both undo and label history prefer).

### Phase 4 — Data Entry UX (2–3 weeks)
- [ ] Vine detail with full event history timeline
- [ ] Fast field entry (large touch targets, stylus-friendly)
- [ ] Bulk edit on multi-selection
- [ ] Color-by-field map rendering
- [ ] Filter and search

### Phase 5 — Import / Export (2 weeks)
- [ ] XLSX import with preview + validation report
- [ ] Undoable import batches
- [ ] XLSX export (current + history)
- [ ] Project archive export/import
- [ ] PDF map export

### Phase 6 — Polish & Field Testing (ongoing)
- [ ] Real vineyard field test
- [ ] Outdoor readability (sun glare, high contrast mode)
- [ ] Stylus vs. finger interaction tuning
- [ ] Performance profiling
- [ ] Backup/restore safety net

### Phase 7 — Deferred
- Cloud sync + multi-user
- RFID / barcode scanning
- Photo attachment per vine
- Analytics dashboards, trend charts
- Weather / spray record integration
- iOS release

---

## 11. Key Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Canvas perf on Fire Max 11 | High | Gate Phase 2 on the 4,000-vine test. Fall back to LOD/aggregation if needed. |
| Renumbering UX confusion | High | Prototype the flows early; get real user reaction before building. |
| Dynamic schema complexity | High | Types immutable (D5) drastically reduces this. Resist scope creep here. |
| Bad import corrupts data | High | Preview-before-write, undoable batches, automatic pre-import snapshot. |
| Data loss on device | Critical | Auto-export archive on a schedule; prominent backup reminders. |
| Learning Flutter/Dart | Medium | Phase 0 doubles as a learning ramp on a low-stakes deliverable. |
| Fire OS quirks | Medium | Test on-device from day one, never trust the emulator. |
| Scope creep | Medium | This document. Phase gates. Deferred list. |

---

## 12. Open Questions

| ID | Question | Status |
|---|---|---|
| Q1 | Audit trail for label renumbering — resolve historical labels? | Leaning yes |
| Q2 | Is archive-based sync sufficient in practice for tablet↔desktop? | Needs pressure-test |
| Q3 | Should plants support arbitrary position (drag anywhere) or snap to row geometry? | **Resolved 2026-07-29: both, and the distinction is a column.** `plants.carrier_id` is the one polyline a plant is snapped to and the only thing `path_offset` is measured along; null means free-standing and the plant keeps its own x/y. A carried plant dragged sideways slides *along* its line rather than off it -- detaching is an explicit action, so a clumsy drag cannot silently break a plant's membership of its row. |
| Q4 | Multiple background images per project (different years/seasons)? | Undecided |
| Q5 | Do blocks need their own user-defined fields, or plants only? | **REOPENED 2026-07-29.** The 2026-07-27 answer was "plants only, and block scope is additive later". v3 changed the ground under it: a block is now a `map_objects` row instancing a user-defined object field, and it already carries a `label` that every plant inside it reads. So blocks have *one* attribute and no way to have a second -- there is nowhere to record an area's acreage or its own spray log. Still additive (an object-scoped event log, or `field_events` gaining a nullable `object_id`), but it is now a question about a thing that exists rather than one that might. |
| Q6 | Row-level operations (spray whole row) — bulk-select sugar, or first-class row events? | **Resolved 2026-07-27: per-vine events.** See D13. |
| Q7 | Should `observed_at` support date-only vs. datetime precision per field? | Likely yes |
| Q8 | Photo attachment per vine — how deferred is this really? Field users tend to want it immediately. | Deferred, but watch |

---

## 13. Immediate Next Steps

1. Install Flutter SDK + Android Studio; verify `flutter doctor`
2. Enable developer mode + ADB on the Fire Max 11
3. Sideload a Flutter hello-world to the tablet
4. Order the Fire Max 11 stylus if not already owned
5. Create the git repo; commit this document
6. Build the GitHub Actions release pipeline
7. Ship the in-app updater and prove the end-to-end loop

**Do not start on the canvas until step 7 is done.** The update pipeline is the thing that makes every subsequent iteration cheap.
