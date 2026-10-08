---
tag: home
depends_on: []
status: open
---

# [home] Resizable Home bottom panel (drag + scroll)

> Independent, rider-app only. No API change; no `shared/` change unless the `[design]` tokens
> are landed (then it consumes them). Owner: `rider-planner`.
> Verify: `melos run analyze` + `melos run test`.

## Goal

Make the Home booking panel resizable by scroll (there is no separate handle-drag recognizer —
see Scope):

- Scrolling up on the panel — starting at the handle, which is the first list child — enlarges
  it (shrink the map), up to a maximum panel height.
- Scrolling down shrinks it to **handle-only** (map at its largest).
- Snap between min / initial / max with an animation, compose with the existing pickup,
  destination, stop-list and estimate controls, handle the keyboard, and stay accessible.

## Current state (verified)

### The panel is already a `DraggableScrollableSheet`, but with fixed, arbitrary sizes

`rider_app/lib/features/home/presentation/home_screen.dart`:

- `_buildBottomSheet` returns
  `DraggableScrollableSheet(initialChildSize: 0.25, minChildSize: 0.1, maxChildSize: 0.4, builder: ...)`
  — `:308-312`. No `snap`, no `snapSizes`, no `snapAnimationDuration`, no `controller`. (The
  Flutter SDK default is `snap = false` —
  `~/fvm/default/packages/flutter/lib/src/widgets/draggable_scrollable_sheet.dart:310`.)
- The builder is a decorated `Container` (`:314-325`) whose child is a
  `ListView(controller: scrollController, padding: EdgeInsets.all(16))` (`:326-329`). The
  scroll controller is the sheet's resize driver: dragging the list while it is at its top
  extent changes the sheet size, which is why it already "resizes" somewhat.
- The "handle" is a static `Container(width: 40, height: 4, margin: bottom 16)`
  (`:330-340`) — a visual affordance only, not a `GestureDetector`; it works solely because it
  is the first child of the scrollable list.
- Content order: nearby-drivers chip (`:341`), pickup field (`:342-374`), destination field
  (`:376-406`), stop list + fare note (`:407-417`), route info (`:419`), Request Trip (`:421`).

### The map does not actually resize; it is overlaid

- The body is a `Stack` whose first child is a full-bleed `FlutterMap` (`:187-276`); the sheet
  is a later `Stack` child (`:292`), so it covers the map rather than shrinking it. The visible
  map area changes with the panel, but the map's layout size is constant.
- The my-location FAB is `Positioned(right: 16, bottom: 16)` and added **after** the sheet
  (`:295-303`), so it floats above the collapsed panel and overlaps it at small sizes.
- The sidebar toggle is `Positioned(top: 8, left: 16)` (`:280-291`), unaffected by the panel.
- `_fitItinerary()` (`:79-100`) uses `CameraFit.bounds(..., padding: EdgeInsets.all(60), maxZoom: 16.0)`
  (`:93-99`); it does not know the panel height, so an expanded panel can hide pins it fitted.

### Composition and test seams

- The stop editor's `ReorderableListView` already uses `NeverScrollableScrollPhysics`
  (`stop_list.dart:50-52`), so it will not fight the sheet's scroll.
- The pre-booking estimate is a **separate** `showModalBottomSheet` (`home_screen.dart:623-633`);
  it is not part of this panel.
- Widget tests set a tall surface and note the sheet is 25% of the viewport
  (`rider_app/test/features/home/presentation/home_screen_test.dart:144-164`); they tap
  `Request Trip` after `ensureVisible` (`:437-440`), so panel size affects whether content is in
  the build window.

## Scope

### 1. Snap points and controller

- Add a `DraggableScrollableController` (SDK `:68`) to `_HomeScreenState`.
- Set `snap: true`, `snapAnimationDuration` and `snapSizes`:
  - **min (handle-only)**: compute from a measured handle height (`handlePx / availableHeight`)
    rather than the fixed `0.1`, so only the handle is visible; clamp to a sane floor
    (e.g. `0.06`–`0.10`) and use `MediaQuery`/`LayoutBuilder` for `availableHeight`.
  - **initial**: keep `0.25` (existing default).
  - **max**: content-driven — the height that fits the whole booking form plus all stops, capped
    at `0.9` so the map and toggle stay usable (locked 2026-10-08).
- Keep `min <= initial <= max` (the constructor asserts, SDK `:316-320`).

### 2. Real drag handle + scroll coordination

- Keep the `ListView`-driven resize (scrolling the list to its top then continuing the drag
  resizes the sheet) and add `snap` so a release settles on a snap point.
- **Locked 2026-10-08: no second drag recognizer.** Do not wrap the handle in a
  `GestureDetector`; resize stays driven by list-scroll only, with the `Semantics.onTap`
  min/initial toggle as the handle's accessible affordance. This avoids a recognizer competing
  with the list.
- Only resize when the list is at its extent; the sheet widget already implements this, so
  prefer relying on it over custom scroll math.

### 3. Map resizing

**Locked 2026-10-08: actually shrink the map's layout box** (not overlay-only).

- Wrap the map (and the FAB/toggle overlay) in an `AnimatedBuilder(animation: controller)` (or
  listen to `controller` and `setState`) that sizes the map to
  `availableHeight * (1 - controller.size)` with a small floor, so the map's layout box shrinks
  as the panel grows. Recompute `_fitItinerary()` padding so pins stay inside the visible map.
- Consider animating the map size on snap (not continuously) to reduce `flutter_map` relayouts.

### 4. Compose with existing controls

- At min (handle-only) the pickup/destination/stop/estimate UI is hidden; the handle must be
  the affordance to expand again.
- The `/location-search` round trip (pickup `:349-373`, destination `:381-405`, add stop
  `:118-134`) must not collapse the sheet unexpectedly; preserve the current expansion while
  the search route is on top and restore it on return.
- `Request Trip` must be reachable when the route info + button exist; `ensureVisible` in tests
  depends on the list being scrollable.
- Keep the FAB from overlapping the collapsed handle: move it above the panel's current height
  at min (locked 2026-10-08; do not hide it).

### 5. Keyboard, persistence, accessibility

- **Keyboard**: Home is body-only inside the shell's `Scaffold`; when a field in the sheet is
  focused, either pad the sheet content with `MediaQuery.viewInsets.bottom` (as the driver
  `RateSheet` does, `driver_app/.../rate_sheet.dart:85-89`) or let the shell's
  `resizeToAvoidBottomInset` shrink the body; ensure the focused field is not hidden and the
  sheet does not collapse.
- **Persistence**: **locked 2026-10-08 — session-only.** Remember the chosen height for the
  session (a global `StateProvider<double>` app-local); do not add a persistence dependency.
- **Accessibility**: label the handle with `Semantics` (`'Drag to resize booking panel'`,
  current state expanded/collapsed), keep a ≥48 dp touch target and a
  double-tap/`Semantics.onTap` toggle between min and initial.

### 6. Map invariants

- No change to route derivation: `_routePlan` (`:104-116`), `multiLegRouteProvider`
  (`:176-182`) and `HomeRoutePreview.fromAsync` stay; the `[map]` honesty rules still hold
  (ready = solid blue API geometry, estimate = grey dashed + label, error = no polyline).

## Invariants

- **The `[map]` route-honesty rules are unchanged** (`home_route_preview.dart`; no client
  straight line, estimate labeled).
- **No new booking/route path.** Resizing is presentation only.
- **Keep the scroll ownership single.** Exactly one mechanism resizes the sheet and the inner
  `StopList` stays `NeverScrollableScrollPhysics` (`stop_list.dart:52`).
- **`_fitItinerary` must keep pins visible** for the current panel height.
- **Behavior/tests preserved**: existing Home tests (route preview, stop list, fare note) stay
  green; the sheet remains body-only (no `Scaffold`).
- **Re-export-shim rule** if the `[design]` tokens/components are used; otherwise no shared
  change.

## Out of scope

- The pre-booking estimate `showModalBottomSheet` (`home_screen.dart:623-633`) and its content.
- The active-trip screen's driver sheet and the driver app's panels.
- A general design-system refactor (that landed as `[design]` — see `STATUS.md` → Landed
  `[design]`).
- Route preview logic, API calls, and the stop-list data model.
- Cross-launch persistence unless requested (would add a dependency).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

Widget tests (`rider_app/test/features/home/presentation/home_screen_test.dart`, extending the
existing tall-surface harness `:144-164`):

1. scroll/drag the list (starting at the handle) up → the sheet reaches the max snap point and the
   map's rendered height decreases (assert via the sheet's controller size / a sized-box key
   around the map);
2. drag/scroll down → the sheet reaches the handle-only min and the map is at its largest; the FAB
   does not overlap the handle;
3. scroll on the panel (not drag) at the list's top extent → same resize;
4. snap animation settles on min/initial/max after release;
5. with the keyboard inset simulated (`tester.view.viewInsets`), the focused field is not hidden
   and the sheet does not collapse;
6. the existing route-preview / stop-list / fare-note tests remain green (content reachable via
   `ensureVisible`).

## Cross-domain notes

- **API: none.**
- **Shared (available — `[design]` landed, `STATUS.md` → Landed `[design]`):** the panel uses
  `AppMotion`/`AppElevation` and the `AppSheetHandle` component and gains one barrel import.
- **`[design]` (landed):** the sheet radius/handle token and motion durations already exist; do
  not re-style the panel independently.
- **`[trip]` pickup recovery (landed; STATUS.md → Landed `[trip]`):** both touch `home_screen.dart`;
  the pickup fields live inside this panel, so re-run the pickup tests after any panel change.
- **Driver: none** (the driver trip screen has its own `Expanded` panel —
  `driver_app/.../trip_screen.dart:206-243`).
- **STATUS rows to update on landing:** add a `### [home]` Landed entry (resizable panel +
  snap, with `file:line`); remove this plan's row and delete this file. No new known-bug row.

## Locked product decisions (2026-10-08 — product owner)

1. **Map resizing vs overlay** — actually shrink the map's layout box (not overlay-only).
2. **Max height** — content-driven (fits the form + all stops), capped at `0.9`.
3. **Persistence** — session-only size memory (no new persistence dependency).
4. **Handle interaction** — no second drag recognizer: rely on list-scroll plus the
   `Semantics.onTap` min/initial toggle.
5. **FAB placement at min** — move the FAB above the panel height at min (do not hide it).
