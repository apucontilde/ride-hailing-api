---
tag: search
depends_on: []
status: open
---

# Throttle place autocomplete

Excessive `GET /places/autocomplete` requests from two rider-side amplifiers. The backend
endpoint is already real (`internal/handler/platform.go:169-219` `PlacesAutocomplete`);
this is pure rider-app work.

**Read first:**

- `rider_app/lib/features/home/presentation/location_search_screen.dart`
- `rider_app/lib/features/home/data/home_provider.dart`

## The two amplifiers (verified)

1. **No debounce** — `location_search_screen.dart:50-52` `onChanged` → `setState(() => _query =
   value)` fires a `placeSearchProvider` request on every keystroke.
2. **Radius upscaling loop** — `home_provider.dart:51,58-73` `placeSearchProvider` iterates
   `_radiusSteps = [1000, 3000, 10000, 30000]` m and fires **up to 4 sequential requests** per
   query (`58` for-loop), returning the first non-empty result.

## Work

1. Add a **debounce** on the query (e.g. ~300–400 ms) before `placeSearchProvider` is invalidated
   — either a timer in `location_search_screen.dart` or a `Debounce`/`Duration`-carrying arg in
   the provider. Make it testable (inject a clock/ticker).
2. **Collapse the radius escalation**: send one request with the widest relevant radius (or a
   single fixed radius), drop the sequential `_radiusSteps` loop. If stepwise widening is still
   desired, cap it to a bounded number of steps with a maximum and a lower-frequency (or
   single-shot) pause.
3. Keep the `PlaceSearchArgs` provider contract compatible (or update the one consumer,
   `location_search_screen.dart`).

## Tests

- `home_provider_test.dart` / `location_search_screen_test.dart`: injected clock → only one
  request per debounce window; a single radius param; no 4-sequential-request burst.

## Accept

- Keystroke stream yields one (debounced) autocomplete call, not one per keypress.
- Radius escalation sends at most one request per query (no 4× fan-out).

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```