---
tag: elevation
depends_on: ["04_[elevation]_calibration_and_rollout_gate.md"]
status: open
---

# Stage 05 — DEFERRED: duration model, response fields, and pgRouting parity

**Status: OPTIONAL. Do not build until stage 04's gate passes *and* the product question in
stage 04 is answered.** Nothing in the route-picking objective needs this file. It is collected
here because all three items are the "everything that is not the feature" remainder, and
because stages 02 and 04 forward-reference it.

Depends on: `04_calibration_and_rollout_gate.md`.

## Context

**Read (nothing else):**

- `api_plans/STATUS.md` — invariant 1 and invariant 7.
- `api_plans/04_[elevation]_calibration_and_rollout_gate.md` — the gate verdict and the open
  product question.
- `internal/service/navigation.go` — the whole file (60 lines). `totalDistance` is
  `int(nodes[last].AggCost)` (`:41`) and `totalDuration := totalDistance / 11` (`:43`).
- `internal/service/fare.go:33-41` — the time fare is `(dur/60)·timeRate`, so **changing
  duration changes prices**.
- `tests/testutil/mock_navigation_repo.go` — returns a fixed 5000 m / 454 s route; **several
  tests assert those exact numbers** (AGENTS.md env fact 7). This is the file that will break.
- `rider_app/lib/features/home/data/home_provider.dart:94-95` and
  `driver_app/lib/features/trip/providers/trip_notifier.dart:180-181` — how the two apps read
  the route response. **Corrected after review:** the first draft said "both apps read it with
  plain map access, not `fromJson`". The driver app does read the map directly
  (`json['total_distance_m']`), but the rider app has a **hand-written**
  `NavigationRoute.fromJson(Map<String, dynamic>)` factory that indexes `json['…']` per key.
  The backward-compatibility conclusion is unchanged — a hand-written factory ignores unknown
  keys, so an *additive* response field needs no Dart change either way — but the reason is
  "neither app uses `json_serializable`", not "neither app has a parser". That distinction
  matters the moment either app is migrated to code generation with strict key handling, at
  which point this argument must be re-checked.
- `api_plans/STATUS.md` — for the parity work below.

**Needs a DB?** Only for the parity item.

---

## Item A — Additive response fields (small, safe, useful)

**Add, do not change.** `GET /api/v1/navigation/route` currently returns
`{polyline, total_distance_m, total_duration_s}` (`internal/handler/platform.go:420-424`).
Add three sibling fields:

```json
"total_ascent_m": 412.0,
"total_descent_m": 388.0,
"elevation_aware": true
```

- `total_ascent_m` / `total_descent_m` come from `routing.Path.AscentM` / `DescentM` (raw
  metres, **not** the weighted quantity the search minimized — stage 01's doc comment says so
  and this is where it matters).
- `elevation_aware` is a **per-response** boolean, not a server-wide setting: with stage 02's
  coverage gate, elevation can be on for one region and off for another in the same process.
  A client that wants to show a "flat route" badge needs to know whether the number means
  anything.
- `false`/`0` when elevation routing is off or the region has no coverage. Never omit the keys
  — a stable shape is worth more than three fewer bytes, and the apps' `?? 0` patterns are not
  a contract.

**Plumbing:** `RouteResult` gains `AscentM`, `DescentM`, `ElevationAware` (set on the last row,
mirroring the existing `AggCost` convention at `navigation_repo.go:144-146`) →
`service.RouteInfo` gains the same three → `handler` emits them → `responses.go` /
`scripts/update-openapi.sh` regenerate the spec.

**Verification:** existing route tests unchanged and green (additive fields do not affect
them); a live curl shows the three keys with and without `ROUTING_ELEVATION=on`; the two
Flutter apps are unaffected (they never read these keys) — state that explicitly, because
"we changed the API" is otherwise a review-blocking claim that turns out to need no app work.

**Blocked on:** the stage-04 product question. This is the *input* to that decision, not the
decision.

---

## Item B — Grade-aware `total_duration_s` (expensive; probably not worth it yet)

**Today:** `totalDuration := totalDistance / 11` — one flat 11 m/s (~40 km/h) for everything
(`internal/service/navigation.go:43`).

**The model:** in the same per-edge walk that already produces `Meters`/`Cost`, accumulate
`DurationS += meters / v(grade)` with a speed function, e.g.
`v(g) = v0 / (1 + kUp·g)` for `g > 0` and `v(g) = v0·(1 − kDown·|g|)` for `g < 0`, clamped to a
band (`kUp ≈ 0.35`, `kDown ≈ 0.15`, `v0 = 13.9` m/s ≈ 50 km/h, floor 2.5 m/s ≈ 9 km/h on a
real ramp). The constants are **proposals** and must be calibrated against real drive times
before shipping — a wrong speed curve produces confidently wrong ETAs and wrong fares.

**Why this is expensive (the blast radius, listed so nobody underestimates it):**

1. `routing.Path` needs a `DurationS` field, accumulated in the same walk — a second
   `internal/routing` change after stage 01.
2. `RouteResult` needs a `DurationS` field (last-row convention), which means
   **`tests/testutil/mock_navigation_repo.go` must be updated** to emit 454 s explicitly, and
   every test asserting 454 s must be re-checked. AGENTS.md env fact 7 calls this file out
   for a reason; do not discover it at the end.
3. `service/navigation.go` must switch from `distance/11` to the computed value — with a
   **documented fallback** to the current formula when the repo does not supply one, or every
   mock-backed and estimate-backed path silently reports 0 s.
4. `FareService` prices the **time** component from it (`fare.go:40`), and the quoted fare is
   snapshotted onto the ride at booking (`service/ride.go:36-53`) — so a wrong duration model
   is wrong *money*, permanently, for every ride quoted while it is deployed.
5. Both apps display duration; neither needs a code change, but users will notice.

**Recommendation:** ship Item A, keep `distance/11` for now, and treat Item B as a separate
plan with its own calibration data. A better *route* is worth having today; a better *duration*
model is a pricing change and deserves its own evidence.

---

## Item C — pgRouting parity (closes the divergence stage 02 logged)

Stage 02 made the divergence explicit: with `ROUTING_ENGINE=pgrouting`, `pgr_dijkstra` reads
`road_network_edges_pgr.cost`, which is still pure meters, so it returns the flat-optimal
route while the native engine returns the elevation-aware one. Same OD pair, two deployments,
two answers.

**Do not** fix this by writing a weighted `cost` into `road_network_edges_pgr`. That column is
the meters contract that `total_distance_m`, the fare, and pgRouting's own `agg_cost` all
depend on (`api_plans/STATUS.md` is explicit: don't "fix" it).

**The clean fix** is an extra, explicitly-named column plus a *separate* cost graph, chosen
per engine at query time:

```sql
-- 016_edge_elevation_costs.up.sql (NOT created; only if/when parity is wanted)
ALTER TABLE road_network_edges_pgr
  ADD COLUMN IF NOT EXISTS cost_ascent DOUBLE PRECISION;  -- metres + w*ascent, fwd
ALTER TABLE road_network_edges_pgr
  ADD COLUMN IF NOT EXISTS reverse_cost_ascent DOUBLE PRECISION;
```

and a second `edges_sql` (`SELECT id, source, target, cost_ascent FROM … WHERE cost_ascent IS
NOT NULL`, with `reverse_cost`) for an `elevationAwareEdgesSQL` constant beside the existing
`edgesSQL` (`pgrouting_repo.go:15`), selected by the same flag. Note the reverse direction needs
`reverse_cost`, which **does not exist** on the 011 table today (plan 03: do not write an
`edges_sql` that references it) — so parity needs a migration adding `reverse_cost` and
populating it, not just a new cost column. **That is the real scope of this item**, which is
why it is not in stages 01–04.

Given plan 03's recorded verdict (the pgRouting gate was NOT met; `native` is production and
pgRouting serves long-haul legs where this does not matter), **parity is low priority**. The
correct action today is the stage-02 warning, which is already written.

---

## Verification (whenever any of this is built)

- `make test` and `make test-integration` green. For Item B specifically: grep the test suite
  for `454` before and after — a changed count of assertions on the mocked duration means the
  contract moved.
- A live curl diff showing the new fields, and confirmation that the response is still valid for
  both app parsers (direct map access in the driver app, a hand-written `fromJson` factory in the
  rider app — both tolerant of unknown keys, so no Dart change).
- For Item C: the same OD pair routed through both engines with elevation on, compared, and the
  expected difference documented rather than papered over.

## Decisions Recorded

- **Route picking first, duration later.** They are different objectives with different risk;
  the second one moves money.
- **Additive response fields, never a changed field.** `total_distance_m` keeps its exact
  meaning (series invariant 1) no matter what this file does.
- **The divergence is logged, not fixed.** pgRouting is not production for city hops (plan
  03's gate), so parity is a documentation problem now and a migration problem later.
- **`MockNavigationRepo` is in the blast radius of Item B** and is named here so it is not a
  surprise.

## Alternatives & Future

- **Serve the flat and the elevation-aware route as two named alternatives** (a
  `?profile=flat|elevation` parameter or a second endpoint) and let the client pick. This is
  the cleanest long-term shape, and it is the only version that does not force the product
  decision on riders. Needs app work; out of scope here.
- **A `/route/elevation-preview` endpoint** for a driver-side "show me the flat way" control —
  the same capability, cheaper to ship, no change to the default route.
- **Push Item C into `api_plans/STATUS.md`'s routing series** rather than keeping it here, if pgRouting ever
  returns to being a city-hop engine. It is an engine-parity concern, not an elevation one.
