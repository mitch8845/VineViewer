# VineViewer — feature and test checklist

Everything the app does as of **0.6.2**, written to be walked through with a
tablet in hand. Tick, strike out, and write in the margins.

Notation: `[ ]` to do · `[x]` works · `[!]` broken · `[?]` unclear what should
happen. The **⚠ NON-OBVIOUS** markers are cases where the correct behaviour is
deliberate and surprising — those are where bugs hide, and several of them are
the *opposite* of what you might assume.

Section 24 lists things that are **not built or not reachable**. Read it before
hunting for a feature that isn't there.

---

## 1. Install and first run

- [ ] Sideload `VineViewer-v0.6.2.apk` from the releases page
- [ ] Home-screen icon label reads **VineViewer**
- [ ] Title bar reads **VineViewer** (0.6.0/0.6.1 wrongly said "PlantViewer")
- [ ] App opens to the project list without a crash on a fresh install
- [ ] ⚠ **NON-OBVIOUS** — first launch after upgrading from 0.5.0 or earlier
      **destroys all data** (schema v4 wipe). Expected. From 0.6.0/0.6.1 nothing
      is lost.
- [ ] Force-stop and reopen: no crash, projects still listed

Notes:

---

## 2. Projects

- [ ] "New vineyard" button creates a project
- [ ] Empty name or whitespace-only name is refused (nothing is created)
- [ ] Name is trimmed
- [ ] Project list shows name and either "No aerial image" or `Image WxH`
- [ ] Two projects can exist with the same name (not a unique constraint)
- [ ] Tapping a project opens the canvas
- [ ] Each project has **its own** fields, template, objects, plants and aerial
- [ ] "Create 4,000-plant test vineyard" builds a project with 4,000 plants
- [ ] ⚠ **NON-OBVIOUS** — that button used to build ~3,030. Count them (or check
      the highest plant number) rather than trusting the label.

Notes:

---

## 3. Setup wizard

Appears automatically after creating a project.

- [ ] Step 1 "What do you draw?" — offers Row and Block as ticked checkboxes
- [ ] Step 2 "What do you record?" — routes to the field editor
- [ ] Step 3 "What is a plant called?" — routes to the template editor
- [ ] "Skip for now" exits at any step
- [ ] "Back" moves to the previous step
- [ ] ⚠ Skipping everything leaves a **usable** project: identifiers fall back to
      bare plant numbers (`1`, `2`, `3`) rather than showing nothing
- [ ] ⚠ **NON-OBVIOUS GAP** — the wizard never asks for the aerial image. You
      must finish/skip it, return to the list, and use the image icon.

Notes:

---

## 4. Fields — the schema engine

- [ ] "New field" creates a field; it appears in the list
- [ ] Name is required
- [ ] A field is either **"A value"** (attribute) or **"Something drawn"** (object)
- [ ] Type cannot be changed once the field exists (control is disabled, and the
      helper text says so)
- [ ] Editing a field and saving **preserves every setting** — options, colours,
      min/max, precision, labels, true/false labels
- [ ] ⚠ **NON-OBVIOUS** — this was a real data-loss bug: saving used to silently
      drop 12 config fields. Set several options + colours + a min/max, save,
      reopen, and confirm nothing vanished.

### Object fields specifically

- [ ] "Drawn as" offers **Line**, **Area**, **Point**
- [ ] Draw type cannot be changed after creation
- [ ] "Plants belong to it" (container) toggle
- [ ] ⚠ A **Point** field cannot be a container (a point contains nothing) — the
      combination is refused
- [ ] Line containers expose "How close counts as on the line" (tolerance)
- [ ] ⚠ Areas have **no** tolerance — inside a polygon is exact; "on" a line is a
      judgement about how accurately you tapped
- [ ] "Shown when blank" (placeholder) is settable per field

Notes:

---

## 5. Field types and validation

One row per type. For each: enter a good value, a bad value, and clear it.

- [ ] **Text** — free text; `maxLength` enforced; `pattern` (regex) enforced with
      "Does not match the required format."
- [ ] **Integer** — rejects `1.5` with "not a whole number"; rejects letters;
      honours min/max
- [ ] **Decimal** — honours `precision`; rejects non-numbers
- [ ] ⚠ Decimal rejects **infinity and NaN** ("is not a finite number") — these
      would poison every downstream calculation
- [ ] **Boolean** — two big buttons; custom `trueLabel`/`falseLabel` are used
- [ ] **Date** — `YYYY-MM-DD`; min/max dates enforced
- [ ] **Datetime**
- [ ] **Categorical** — options shown as large tappable buttons; per-option
      colour swatch appears in the inspector
- [ ] `allowOther` permits a value outside the option list; without it, refused
- [ ] **Multi-select**
- [ ] **Rating** — buttons from `scaleMin` to `scaleMax` (defaults 1–5); a value
      outside the scale is refused
- [ ] Colour ramp is offered only for integer / decimal / rating
- [ ] ⚠ Clearing a value is **distinct from never entering one**. Both display as
      `--`, but "we looked and there is nothing" and "we never looked" are
      different records. Clear a value and check the history shows the clear.

Notes:

---

## 6. Identifier (plant ID) template

- [ ] "Plant ID format" screen lists the parts in order
- [ ] "Plant number" can be added
- [ ] Any field can be added as a part
- [ ] Parts can be **dragged to reorder**
- [ ] Parts can be removed
- [ ] Delimiter is editable — a dot gives `3.12.7`, an ampersand gives `3&12&7`
- [ ] Live preview renders against a **real plant** from the project
- [ ] Empty template is refused ("Add at least one part.")
- [ ] Saving with changes prompts **"This renames N plants"** with the real count
- [ ] Cancelling the prompt changes nothing
- [ ] ⚠ A template that would give two plants the **same** ID is **refused
      outright** — no override is offered. Try removing the Row part from
      `Block.Row.Plant` where two rows both have a plant 1.
- [ ] ⚠ The refusal names the colliding IDs and tells you to add a
      distinguishing part
- [ ] ⚠ A multi-part delimiter, or an empty delimiter, both work — check
      `3127` (empty) is what you get and decide if you want it

Notes:

---

## 7. Aerial image

- [ ] Project list → image icon on the row → sheet with two options
- [ ] **"Five Sisters aerial"** installs the bundled photo, no file browsing
- [ ] **"Choose a photo"** opens the Android picker
- [ ] ⚠ This was broken in 0.6.0/0.6.1 (`MissingPluginException`). Specifically
      test it on 0.6.2.
- [ ] Subtitle changes to `Image WxH` afterwards
- [ ] Image appears under the layout on the canvas
- [ ] "Fit to layout" frames it
- [ ] Choosing an image again **replaces** the existing one
- [ ] Two projects can start from the same image independently
- [ ] ⚠ Image draws at **identity** — top-left at the layout origin, 1:1 pixels,
      no rotation. Correct for a fresh draw; there is no UI to nudge it.
- [ ] ⚠ Delete the aerial file from storage behind the app's back, then reopen
      the project: **the layout must still draw**. The plants are the data; the
      photo is backdrop, and a moved file must not cost you access to 3,000
      records.
- [ ] ⚠ Feed it something that is not an image (rename a `.txt` to `.jpg`): the
      path is still recorded so you can see what went wrong, rather than the
      action silently doing nothing

Notes:

---

## 8. Canvas navigation

- [ ] Two-finger pinch zooms; two-finger drag pans
- [ ] ⚠ **Two fingers always navigate, whatever the tool is** — there is always a
      way to move without putting a tool away
- [ ] ⚠ Start a one-finger marquee, then put a second finger down **mid-drag**:
      navigation takes over cleanly and the view does not jump
- [ ] The point under your fingers stays put while zooming
- [ ] "Fit to layout" frames everything including objects, not just plants
- [ ] Fit happens automatically once on opening a project with content
- [ ] ⚠ Zoom out far: below 0.25 scale individual plant markers **stop drawing
      entirely**. Intended — that is what makes a whole-vineyard overview cheap.
- [ ] ⚠ Zoom in past 1.2 scale with "Show IDs" on: labels appear. Below it they
      do not, however much you want them.
- [ ] Markers stay a constant size on screen as you zoom (they do not balloon)
- [ ] ⚠ Tap tolerance is constant **on screen** at any zoom — a finger-sized
      target zoomed in covers less layout area. Selecting a specific plant in a
      dense row should get easier as you zoom, not harder.
- [ ] Stylus and finger behave identically
- [ ] Desktop only: scroll wheel zooms anchored under the cursor

Notes:

---

## 9. Selection

- [ ] **Select** tool: tap a plant selects it
- [ ] Tap a drawn object selects **the object** (bar appears at the bottom)
- [ ] Tap empty ground clears the selection
- [ ] Drag with Select draws a **marquee**; everything inside is selected
- [ ] **Lasso** tool: freehand loop selects what it encloses
- [ ] ⚠ A lasso with fewer than 3 points selects nothing (it is not a shape yet)
- [ ] ⚠ A **tap** with the lasso tool is treated as a plain select, not an
      empty lasso

### Sticky select (the toggle in the app bar)

- [ ] Icon highlights when on
- [ ] With it on, tapping plants **adds** them one by one
- [ ] ⚠ Tapping an **already-selected** plant **removes** it — that is how you
      fix an over-grab without starting over
- [ ] Marquee and lasso **union** with the existing selection instead of
      replacing it
- [ ] ⚠ **NON-OBVIOUS** — with sticky on, a stray tap on empty ground must **not**
      clear a selection you are 30 taps into building. With it off, it must.
- [ ] Two separate marquees over two stands of plants selects both

### What selection resolves to

- [ ] Object bar → "Select its plants" selects everything on/in that object
- [ ] ⚠ For a **container line**, that means plants within tolerance of it; for a
      non-container line it means plants **carried** by it. Both are unioned.
- [ ] ⚠ **Retired plants are excluded** from a selection by default. Retire a
      plant, select its whole row, and confirm the count drops by one.
- [ ] Selecting an object with no plants says so rather than selecting nothing
      silently

Notes:

---

## 10. Drawing objects

- [ ] **Draw** tool prompts for which object field, if more than one exists
- [ ] With exactly one object field it is chosen automatically
- [ ] With **no** object fields, an explanatory dialog offers to set one up
- [ ] Banner shows how many points are placed
- [ ] "Undo point" removes the last point
- [ ] "Done" opens the naming sheet
- [ ] Live preview of the shape as you tap
- [ ] Switching tools mid-draw **abandons** the shape (no invisible leftovers)
- [ ] A line needs ≥2 points; an area needs ≥3; a point needs 1 — each refusal
      says which
- [ ] Name is suggested as the lowest unused integer
- [ ] Name validated **as you type**, not on submit
- [ ] Duplicate name for the same field is refused
- [ ] Line: "Which end is plant 1" — "Where I started" / "Where I finished"
- [ ] Line: plant it by count or by spacing, or leave it empty
- [ ] Length shown in real units if calibrated, pixels if not

### The overlap rule — ⚠ read carefully

- [ ] Two objects of the **same field** may not overlap. Refused on save, with
      the offending object named.
- [ ] ⚠ **Merely touching is legal.** Two blocks sharing a fence line is the
      normal case and must be allowed. Draw two blocks with a shared edge.
- [ ] ⚠ A **row crossing a block** is legal — different fields. Only same-field
      overlap is refused.
- [ ] ⚠ Two rows crossing each other **is** refused
- [ ] ⚠ On refusal, **the shape you drew is still there** — you go back and move a
      point rather than losing twelve taps. Confirm the button says "Edit shape".
- [ ] ⚠ A name equal to the field's blank placeholder (e.g. naming a row `0`) is
      **reserved** and refused — otherwise `0.12.7` is ambiguous between a real
      address and an unassigned one
- [ ] ⚠ A name containing the **delimiter** (naming a row `12.5` when the
      delimiter is `.`) is refused — it would make the ID unparseable
- [ ] ⚠ A name that is not a number is fine and occupies no number — a row called
      "north" cannot collide with row 1

Notes:

---

## 11. Planting

- [ ] **Plant** tool places a single free-standing plant
- [ ] **Insert** tool inserts into an existing line near the tap
- [ ] Insert away from any plant says "tap next to a plant on the line"
- [ ] Insert next to a plant that is **not** on a line says so
- [ ] Insert prompts: shift everything down, or reuse a gap
- [ ] ⚠ The prompt names **how many plants a shift would rename** — and that
      number must match what actually changes. Count it.
- [ ] "Shift" → new plant takes `after+1`, everything beyond moves up one
- [ ] "Gap fill" → takes the lowest free number, **renaming nothing**
- [ ] ⚠ Gap fill when the row is full **appends** rather than failing
- [ ] Inserting at the very end shifts nothing

### ⚠ Numbering scopes — genuinely non-obvious

- [ ] Numbers are **per carrier**. Row 12 plant 1 and Row 13 plant 1 both exist
      and are correct.
- [ ] ⚠ Free plants (no carrier) have **their own** shared numbering scope. Place
      three free plants: they number 1, 2, 3 regardless of what any row contains.
- [ ] ⚠ New numbers are **lowest-unused**, not highest-plus-one. Retire plant 3,
      plant a new one on that row, and it becomes **3** — not 41.
- [ ] Two plants sharing a `position_idx` on different carriers is legal; sharing
      a full rendered **identifier** is not

Notes:

---

## 12. Object actions (tap an object → "Actions")

- [ ] "Select its plants"
- [ ] "Rename"
- [ ] "Plant more along it" (lines only)
- [ ] "Space points along it" (lines only)
- [ ] "Join to another" (lines only)
- [ ] "Reshape" (switches to the reshape tool)
- [ ] "Delete"

### Rename

- [ ] Shows **live** how many plants the typed name would rename
- [ ] Duplicate name refused
- [ ] Placeholder / delimiter rules apply as when drawing
- [ ] ⚠ Renaming an object whose field is **not in the template** reports "No
      plant IDs change" and needs no confirmation — renaming a road renames
      nothing
- [ ] Confirmed rename updates every plant's ID at once, **without touching a
      single plant row**
- [ ] Old IDs remain in each plant's history

### Plant more along it (the rock case)

- [ ] Shows length and how far plants currently reach
- [ ] Defaults the "from" to just past the last existing plant
- [ ] From / to in real units if calibrated
- [ ] By count or by spacing across that span
- [ ] ⚠ **The headline case:** plant 0–140, then 200–300 on the same line.
      Numbers must come out **contiguous 1..25** with a visible gap in *space* —
      not a gap in the numbering.
- [ ] ⚠ The first pass's numbers are **not disturbed** by the second
- [ ] Reversed span (to < from) places nothing rather than erroring

### Delete

- [ ] ⚠ Plants are **not** deleted. They keep their positions and simply stop
      belonging to the object. Confirm they are still on the map and still hold
      their recorded data.
- [ ] Deleting a container prompts with the ID-change count (every plant inside
      loses that part)
- [ ] Undo restores the object **and** re-attaches its plants

Notes:

---

## 13. Reshape

- [ ] Reshape tool: dragging a **corner** moves that corner only
- [ ] Hint banner explains what to do, and changes once you grab something
- [ ] A drag that grabs no corner does nothing (and looks like it did nothing,
      not like the tool is broken)
- [ ] Generous grab radius (bigger than the plant tap target)
- [ ] ⚠ With an object already selected, its corners are preferred over a
      different object's — reshaping a block that runs under a row must not grab
      the row
- [ ] Two fingers still pan while the reshape tool is active
- [ ] Live preview follows your finger
- [ ] ⚠ Drag a corner in **circles** for several seconds before letting go: the
      vertex must land exactly where you release, with no accumulated drift
- [ ] A tap (no movement) with reshape is a select, not a zero-length reshape

### The two gates before it writes

- [ ] Same-field overlap → refused, **boundary snaps back exactly**
- [ ] ID collision → refused, boundary snaps back exactly
- [ ] Otherwise, "this renames N plants" with cancel restoring the boundary
- [ ] ⚠ **All or nothing.** There is no "move it but leave those plants alone" —
      membership is derived from geometry, so a plant inside Block 2 *is* in
      Block 2.
- [ ] ⚠ Shrink a block off a row's plants: they should lose the block part of
      their ID
- [ ] ⚠ Drag a **row's endpoint** out of a block: its plants go with it and leave
      the block, **even though the block never moved**. This is a second,
      independent way containment changes and is easy to miss.
- [ ] Reshaping a line keeps its plants at their stored offsets — extending the
      far end leaves existing plants exactly where they were
- [ ] ⚠ **Shorten** a line past its plants: they clamp to the new end rather than
      disappearing. Ugly but visible and fixable — better than vanishing.

Notes:

---

## 14. Split and merge

### Split

- [ ] Split tool: tap a line where you want it cut
- [ ] Tapping empty ground or a non-line says so
- [ ] Sheet names the far half and says how many plants move
- [ ] Near half keeps its **id and name**; far half gets the new name
- [ ] Shows the ID-change count live
- [ ] ⚠ Cutting at or past either end is **refused**, not clamped — a "split"
      giving one line and one nothing is a rename with extra steps
- [ ] ⚠ Plants beyond the cut **do not move on screen**. Only their carrier and
      offset change.
- [ ] ⚠ **Numbering is untouched.** The far half keeps 3, 4, 5… and does *not*
      restart at 1. That reads odd and is deliberate — the numbering tool fixes
      it if you want it fixed.
- [ ] ⚠ Cut exactly on an existing **vertex** (a dogleg): neither half should end
      up with a duplicated point
- [ ] ⚠ **The seam plant.** Put a plant exactly at the cut. The halves *touch*
      there, so it is within reach of both. It must land on the half it was
      assigned to (the near one) — decided by its carrier, not by luck.
- [ ] Undo restores one line with all its plants

### Merge / "Join to another"

- [ ] Lists candidate lines, **nearest end first**, with distances
- [ ] "ends touch" shown for a zero gap
- [ ] Selecting a candidate previews how many plants move
- [ ] ⚠ Joins at whichever **pair of ends is closest** — draw the second line
      backwards and confirm it still joins correctly
- [ ] ⚠ When a half has to be reversed, plants on the **surviving** object move
      too, not just the ones coming across
- [ ] ⚠ Two lines with a **gap** between them join into one line spanning the
      gap. Deliberate, not a bug.
- [ ] Refuses joining objects of **different fields** (a Row to a Terrace)
- [ ] Refuses joining something to itself
- [ ] ⚠ **The common case:** two rows both numbered from 1 would give one row with
      two plant 1s. The button changes to **"Join and number 1 upward"** and
      explains why. Plain "Join them" is not offered.
- [ ] ⚠ When it does renumber, numbers follow the **path**, not the screen. Merge
      an L-shaped pair (one leg across, one down) and confirm the corner is not
      numbered wrongly.
- [ ] Merge two rows whose numbers **don't** collide → numbers left completely
      alone
- [ ] ⚠ **Round trip:** split a line, then merge the halves back. Path length,
      plant offsets and numbers should all return to where they started.
- [ ] Undo restores two separate lines

Notes:

---

## 15. Arrays

### Run (parallel copies of a line)

- [ ] "Run" tool draws one line, then a sheet
- [ ] Count and gap; gap in real units if calibrated
- [ ] "This side" / "The other side"
- [ ] ⚠ There is **no way to guess** which side you mean from the direction you
      dragged — check both and confirm the copies flip
- [ ] Optionally plants every copy with the same spacing
- [ ] Preview names the count and the label range (e.g. "named 3 to 26")
- [ ] ⚠ **The line you drew is the first one.** Ask for 24 and get 24, not 25.
- [ ] ⚠ Copies of a line that **doglegs** keep the dogleg. They must not fan
      apart or change shape.
- [ ] Overlap checked against existing objects **and** against the other lines in
      the run; the failure names which line
- [ ] Refusal leaves your drawn line intact and creates nothing
- [ ] ⚠ **The whole run is one press of undo**
- [ ] ⚠ **THE IMPORTANT ONE:** generate 24 rows, then drag one line's endpoint.
      The other 23 must **not** move. There is no parent link by design.
- [ ] ⚠ Zero gap stacks them all on top of each other. Allowed, not refused —
      the count in the sheet is what warns you.
- [ ] Each generated line numbers its plants from 1 independently

### Space (points along a line)

- [ ] "Space" tool draws a **guide line**, then a sheet
- [ ] Choose what to place: **Plants**, or any point-typed field
- [ ] By count or by spacing
- [ ] ⚠ **The guide is never saved.** After placing, confirm no new object was
      created for the guide and it has vanished from the canvas.
- [ ] ⚠ Plants placed along a **throwaway guide** are **free-standing** (no
      carrier) — there is nothing left for a carrier to point at
- [ ] ⚠ Plants placed via **object → "Space points along it"** *are* carried by
      that line. Same sheet, different outcome — the sheet says which.
- [ ] Point objects get sequential names
- [ ] Point objects draw as **diamonds**, deliberately unlike a plant's round dot
- [ ] One press of undo

Notes:

---

## 16. Numbering tool

Select 2+ plants → "Actions" → "Number them".

- [ ] Start-at is settable
- [ ] Four orders: left→right, right→left, top→bottom, bottom→top
- [ ] Preview names the resulting range and the order
- [ ] ⚠ A collision is **refused atomically** — nothing is written, the sheet
      stays open so you can change the start number, and the colliding IDs are
      named
- [ ] ⚠ Re-running the same numbering gives the **same** answer. A row drawn at a
      slight angle has y values differing by fractions of a pixel; without a
      total order the plants would reshuffle between runs. Run it twice.
- [ ] Renumbering is one press of undo

Notes:

---

## 17. Plant inspector and data entry

Select exactly one plant.

- [ ] Panel appears bottom-left, **over** the canvas — the plant stays visible
- [ ] Shows the rendered identifier large
- [ ] Shows which containers hold it ("Row 12 · Block 1") or "Not inside anything"
- [ ] ⚠ Container values are **shown, not editable**. They come from geometry, so
      the way to change one is to move the plant or the boundary.
- [ ] Lists every field with its current value; `--` when unset
- [ ] Categorical colour swatch appears next to the value
- [ ] Tapping a field opens a type-appropriate editor
- [ ] "Clear" appears only when there is a value
- [ ] Dismissing the sheet **cancels** (distinct from clearing)
- [ ] Close button clears the selection
- [ ] ⚠ Panel is **live**: undo an edit and the panel updates itself. It must not
      sit there showing a value that has already been reverted.

### Static (write-once) fields

- [ ] A static field with a value shows a **lock** icon before you tap
- [ ] Writing to it offers "Keep X" / "Overwrite"
- [ ] Overwriting keeps the previous value in history
- [ ] ⚠ **Clearing a static field unlocks it** — clearing is the deliberate act
      of making it writable again

### ID history

- [ ] History icon lists every identifier the plant has carried, oldest first
- [ ] Each entry names the operation responsible
- [ ] The current one is marked
- [ ] "This plant has never been renamed" when there is only one
- [ ] ⚠ The **first** entry has no date and says "as far back as the record goes"
      — the journal records what *changed* an ID, never when it was first given
- [ ] ⚠ Rename a row, then **undo** the rename: the history must show the rename
      **did not happen**, not that it happened and was reversed
- [ ] ⚠ Drag a boundary so the plant changes block, then check history — the
      plant itself was never touched, yet its ID changed
- [ ] ⚠ Change the **template** and reread an old entry: past IDs re-render under
      the new template. The *parts* are what was recorded, not the text.

Notes:

---

## 18. ID-change prompts — all four triggers

Four different things rename a plant. Only one is about naming. Each must count
and confirm, and refuse a collision outright.

- [ ] **1. Template edited** → counted, confirmed, refused on collision
- [ ] **2. Object renamed** → counted, confirmed, refused
- [ ] **3. Boundary moved / reshaped / deleted** → counted, confirmed, refused
- [ ] **4. An ID-part attribute edited** → counted, confirmed, refused
- [ ] ⚠ Trigger 4 is the sneaky one. Put Clone in the template, then correct a
      plant's clone: that **readdresses the plant**. It must prompt.
- [ ] ⚠ With Clone in the template, entering a clone literally called `none`
      (when `none` is the placeholder) is refused — `12.none.7` would be
      ambiguous between a real clone and a missing one
- [ ] ⚠ Entering an ID-part value containing the **delimiter** is refused
- [ ] ⚠ Editing a field that is **not** in the template prompts nothing — the
      overwhelming majority of edits, and they must stay quiet
- [ ] ⚠ Every refusal offers **no override**. Two plants called `3.12.7` makes
      every record naming that plant worthless.
- [ ] ⚠ A change that renames **zero** plants shows no dialog at all

### The one deliberate asymmetry

- [ ] ⚠ Dragging a **single plant** across a boundary changes its ID with **no
      confirmation** — the inspector shows the new ID immediately and it is the
      direct consequence of what you just did
- [ ] ⚠ But a single plant drag that would cause a **collision** *is* refused,
      with a message, and the plant stays put
- [ ] ⚠ Dragging a whole **object** *is* counted and confirmed — it can sweep
      hundreds at once

Notes:

---

## 19. Move tool

- [ ] Dragging a plant moves it
- [ ] Dragging an object moves the whole object and everything it carries
- [ ] Plants are preferred over objects when both are under your finger
- [ ] ⚠ A **carried** plant dragged sideways **slides along its line** to the
      nearest point rather than coming off it. Detaching is an explicit action —
      a clumsy drag must never silently break a plant's membership of its row.
- [ ] ⚠ A **free** plant goes exactly where you drop it
- [ ] ⚠ A plant carried by a line that was never drawn goes where you drop it
      (there is nothing to slide along) rather than refusing to move
- [ ] One drag = one press of undo, not one per pointer event
- [ ] Moving an object checks same-field overlap and refuses, leaving it put

Notes:

---

## 20. Plant lifecycle

Select plants → "Actions".

- [ ] "Mark as removed" — confirmation names the **recorded observation count**
      ("47 recorded observations will be kept")
- [ ] Different wording when nothing has been recorded yet
- [ ] ⚠ History is kept and the **position stays on the map as an empty slot**,
      ready for a replant
- [ ] "Replace with a new plant" (single selection only)
- [ ] Replace offers a checklist of **write-once** fields to carry forward
- [ ] ⚠ Which facts carry forward is a judgement only you can make — the variety
      almost certainly does, the planting date certainly does not
- [ ] ⚠ The successor takes the **same position, carrier, offset and number**, so
      the ID is continuous — but a **fresh identity**, so the dead plant keeps its
      entire history rather than having it reattributed
- [ ] ⚠ There is **no permanent delete and no trash**, by design. The sheet says
      so. A plant you pulled is data; one created by mistake is one press of undo.
- [ ] Retire/replace are undoable

Notes:

---

## 21. Undo / redo — the central bet

- [ ] Undo and redo buttons enable/disable correctly
- [ ] Tooltips name the operation ("Undo Draw Row 12")
- [ ] A snackbar confirms what was undone/redone
- [ ] ⚠ **THE BIG ONE: force-stop the app, reopen, and undo still works.** Undo
      survives the process dying — an Android tablet carried round a vineyard gets
      reaped by the OS routinely.
- [ ] Redo after undo restores the change
- [ ] ⚠ A new edit after an undo makes the redo unavailable
- [ ] ⚠ **One gesture = one undo**, however many rows it wrote. Drawing a planted
      row writes an object, 40 plants and their memberships — one press takes all
      of it back.
- [ ] Undo a 24-line array: all 24 lines and their plants go
- [ ] Undo a 4,000-plant seed
- [ ] ⚠ Undo a **boundary edit** and confirm the membership changes come back too,
      not just the geometry
- [ ] ⚠ Undo a bulk value edit across a whole block
- [ ] ⚠ Undo does **not** record its own inverse (no infinite undo/redo loop)
- [ ] Undo is **per project** — undoing in one project must not touch another

Notes:

---

## 22. Performance (the 4,000-plant gate)

- [ ] Toggle the frame-stats overlay (speedometer icon)
- [ ] Shows fps, average ms, build ms, raster ms, jank %
- [ ] Tap the overlay to reset the counters
- [ ] Seed the 4,000-plant vineyard and record: **fps ___ avg ___ build ___
      raster ___ jank ___%**
- [ ] Pan and zoom continuously for 30s — record the worst frame
- [ ] Target: average under **16.67ms**
- [ ] ⚠ Reference: v2 was 11.5ms avg / 7.8 build; v3 was 13.3 / 8.9. That
      regression is **still unattributed** — these numbers are the thing that can
      attribute it.
- [ ] Time a **boundary drag** on the 4,000-plant project (shrink the block right
      in). Does it stall? Roughly how long? ___
- [ ] Time a **small boundary nudge** — should be much cheaper than a big sweep
- [ ] Select 500+ plants and pan — selection rings are drawn one at a time
- [ ] Turn "Show IDs" on while zoomed in on a dense area
- [ ] Zoom out fully — should get *cheaper*, not more expensive

Notes:

---

## 23. Updater

- [ ] "Check for updates" reports up to date on the newest release
- [ ] ⚠ Distinguishes **"up to date"** from **"couldn't reach GitHub"**. Turn wifi
      off and check: you must get an error, not a false "no updates".
- [ ] ⚠ A 404 is an **error naming the URL**, never "up to date". This was the
      0.6.0/0.6.1 bug — it silently reported no updates for two releases.
- [ ] Download shows progress
- [ ] Hands off to the Android installer
- [ ] Permission-denied message names **VineViewer** (what Settings actually shows)
- [ ] Release notes from the tag are displayed
- [ ] An interrupted download does not resume onto a partial file

Notes:

---

## 24. Not built / not reachable — don't go looking

Built in the data layer with **no UI**:

- **Colour-by-field.** The painter supports per-plant colours and the DAO can
  fetch a field's values across a project, but nothing connects them.
- **Project delete / trash / restore / purge.** All four exist as DAO methods.
  There is no way to delete a project from the app.
- **Bulk field edit across a selection.** The service exists and is tested; the
  selection bar only offers numbering, retire and replace. **You cannot currently
  set a field value on many plants at once from the UI** — which also means the
  array tools' "set the attributes afterwards with multi-select" workflow is not
  yet completable.
- **Rolling back a bulk edit by batch.**
- **Project rename** (DAO only).
- **`asOf` historical queries** — "what was this value in 2025" works in the data
  layer, with no UI.

Not built at all:

- **Aerial image repositioning** (offset / scale / rotation). Schema and painter
  support it; there is no UI. Only matters when swapping in a differently-framed
  photo later.
- **`.xlsx` import / export.**
- **Filter** (show only plants matching criteria).
- **Photo attachment per plant.**
- **Fill** (deliberately dropped — you draw and assign, the app does not guess).
- **Transfer data between plants** (deliberately dropped; the code was deleted).
- **Sync between devices.**
- **Sub-blocks as a feature** — superseded: define another container field.

Known gaps in what *is* built:

- The setup wizard never asks for the aerial image.
- **Q5 is reopened:** a block is a real object with exactly **one** attribute (its
  name) and nowhere to record an area's acreage or its own spray log.

Notes:

---

## 25. Nastiest corners, collected

If you only have time for a handful, these are the ones most likely to be broken.

- [ ] Force-stop, reopen, undo — including undo of a boundary edit
- [ ] Two blocks sharing a fence line (touching must be legal)
- [ ] Split a row at a plant's exact position, check the seam plant's ID
- [ ] Split then merge back; everything returns
- [ ] Merge two rows both numbered from 1 (must offer renumber, not corrupt)
- [ ] Generate 24 rows, drag one endpoint, confirm 23 don't move
- [ ] Drag a row's end out of a block — plants leave the block that never moved
- [ ] Retire plant 3, add a new plant to that row, confirm it becomes 3
- [ ] Name a row `0` (placeholder) and `12.5` (delimiter) — both refused
- [ ] Put Clone in the template, then edit a clone — must prompt
- [ ] Delete the aerial file behind the app's back; layout still draws
- [ ] Sticky select on, tap empty ground, selection survives
- [ ] Second finger down mid-marquee — navigation takes over cleanly
- [ ] Wifi off, check for updates — error, not "up to date"
- [ ] A project with **no objects at all**, and one with **no template** — both
      fully usable

Notes:
