---
tag: home
depends_on: []
status: open
---

# `[home]` — Home booking panel is not draggable on web/desktop

## Context / bug

On Flutter **web and desktop**, the Home booking bottom panel (the
`DraggableScrollableSheet`) does not grow when the user drags the grab handle with a mouse.
Touch resizing on Android/iOS works. The panel still opens/closes via the handle's
`Semantics` action and via touch scroll; only the mouse-drag resize path is missing.

## Root cause (verified against the tree)

- The panel is a `DraggableScrollableSheet` with `snap: true` and
  `snapSizes: [initialSize]`; its min/max are the handle-only minimum and the content-driven
  max — `rider_app/lib/features/home/presentation/home_screen.dart:541-549`
  (`snap` `:543`, min/max `:546-547`, `snapSizes` `:549`).
- Its only **pointer-drag** resize path is the internal scrollable,
  `SingleChildScrollView(controller: scrollController)` at
  `home_screen.dart:558-559`. The 48 dp handle lives inside that scroll content
  (`home_screen.dart:571`) and is a `Semantics`-only min↔opening toggle with **no**
  `GestureDetector` — `_buildSheetHandle` `home_screen.dart:661-664,665-687`.
- Flutter's default `ScrollBehavior.dragDevices` is `_kTouchLikeDeviceTypes`, which contains
  touch/stylus/invertedStylus/trackpad/unknown but **not** `PointerDeviceKind.mouse` —
  `~/fvm/default/packages/flutter/lib/src/widgets/scroll_configuration.dart:29-37`, getter
  `:120`. A mouse drag therefore cannot start the sheet's scroll drag, so
  `_DraggableScrollableSheetScrollPosition.applyUserOffset`
  (`~/fvm/default/packages/flutter/lib/src/widgets/draggable_scrollable_sheet.dart:905-914`)
  never sees the pointer and the sheet never resizes.
- The `DraggableScrollableSheet` docs warn about exactly this and offer two remedies — add
  `PointerDeviceKind.mouse` to `dragDevices`, **or** add a drag handle —
  `draggable_scrollable_sheet.dart:291-299`; the official example uses a `Grabber` with
  `GestureDetector(onVerticalDragUpdate:)`
  (`~/fvm/default/examples/api/lib/widgets/draggable_scrollable_sheet/draggable_scrollable_sheet.0.dart:63-64,108-118`).
- The rider `MaterialApp.router` has no custom `scrollBehavior`
  (`rider_app/lib/app.dart:34-39`).
- Programmatic `DraggableScrollableController.jumpTo`/`animateTo` **bypass** the sheet's own
  `snap`/`snapSizes`
  (`draggable_scrollable_sheet.dart:126-127,177-178`), so the handle must do its own snapping.
- No physics fix is needed: the sheet controller already injects
  `AlwaysScrollableScrollPhysics` (D6).

## Scope & non-goals

**In scope:** rider app only — a desktop/web-only mouse drag handle that drives the existing
`_sheetController` (`home_screen.dart:71-73`).

**Explicit non-goals:**

- No physics change: the sheet controller already injects
  `AlwaysScrollableScrollPhysics` (`draggable_scrollable_sheet.dart:810-820`); do **not** add
  one to the `SingleChildScrollView` (D6).
- No `shared/` change (no shared symbol, no shared UI change).
- No API change.
- No driver app change (`driver_app` has no `DraggableScrollableSheet`; its sheets are modal
  `showModalBottomSheet`).
- No `ScrollBehavior`/`dragDevices` change (rejected alternative, below).
- No layout/measurement restructure and no change to `_scheduleSheetMaxMeasure`
  (`home_screen.dart:355-370`).
- No change to the existing touch path or the `StopList` reorder behavior.

## Locked decisions

- **D1 — fix shape: desktop/web-only grabber.** Add a drag handle (grabber) that drives the
  existing `DraggableScrollableController` `_sheetController` (`home_screen.dart:71-73`).
  **Rejected alternative:** adding `PointerDeviceKind.mouse` to the sheet's scroll view's
  `dragDevices`. That would make mouse drags *anywhere* in the sheet scroll/resize and can
  interfere with the reorderable `StopList` drag handle
  (`rider_app/lib/features/home/presentation/stop_list.dart:64-67`). The grabber keeps the
  mouse-resize affordance scoped to one 48 dp target; the tradeoff is one extra recognizer on a
  platform where the scrollable ignores mouse drags, so the two do not compete.
- **D2 — platform gate.** Enable only when `kIsWeb` **or** `defaultTargetPlatform` is
  macOS/linux/windows; disabled on Android/iOS/fuchsia. Encode this in one pure app-local
  predicate, mirroring `shouldSubmitOnEnter`
  (`rider_app/lib/core/platform/enter_to_submit.dart:6-21` and its test
  `rider_app/test/core/platform/enter_to_submit_test.dart`):
  `bool shouldEnableSheetDragHandle({required bool isWeb, required TargetPlatform platform})`
  in new file `rider_app/lib/core/platform/sheet_drag_handle.dart`. `isWeb` wins first, so a
  web build on a mobile OS still gets the grabber (web is pointer-driven).
- **D3 — drag mechanics.** On drag start capture the current size (guard
  `_sheetController.isAttached` and `_availableHeight > 0`). On update, `jumpTo` a running size
  clamped to `[_minSheetSize(_availableHeight), _sheetMax.clamp(_initialSize, 0.9)]`, using
  `details.delta.dy / _availableHeight` (drag up has negative `dy`, so
  `size -= dy / availableHeight`). On end **or cancel**, `_settleSheetDrag` calls
  `animateTo(..., duration: AppMotion.medium, curve: AppMotion.standard)` to the nearest implied
  snap size `{min, initial, max}`, honoring fling direction (cancel passes velocity 0) — because
  `jumpTo`/`animateTo` bypass the sheet's own snapping
  (`draggable_scrollable_sheet.dart:126-127,177-178`). No second write path for
  `homePanelSizeProvider`: the existing `_onSheetChanged` listener
  (`home_screen.dart:331-338`) already persists every controller change.
- **D4 — keep the existing affordance.** Keep the `Semantics.onTap` min↔opening toggle
  `_togglePanelSize` (`home_screen.dart:343-353`), its label `'Drag to resize booking panel'`
  and its `Expanded`/`Collapsed` value untouched (the existing test depends on the label:
  `rider_app/test/features/home/presentation/home_screen_test.dart:1315-1348`). Do **not** add
  tap-to-toggle to the new `GestureDetector` in this plan; a tap-on-grabber toggle is a possible
  follow-up only.
- **D5 — no restructure; mouse-only recognizer.** Keep the handle inside the scroll content
  (`home_screen.dart:571`); no change to `_scheduleSheetMaxMeasure` (`home_screen.dart:355-370`).
  The sheet's scrollable **does** accept trackpad drags (`_kTouchLikeDeviceTypes` includes
  `PointerDeviceKind.trackpad` — `scroll_configuration.dart:29-37,120`), so an unconstrained
  handle recognizer would enter the gesture arena against it over the 48 dp target. Lock
  `supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse}` on the handle
  `GestureDetector` (`supportedDevices`, `gesture_detector.dart:303,1040`): the mouse never
  enters the scrollable's arena on desktop/web, so the two do not compete; two-finger trackpad
  behavior stays on the existing scroll path (unchanged). On mobile the recognizer is not
  attached (callbacks null), so the touch path is unchanged. The platform gate decides whether
  the recognizer is attached; the key is always present (D2, test (c)).
  Give the `GestureDetector` `behavior: HitTestBehavior.opaque` so the whole 48 dp
  target is draggable (the child `AppSheetHandle` is a tiny capsule; the default
  `deferToChild` would miss most of the target). Add a stable key
  `const ValueKey<String>('home-sheet-handle')`.
- **D6 — recorded non-change: no physics change.** The sheet's scroll controller already injects
  `AlwaysScrollableScrollPhysics`: `_DraggableScrollableSheetScrollController.createScrollPosition`
  wraps the position physics with `physics.applyTo(const AlwaysScrollableScrollPhysics())`
  (`draggable_scrollable_sheet.dart:810-820`), so
  `ScrollPositionWithSingleContext.applyNewDimensions` already sees
  `shouldAcceptUserOffset == true` (`scroll_position_with_single_context.dart:108-110`).
  Adding `physics: const AlwaysScrollableScrollPhysics()` to the `SingleChildScrollView` is a
  no-op; **do not add one** (it would be a no-op and falsely imply a behavior change).
- **Supersedes (desktop/web only) — the prior "no second drag recognizer" lock.** The landed
  `[home]` panel plan locked "no second drag recognizer" on 2026-10-08 (git history:
  `git show 62a6019^:rider_app_plans/[home]_bottom_panel_resize.md`, D4; the surviving code
  comments `home_screen.dart:340-342,661-664`). This plan deliberately supersedes that lock
  **for desktop/web only**, because the mouse never enters the scrollable's gesture arena
  there; the mobile lock is preserved by the platform gate (callbacks null on
  Android/iOS/fuchsia). The landing must record the supersession in Landed `[home]` and amend
  those comments.

## Implementation steps

1. **New pure predicate** — `rider_app/lib/core/platform/sheet_drag_handle.dart`:
   ```dart
   import 'package:flutter/foundation.dart';

   /// True when the Home booking panel should expose its mouse-drag grab handle.
   /// Web and desktop are pointer-first; mobile keeps the touch/scroll path.
   bool shouldEnableSheetDragHandle({
     required bool isWeb,
     required TargetPlatform platform,
   }) {
     if (isWeb) return true;
     switch (platform) {
       case TargetPlatform.windows:
       case TargetPlatform.linux:
       case TargetPlatform.macOS:
         return true;
       case TargetPlatform.android:
       case TargetPlatform.iOS:
       case TargetPlatform.fuchsia:
         return false;
     }
     // Exhaustive over TargetPlatform (Dart 3): no trailing return needed.
   }
   ```
   (`isWeb` wins first, mirroring `shouldSubmitOnEnter`
   `rider_app/lib/core/platform/enter_to_submit.dart:6-21`.)

2. **Wire the platform gate in `_buildSheetHandle`**
   (`home_screen.dart:661-687`): compute
   `final canDrag = shouldEnableSheetDragHandle(isWeb: kIsWeb, platform: defaultTargetPlatform);`
   and wrap the existing handle child in
   `GestureDetector(key: const ValueKey<String>('home-sheet-handle'), behavior: HitTestBehavior.opaque,
   supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse},
   onVerticalDragStart: canDrag ? _onSheetHandleDragStart : null,
   onVerticalDragUpdate: canDrag ? _onSheetHandleDragUpdate : null,
   onVerticalDragEnd: canDrag ? _onSheetHandleDragEnd : null,
   onVerticalDragCancel: canDrag ? _onSheetHandleDragCancel : null,
   child: <existing 48 dp SizedBox>)`.
   The `GestureDetector` (and its key) is **always built**; only the callbacks are null when
   the gate is off. Keep the `Semantics` outermost with the existing label/value/`onTap`
   (`home_screen.dart:671-675`). Add imports for `package:flutter/foundation.dart`
   (`kIsWeb`/`defaultTargetPlatform`; `material.dart` re-exports foundation symbols but be
   explicit) and `package:flutter/gestures.dart` (`PointerDeviceKind`, `kMinFlingVelocity`).
   Update the class comments at `home_screen.dart:340-342` and `:661-664` to say the
   desktop/web mouse grabber drives the controller and the scroll path stays the mobile path,
   and to record that this supersedes the 2026-10-08 "no second drag recognizer" lock for
   desktop/web only.

3. **Drag state + math** in `_HomeScreenState` (near `_togglePanelSize`,
   `home_screen.dart:343-353`):
   - fields: `double? _sheetDragSize;`
   - `_onSheetHandleDragStart(DragStartDetails details)`:
     if `!_sheetController.isAttached || _availableHeight <= 0` return;
     `_sheetDragSize = _sheetController.size;`
   - `_onSheetHandleDragUpdate(DragUpdateDetails details)`:
     if `_sheetDragSize == null || !_sheetController.isAttached || _availableHeight <= 0` return;
     `final min = _minSheetSize(_availableHeight);`
     `final max = _sheetMax.clamp(_initialSize, 0.9);`
     `_sheetDragSize = (_sheetDragSize! - details.delta.dy / _availableHeight).clamp(min, max);`
     `_sheetController.jumpTo(_sheetDragSize!);`
   - `_settleSheetDrag(double velocityDy)`: the single landing helper for both end and cancel —
     if `_sheetDragSize == null || !_sheetController.isAttached || _availableHeight <= 0` return;
     `final min = _minSheetSize(_availableHeight);`
     `final max = _sheetMax.clamp(_initialSize, 0.9);`
     `final initial = _initialSize.clamp(min, max);`
     `final size = _sheetController.size;`
     `final snaps = <double>[min, initial, max]..sort();`
     `double target;`
     if `velocityDy.abs() > kMinFlingVelocity`: upward (`velocityDy < 0`) → first snap strictly
     greater than `size` (else `max`); downward → last snap strictly less than `size` (else
     `min`); else → the snap with the smallest `(s - size).abs()`.
     Then `_sheetController.animateTo(target, duration: AppMotion.medium,
     curve: AppMotion.standard);` `_sheetDragSize = null;`.
   - `_onSheetHandleDragEnd(DragEndDetails details)` →
     `_settleSheetDrag(details.velocity.pixelsPerSecond.dy);`
   - `_onSheetHandleDragCancel()` → `_settleSheetDrag(0);` — on web a pointer leaving the
     window cancels the gesture; the official example explicitly handles the re-enter case
     (`draggable_scrollable_sheet.0.dart:40-45,62-73`). Settling at the nearest snap with zero
     velocity leaves the sheet in a valid state rather than mid-drag.
   - `kMinFlingVelocity` comes from `package:flutter/gestures.dart` (already imported for
     `PointerDeviceKind`). `AppMotion.medium`/`standard` are the existing motion tokens used at
     `home_screen.dart:544,350-351`; the existing `_onSheetChanged` listener at `:331-338`
     handles persistence.
   - Optional helper `List<double> _sheetSnapSizes()` to keep `_togglePanelSize` and the drag
     end in agreement is fine, but do not change `_togglePanelSize`'s behavior.

4. **Recorded non-change — no physics.** Do **not** add `physics:`/
   `AlwaysScrollableScrollPhysics` to the `SingleChildScrollView` (`home_screen.dart:558-559`):
   the sheet controller already injects `AlwaysScrollableScrollPhysics`
   (`draggable_scrollable_sheet.dart:810-820`), so it would be a no-op and falsely imply a
   behavior change. No other sheet/layout change (`_scheduleSheetMaxMeasure` untouched).

## Tests (write in the implementation pass; RED→GREEN required for (a)/(b))

1. **New pure predicate test** —
   `rider_app/test/core/platform/sheet_drag_handle_test.dart`, mirroring
   `rider_app/test/core/platform/enter_to_submit_test.dart`:
   - web is true for every `TargetPlatform` (`for (final p in TargetPlatform.values)`);
   - `isWeb: false` is true for macOS/linux/windows;
   - `isWeb: false` is false for android/iOS/fuchsia.
   RED pre-fix: the file/symbol does not exist.

2. **Widget tests** in `rider_app/test/features/home/presentation/home_screen_test.dart`,
   reusing `pumpHome` (`:231-259`), `resizeSurface = Size(800, 600)` (`:1187`), and the
   `sheetWidget`/`sheetSize`/`mapHeight` helpers (`:1189-1203`). Set
   `debugDefaultTargetPlatformOverride = TargetPlatform.linux;` before `pumpHome` and
   `addTearDown(() => debugDefaultTargetPlatformOverride = null);` (pattern from
   `rider_app/test/features/auth/presentation/login_screen_test.dart:450-451`).
   **Add `import 'package:flutter/gestures.dart';`** to
   `rider_app/test/features/home/presentation/home_screen_test.dart` for
   `PointerDeviceKind`: `package:flutter/material.dart` does not export it (the gesture constants
   live in `package:flutter/gestures.dart`; `gesture_detector.dart:20-58` imports them but does
   not re-export). The pure predicate test (1) does not need this import (it uses
   `TargetPlatform` only).
   Define a local helper
   `Future<void> dragHandle(WidgetTester t, Offset off, {PointerDeviceKind kind = PointerDeviceKind.touch}) =>
   t.drag(find.byKey(const ValueKey<String>('home-sheet-handle')), off, kind: kind);`.

   - **(a) mouse drag UP grows the panel** — `'a mouse drag up on the handle reaches max and shrinks the map'`:
     with the linux override, assert `sheetSize` starts at `initialChildSize`, call
     `dragHandle(tester, const Offset(0, -600), kind: PointerDeviceKind.mouse)`, `pumpAndSettle()`,
     assert `sheetSize ≈ maxChildSize` and `mapHeight < beforeMap`
     (`mapHeight` helper `:1202-1203`). **RED pre-fix:** pre-fix the key does not exist (no
     `GestureDetector`) and the scrollable ignores mouse, so the drag cannot grow the sheet.
     **GREEN post-fix.**
   - **(b) mouse drag DOWN from max collapses to min** — `'a mouse drag down from max on the handle reaches min and lifts the FAB'`:
     first drag up with the mouse (as in (a)) to reach max, then
     `dragHandle(tester, const Offset(0, 600), kind: PointerDeviceKind.mouse)`, `pumpAndSettle()`;
     assert `sheetSize ≈ minChildSize` and the FAB-above-panel assertion copied from
     `:1257-1261` (`fab.bottom <= AppBottomSheet.top`). **RED pre-fix** for the same reason.
   - **(c) mobile-inert guard test (not RED→GREEN)** —
     `'the mouse grabber is inert on Android and touch still resizes'`:
      set `debugDefaultTargetPlatformOverride = TargetPlatform.android;` (tearDown reset) and
      `pumpHome(tester, pickup: pickupPlace, destination: destinationPlace, surface: resizeSurface)`
      — the same fixture as (a)/(b), so the content-driven max is genuinely above the initial
      size and the touch-resize assertion is not vacuous. The `GestureDetector` at
     `ValueKey<String>('home-sheet-handle')` is **always present** (the platform gate only
     nulls its callbacks), so: assert
     `shouldEnableSheetDragHandle(isWeb: false, platform: TargetPlatform.android)` is false; get
     `tester.widget<GestureDetector>(find.byKey(...))` and assert `onVerticalDragStart`,
     `onVerticalDragUpdate`, `onVerticalDragEnd`, and `onVerticalDragCancel` are all `null`;
     record `sheetSize`; simulate a **mouse** drag by key
     (`dragHandle(tester, const Offset(0, -600), kind: PointerDeviceKind.mouse)`), pump, and
     assert `sheetSize` is unchanged (the recognizer is inert); then simulate a **touch** drag
     (`Offset(0, -600)`) and assert the sheet reaches `maxChildSize` through the existing
     scroll path. Label (c) a **guard test**, not a RED→GREEN test: it protects the gate and
     proves the mobile path is untouched. The existing touch tests
     (`home_screen_test.dart:1183-1348`, including the handle `Semantics` toggle at
     `:1315-1348`) must stay green.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
# targeted:
cd rider_app && flutter test test/features/home/presentation/home_screen_test.dart test/core/platform/sheet_drag_handle_test.dart
```

- `make flutter-analyze`/`make flutter-test` are **broken in this WSL tree** (they shell out to
  the Windows `melos.bat` through `cmd.exe`, which cannot `cd` the UNC path). Use the Linux FVM
  SDK + native Melos 8 at `~/.pub-cache/bin/melos`, as above. Run one Flutter agent at a time.
- **UNVERIFIABLE in this WSL harness:** real Chrome/desktop mouse behavior (the VM widget test
  only proves the recognizer drives the controller). Close on a host with a GUI target:
  run the rider app with `flutter run -d chrome` (or a Linux desktop target), then with a mouse:
  drag the grab handle → the panel grows to max and the map shrinks; drag down from max → it
  collapses to the handle-only min; release mid-drag → it snaps to the nearest of
  min/initial/max; a pointer leaving the window mid-drag settles at the nearest snap (no stuck
  mid-drag state); the mouse wheel and two-finger trackpad still scroll the booking form; a
  `StopList` reorder still works.

## Risks

- **Recognizer competition:** the sheet's scrollable accepts trackpad drags
  (`scroll_configuration.dart:29-37,120`), so the handle locks
  `supportedDevices: {PointerDeviceKind.mouse}`. The mouse never enters the scrollable's arena
  on desktop/web, and two-finger trackpad behavior stays on the existing scroll path
  (unchanged). If a future change enables `PointerDeviceKind.mouse` in `dragDevices`, the D1
  rejected alternative returns and the two recognizers would compete — keep the gate and do
  not enable mouse in `dragDevices`.
- **Turning off the gate leaves the existing scroll path intact:** on mobile the callbacks are
  null, so behavior is bit-for-bit the old path, and the `Semantics` toggle/label is unchanged.
  The `GestureDetector`/key still exists but registers no recognizer.
- **Fling/snap feel:** programmatic `jumpTo`/`animateTo` bypass the sheet's snap, so the
  end-of-drag snap is ours; a wrong velocity sign or clamp could land off-snap. The (a)/(b)
  tests plus the on-host close cover the reachable states; hoist the snap-size list to one
  helper so `_togglePanelSize` and the drag end cannot disagree about `initial`.
- **Cancelled drag:** on web a pointer leaving the window cancels the vertical drag. Both
  `onVerticalDragEnd` and `onVerticalDragCancel` funnel into `_settleSheetDrag`, so a cancel
  lands on the nearest snap (velocity 0) and clears `_sheetDragSize`; never leave the sheet
  mid-drag with stale drag state.
- **Physics non-change:** no `AlwaysScrollableScrollPhysics` is added — the sheet controller
  already injects it (`draggable_scrollable_sheet.dart:810-820`), so adding one would be a
  no-op. The mouse wheel path is unchanged because the scrollable's `dragDevices` still
  excludes mouse.

## Landing checklist

- [ ] `[home]`'s Landed line in `rider_app_plans/STATUS.md:198-206` ("the handle is a 48 dp
  `Semantics` min↔opening-size toggle with **no** `GestureDetector`") is amended to describe the
  desktop/web grabber and the unchanged mobile scroll path.
- [ ] The source comments at `home_screen.dart:340-342` and `:661-664` describe the grabber, not
  "no second drag recognizer".
- [ ] The 2026-10-08 "no second drag recognizer" lock (git
  `62a6019^:rider_app_plans/[home]_bottom_panel_resize.md`, D4) is recorded as **superseded for
  desktop/web only** in Landed `[home]` (the mobile lock survives via the platform gate).
- [ ] Known bug **#32** is flipped to **FIXED** with post-fix `file:line` evidence (handle
  builder, mouse-only `supportedDevices`, drag handlers incl. cancel, predicate file, tests).
- [ ] RED→GREEN observed for (a)/(b); the (c) mobile-inert guard test and the existing touch
  tests are green.
- [ ] `melos run analyze` clean and `melos run test` green (or a recorded, honest exception).
- [ ] Dangling-`depends_on` re-checked for every rider plan (this plan is `[]` and unnumbered).
- [ ] On-host Chrome/desktop mouse close recorded (or explicitly left UNVERIFIABLE in WSL).
- [ ] Plan file deleted and condensed into `rider_app_plans/STATUS.md` after
  `antagonistic-reviewer` confirmation.
