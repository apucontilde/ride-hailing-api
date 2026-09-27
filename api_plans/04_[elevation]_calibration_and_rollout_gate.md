---
tag: elevation
depends_on: ["03_[elevation]_dem_ingest_and_noise_control.md"]
status: open
---

# Stage 04 — Calibration, acceptance suite, and the rollout gate

**Goal.** Turn "elevation-aware routing is implemented" into "elevation-aware routing is
**measured, falsifiable, and decided**". This stage finds real origin–destination pairs in the
live data where the feature changes the answer, quantifies the change, measures the cost, and
records an explicit **go / no-go** for flipping `ROUTING_ELEVATION` — the same discipline
`api_plans/STATUS.md` applied to its pgRouting gate.

Depends on: `03_dem_ingest_and_noise_control.md` (real `elevation_m` on the live vertices, and
the grade histogram from its diagnostics).

> ⚠ **This stage's original gates are pre-falsified and must be re-derived (`[elevation]_review.md`
> §3.1–3.7, §4.2, §4.5).** Two independent problems, both measured on the real `skadi` DEM
> over 2,000 random OD pairs:
> 1. **The "flat control area" was not flat** — `lat 9.90–10.00, lng −84.12…−84.02` spans
>    986–1,358 m, i.e. **371 m of relief**. Every gate anchored to it was a gate on a slope.
> 2. **The provisional defaults barely do anything** — at `1.5 / 0.3 / 0.15 / 3` the median
>    ascent ratio is **1.0000** and the median meters ratio **1.0001**; only **45 of 2,000**
>    pairs even meet the climb-avoidance filter, and the "top N" filter left 3,763/5,101 =
>    **0.737** against a 0.6 bar.
>
> **Consequence: this stage is sweep-first, gate-second.** The first deliverable is the measured
> response curve, not a flag flip. Every threshold in the original draft is a *hypothesis*, and
> the numbers below that the review could not falsify are retained verbatim.

## Context

**Read (nothing else):**

- `api_plans/STATUS.md` — invariants 1 and 3, and the verified-facts table.
- `api_plans/01_[elevation]_directional_cost_model.md` — the Part 2 trade-off this stage must
  now *measure*: as `heuristicScale` (= `1 - DescentW·MaxGrade`) shrinks, A\* prunes less and
  the search gets slower.
- `api_plans/02_[elevation]_elevation_column_and_repo_plumb.md` — the config knobs and their
  (deliberately provisional) defaults.
- `api_plans/03_[elevation]_dem_ingest_and_noise_control.md` — the MEASURED block (grade
  histogram, `short − long` tripwire, known-flat-street `Δz` spread). **Stage 04's `DeadbandM`
  is set from the flat-street spread** (measured by the replacement estimator in *stage 03's*
  Part 4a), not from the code default. The `short − long` delta is *not* a calibration input:
  measured on real data it is 1.00×, so it carries no signal.
  *(Note: this stage has its own Part 4a, the weight sweep. The two are unrelated.)*
- `api_plans/STATUS.md` — the format of a decision gate that was
  actually executed (the `GATE RESULT` block). Match its honesty: numbers, verdicts, and a
  recorded recommendation — not a plan to decide later.
- `internal/routing/benchmark_test.go` — `BenchmarkRouteElevated` as landed by stage 01.
- `internal/repository/pgrouting_repo_benchmark_test.go` — the precedent for an
  integration-tagged, DB-backed benchmark.

**Write:**

- `internal/repository/elevation_acceptance_integration_test.go` *(new — the whole suite)*
- `internal/routing/elevation.go` — **exactly one addition**: an `Expanded int` counter on
  `Path`, incremented once per node popped. Nothing else in `internal/routing` may change in
  this stage. This is the one sanctioned cross-stage edit; if the suite seems to need more,
  that is a finding, not a licence.
- `api_plans/04_[elevation]_calibration_and_rollout_gate.md` — this file, with the results and
  the gate decision.

**Do NOT touch:** `internal/repository/navigation_repo.go` and `pgrouting_repo.go` (stage 02's
output is an input here, not something to retune), `internal/service/*`, `internal/handler/*`,
migrations, `scripts/*`, the Flutter apps.

**Needs a DB?** Yes — the entire suite runs against the live SJ import with real elevations.

## Problem

Three things are true at the end of stage 03 and none of them is evidence:

1. The engine *can* prefer a flatter route. That is a claim about a cost function, not about
   this city.
2. The deadband default (3.0 m) was chosen from a datasheet, not from **this** DEM on **this**
   network — and Part 3's measurement shows it is far too small: 3 m touches 59.5 % of edges
   while **25.1 % of edges carry 3–10 m of |Δz| (mean 5.43 m)**, a band the deadband does
   nothing about and the grade cap then prices as a full uphill surcharge.
3. Nothing has shown the change is *net positive*. A route that is 3 % longer and 2 % slower
   is **more expensive for the rider** (`FareService`: `dist/1000·distRate + (dur/60)·timeRate`,
   `internal/service/fare.go:39-40`) — so "flatter is better" is a **product trade the rider
   pays for**, not a free win. See *Open product question* below; it is not the plan's to
   close.

## Current State (verified 2026-09-25)

- Live DB: 152,665 vertices / 183,371 edges, province bbox lat `8.9885…10.2369`,
  lng `−84.5361…−83.3905`. 30.5 % of edges are under 40 m. `elevation_m` is NULL everywhere
  until stage 03 runs.
- The province bbox contains real relief: **Cerro de la Muerte (9.5497, −83.7699) is 3,491 m**
  and sits inside the clip, so the imported network spans roughly 3,500 m of vertical range.
  This is why SJ is an unusually good test bed for this feature and a misleading one for
  "typical" — see *Flat-area invariance* below for the control.
- Stage-01/03 synthetic baselines (`benchmarkGridGraph(400)`, plan 01/03 harness):
  `Route/hop` ~10.6 µs, `Route/corner` ~356 ms, `NearestNodeGrid` 160 ns, `NewGraph` ~120 ms.
- `NewGraph` currently drops `Cost <= 0` and unknown endpoints and does **not** validate
  elevation; stage 02's coverage gate is the only place that decision is made.

## Solution

### Part 1 — The harness

One integration-tagged file,
`internal/repository/elevation_acceptance_integration_test.go`, building the **real** graph the
way `NativeNavigationRepo.roadGraph` does (same `loadNodes`/`loadEdges`/`NewGraph` path, so the
test measures production behaviour) and exposing four helpers:

```go
// pair is a fixed, seeded origin/destination used by every sub-test, so
// failures are reproducible and numbers are comparable run to run.
type pair struct{ fromLat, fromLng, toLat, toLng float64 }

func seededPairs(t *testing.T, n int, b [4]float64) []pair  // rand.NewSource(42), filtered to the bbox
func routeWith(t *testing.T, g *routing.Graph, p pair, w routing.CostWeights) *routing.Path
func report(name string, rows []row)  // prints a table under `go test -v`
```

`rand.NewSource(42)` is deterministic across runs and machines — a hard requirement, since
every threshold below is asserted against a fixed sample. Log the sampled pairs so a failure
can be reproduced by hand with a `curl`.

### Part 2 — Flat-area invariance (the anti-regression gate)

**This is the check that matters most, and it is the one that would catch a broken DEM.**

The control area must be **demonstrably flat, and the demonstration is the first step.** The
original draft picked `lat 9.90–10.00, lng −84.12…−84.02` by eye and asserted "a few tens of
metres of relief". Measured on the real DEM it spans **986–1,358 m — 371 m of relief.** Every
conclusion drawn from that box (including a passing invariance result) was a conclusion about a
slope, and a "flat" test that quietly contains a 371 m hill is worse than no test: it can only
fail for the wrong reason, or (with enough deadband) pass while the DEM is biased.

**Step 1 — certify the control area.** Do not pick a box by eye. Derive one:

```sql
-- On a 0.005° lattice over the metro area, keep cells whose 4 corners are
-- all within 15 m of the cell minimum, and that contain >= N routing
-- vertices. The union of the largest such cluster is the control area.
-- Record the measured min/max elevation and the vertex count in MEASURED.
```

Bar for "flat enough to be a control": **total relief ≤ 15 m across the whole box** and ≥ 500
routing vertices. If no such cluster of that size exists, the box grows until it does, and the
final measured relief is recorded — an uncertified control area is not a control.

**Step 2 — invariance.** Restrict the seeded sample to the certified box. For each pair, route
with the zero weights and with the calibrated weights.

> **Assert:** at least **95 %** of pairs return the **identical node path** (not merely a
> similar distance), and no pair's `Meters` grows by more than **2 %**.

Rationale: on genuinely flat ground with a well-damped DEM, the elevation term should be ~0 and
the search should return today's route. If it does not, the DEM has a bias, the deadband is too
small, or the weights are wrong — and the feature is actively harmful in the largest class of
deployment (flat cities are most of the world). **Symmetrically, this is why the feature must
stay opt-in until it passes: a city that is 5 % of the way up a hill should not get hill
routes.**

**The 95 %/2 % numbers themselves are unvalidated** — they were never run against a certified
flat box. Record the observed rate as the baseline and set the bar from it.

### Part 3 — Finding real climb-avoidance cases (do not invent them)

The objective case — "the short route climbs a ridge, the longer one contours it" — must be
**discovered from the live data**, not asserted from imagination. Method:

1. Seed 2,000 OD pairs across the province bbox (the hilly area). **Pairs that do not snap or
   do not route are not failures and are not silently dropped** — count them separately, record
   the count and the reason (`no route within snap radius`, `unreachable component`), and
   **exclude them from every ratio** in Parts 3 and 4. A ratio whose denominator quietly loses
   its unroutable pairs is not comparable to a run where the sample lands differently, and
   `seededPairs` must return both the routable set and the rejected set so the test can assert
   the rejection count rather than have it vanish.
2. For each, route flat and route elevation-aware with the calibrated weights.
3. Score `Δ = AscentM_flat − AscentM_elev`, keep pairs where
   `AscentM_elev < 0.75 · AscentM_flat` **and** `Meters_elev ≤ 1.05 · Meters_flat`.
   This filter is applied **before** ranking, so the "top N" set is drawn from the qualifying
   population — not from all 2,000 pairs, of which the large majority have `AscentM_elev ==
   AscentM_flat` (ratio 1.000) and would dominate any naive sort. The review's measurement of
   the *unfiltered* top-5,101 as 3,763/5,101 = 0.737 shows exactly that failure mode.
4. Sort the qualifying set by `Δ` descending. **The top 10, with coordinates, are the
   demonstration set** — print them. A human drives/looks at those ten and confirms the choice
   is the one they would make. The test asserts only that such pairs **exist** and that their
   properties hold; the judgement that the route is *better* is human, and the plan must not
   pretend otherwise.

> **Assert (revised):** ≥ 20 pairs satisfy the filter, **and** the report records the qualifying
> count. The `< 0.6·AscentM_flat` bar on the top pair is **dropped as an assertion** — it was a
> single-pair statistic with no measured support, and a demo whose headline is one lucky pair
> is a demo that will regress on the next re-import. The *distribution* in Part 4 is the
> claim; one pair is the illustration.

**Pre-falsified at the provisional defaults:** only **45 of 2,000** pairs clear the Part 3
filter, and the median ascent ratio across all pairs is **1.0000**. So at `1.5/0.3/0.15/3` the
feature is, for the typical trip, *measurably indistinguishable from off*. Do not run the gate
at these values and read the failure as "the DEM is bad" — it is the weights. That is what
Part 4a exists to find.

If zero pairs qualify, that is a **real finding, not a test failure**: the feature has nothing
to do on this network, and the gate in Part 6 must record that honestly. A demo dataset that
cannot produce a single genuine case means the default stays off.

### Part 4 — Distribution + the trade we are making

Print, over the same routable pairs, the median and p90 of: `Meters` ratio
(`elev/flat`), `AscentM` ratio, polyline point-count ratio, and wall-clock per route for both.

> **Targets (hypotheses, not gates — measured values at the provisional defaults are
> 1.0000 / 1.0001, i.e. no effect at all):**
> - median `Meters` ratio ≤ **1.02** — the typical trip gets ≤ 2 % longer;
> - p90 `Meters` ratio ≤ **1.10** — the tail is bounded;
> - median `AscentM` ratio ≤ **0.85** — the typical trip gets ≥ 15 % flatter;
> - **p99 `Meters` ratio ≤ 1.25** — hard ceiling, no pathological detour ever ships. If this
>   is violated, the correct fix is a **detour cap** (a second pass bounding
>   `Meters ≤ (1+cap)·flatMeters` for the same OD), not a smaller weight.

The last bullet is the guard against the classic failure of weighted shortest-path routing: a
route that is 40 % longer because one ridge was expensive is worse than the ridge. Note the
**tension between bullet 1 and bullet 4** — a median detour ceiling of 2 % and a p99 ceiling of
25 % are not independent knobs, and the sweep in Part 4a is what shows whether both are
simultaneously reachable at any weight setting. If they are not, that is the result.

**Every ratio above is defined only on pairs where both weight sets produced a route.** See
Part 3's unroutable rule; a denominator that silently changes between runs invalidates the
comparison to any previously recorded number.

### Part 4a — The sweep (this is the first deliverable; the gate is the second)

**Nothing here can be decided until the response curve is measured, and the pre-falsified
numbers say the defaults are in the flat, inert region of it.** So the stage runs the sweep
first, records the curve, and only then picks a point on it.

Sweep, over the same seeded routable pairs from Part 3, and print the full metric set for each
point — `Meters` median/p90/p99 ratio, `AscentM` median ratio, qualifying-pair count, and
`Expanded` delta:

| axis | values |
|---|---|
| `AscentW` | `0.5, 1.5, 3, 6, 12, 25` |
| `DescentW` | `0.0, 0.1, 0.3` (constrained by `DescentW·MaxGrade < 1`) |
| `MaxGrade` | `0.10, 0.15, 0.25` |
| `DeadbandM` | `{from Part 3's flat-street spread}, 3, 5, 8` — **the deadband axis matters most** and is the one the first draft got wrong |

Full cross-product is 216 runs × 2,000 pairs, which is fine as an offline sweep but must not
ship as a test; the **committed** test is a 4–6 point subset (`TestElevationWeightsSweep`),
chosen from the recorded curve to bracket the interesting transition, not chosen in advance.

**The output is a `WEIGHT RESPONSE` block in this file** — a table plus the chosen point and
its justification. Two properties must be visible in it or the weights are wrong:

1. **Monotonicity.** As `AscentW` rises, median `AscentM` ratio falls and median `Meters` ratio
   rises. A flat or non-monotone response means a sign error or a deadband/cap interaction, not
   a tuning problem. This is the single most valuable assertion in the stage and it is free.
2. **A usable operating point.** There exists a setting where median `AscentM` ratio is
   meaningfully < 1 while median `Meters` ratio stays within the Part 4 targets. If the curve
   has no such point — i.e. every weight that climbs-avoids also detours past the ceiling — then
   **the verdict is "the detour cap is required", and that is a real, publishable result**, not
   a reason to keep tuning forever.

The deadband deserves its own line in the report, because of the measured pathology in Part 3:
as `DeadbandM` rises past the 3–10 m noise band, the median `AscentM` ratio should improve
markedly. If it does not, the DEM's error is spatially correlated (a tilt), and no deadband
will fix it — that finding is what would justify the k-hop smoothing in *Decisions Recorded*.

### Part 5 — Cost of the feature

- `Path.Expanded` (the one sanctioned `internal/routing` addition) is reported for both weight
  sets on the same pairs. Expect the elevation run to expand **more** nodes: its heuristic is
  `heuristicScale · haversine` with `heuristicScale = 1 - DescentW·MaxGrade ≈ 0.955` at the
  default weights, and the edge costs are no longer proportional to distance, so both the
  pruning power and (slightly) the heuristic's consistency margin change. **Quantify it**; do
  not assume it.
- Re-run `make benchmark` and record `BenchmarkRoute/{corner,hop}` against
  `BenchmarkRouteElevated/{corner,hop}`. **Not "must be unchanged"** — stage 01 established
  that the zero-weight path is *behaviourally* identical (same path, same meters) but not
  *performanceally* identical, because the `metersScore` map and the `Path` return type are on
  the flat path too. Compare against stage 01's own `MEASURED` block on **this** machine; the
  plan-01 figures (`~1.4 µs` / `~267 ms`) came from different hardware and are not a baseline.
- Add an integration-tagged real-data benchmark in the same file,
  `BenchmarkRouteRealSJ/{flat,elev,hop,corner}`, over the live 183k-edge graph, and record the
  absolute numbers. This is also the input plan 06 needs for its per-region memory/latency
  budget (currently ~150–200 MB and "µs per call" per city).
- **If the elevation search is more than ~2× the flat search**, the honest options are (a) keep
  it behind the flag, (b) shrink `DescentW` to raise `heuristicScale`, or (c) pursue a proper
  speedup (dense node indices, ALT landmarks). Record which, and why. Do **not** ship a
  2×-slower hot path silently in the name of a nicer route.

### Part 6 — The rollout gate

Fill in a `GATE RESULT` block in this file in the style of `api_plans/STATUS.md`, and record:

| # | Criterion | Bar | Result |
|---|---|---|---|
| G1 | Flat-area invariance, on a **certified** flat box | ≥ 95 % identical paths, no pair > +2 % meters | |
| G2 | Genuine climb-avoidance cases exist | ≥ 20 qualifying pairs, and the qualifying count reported | |
| G3 | Typical-trip detour | median `Meters` ratio ≤ 1.02 | |
| G4 | Detour tail | p99 `Meters` ratio ≤ 1.25 | |
| G5 | Hot-path cost | `BenchmarkRouteRealSJ/elev` within the bound agreed in Part 5 | |
| G6 | Deadband calibration | `DeadbandM` set from the **known-flat-street `Δz` spread** (stage 03 Part 4a), written into `config.go` with the measured justification | |
| G7 | Monotonicity | median `AscentM` ratio falls monotonically as `AscentW` rises across the sweep | |
| G8 | Engine precondition | the flip is recorded against `ROUTING_ENGINE=native`; the gate **fails** rather than flipping on `pgrouting`, where the flag is inert | |

**Engine precondition (`G8`) — why it is a gate and not a note.** `ROUTING_ENGINE` defaults to
`native` today and plan 03 may flip it. `NativeNavigationRepo.elevationEnabled` is consulted
only inside the native repo's own route path; on the pgRouting path the flag is accepted,
logged, and **has no effect** (stage 02 Part 4). So a gate run after plan 03's engine swap
would pass every quality criterion and deliver **zero** behaviour change, and a later flip of
`ROUTING_ELEVATION`'s default would be a silent no-op in production. The gate must therefore
assert the engine it ran on, and the "flip the default" action is only valid while that engine
is native. This is the main coupling between this series and plan 03, and it is the reason
invariant 2 (native-only) has to be re-checked at flip time rather than assumed.

**Decision policy, fixed in advance so it cannot be rationalised afterwards:**

- **All eight pass** → flip `ROUTING_ELEVATION`'s documented default to `on` **for the native
  engine only**, in a **separate, clearly-labelled commit**, and update `.env.example`,
  `AGENTS.md` and the series README. Keep the flag itself.
- **G1 fails** → the DEM or deadband is wrong. Stay `off`; fix stage 03; re-run. A failure here
  is disqualifying regardless of the other seven.
- **G2 fails** → stay `off` and record that the feature has no demonstrated benefit on real
  data. Do not ship an unexercised cost function.
- **G3/G4 fail** → stay `off`, tune the weights, re-run. If tuning cannot satisfy both, the
  answer is the detour cap, not a bigger ascent weight.
- **G5 fails** → stay `off` until the speedup work lands, whatever the route quality is.
- **G7 fails** → stay `off` and treat it as a code bug (sign error or deadband/cap interaction),
  not a tuning problem.
- **G8 fails** → the results are still recorded, but **no flip**: re-run against the native
  engine. Never flip a flag that the configured engine ignores.

Whatever the outcome, write the verdict in this file, in this series' style: numbers, the
reasoning, and the follow-up. A gate that ends without a recorded verdict has not been run.

### Open product question (escalate; do not decide here)

**Who pays for "flatter"?** With the current rate card, a route that is +3 % distance and
+2 % duration is **+3 % on the distance fare and +2 % on the time fare** — the rider pays for
the driver's comfort and fuel economy. Options, in the order they should be considered:

1. **Do nothing** — accept it; flattery is a service-quality feature riders notice.
2. **Surface it**: expose `total_ascent_m` (stage 05) so the app can show "flat route" and
   the rider can choose. Requires product + app work. An **additive** JSON field is backward
   compatible with both apps, but note *how*: the driver app reads the response with direct map
   access (`driver_app/lib/features/trip/providers/trip_notifier.dart:180-181`), while the rider
   app has a hand-written `NavigationRoute.fromJson(Map<String, dynamic>)` factory
   (`rider_app/lib/features/home/data/home_provider.dart:94-95`) that indexes only the keys it
   knows. Neither uses `json_serializable`, so neither can be broken by an unknown key — the
   first draft of this plan claimed the rider app "parses with plain map access, not fromJson",
   which was wrong about the mechanism and right about the conclusion. **If either app is later
   migrated to `json_serializable` with a `disallowUnrecognizedKeys`-style strictness, this
   compatibility argument must be re-checked.**
3. **Cap the surcharge** so the rider's bill is bounded by a percentage — a fare-model change,
   well outside this series.

This is a business decision, not an engineering one. **Stage 04 measures the trade; the product
owner decides whether to make it.** Record the answer here when it exists.

## Tests to add (all in the one integration-tagged file)

- `TestElevationFlatAreaInvariance` — Part 2.
- `TestElevationFindsClimbAvoidanceCases` — Part 3, including the "assert the set is
  reproducible" check (the same seed must yield the same top pair across two runs).
- `TestElevationDetourBounds` — Part 4's p99 ceiling over the seeded sample.
- `TestElevationWeightsSweep` — a small table over
  `{AscentW, DescentW, MaxGrade, DeadbandM} ∈ {default, ascent-heavy, descent-heavy,
  no-deadband}`, printing the same metrics for each. Purpose: show the knobs actually trade
  distance against ascent monotonically, which is what makes them tunable rather than
  arbitrary. Assert only monotonicity of the ascent median as `AscentW` rises (**G7**) — a
  genuine property, and a cheap guard against a sign error in the cost model. The committed
  subset is chosen *from* the Part 4a curve, not in advance.
- `TestReportedMetersUnaffected` — for every case, `Meters` equals the sum of true edge lengths
  along the returned path (recomputed independently from `g.adj`), regardless of weights.
  Series invariant #1, asserted end-to-end on real data rather than only in stage 01's unit
  tests.
- `BenchmarkRouteRealSJ` — Part 5.

## Verification

1. `make test-integration` green; the output contains the five new tests plus the printed
   tables. Paste the tables into the `WEIGHT RESPONSE` and `GATE RESULT` blocks, **including
   the unroutable-pair count**.
2. `make benchmark` — `BenchmarkRoute/{corner,hop}` compared against **stage 01's `MEASURED`
   block on this machine** (not the plan-01 figures, different hardware); a regression is
   reported, not asserted away. `BenchmarkRouteElevated/*` recorded.
3. `make test` green (no DB).
4. A manual `curl` on the top-1 demonstration pair from Part 3, with `ROUTING_ELEVATION=on`
   and again with `off`, both pasted into the file. The rider-visible difference is the whole
   point; a human should look at the two polylines.
5. `gofmt -w internal/routing/elevation.go internal/repository/*_test.go && go vet ./...`.
6. The `GATE RESULT` block is filled in, including the verdict and the flip decision — or an
   explicit "not met, staying off" with the reason.

## MEASURED / WEIGHT RESPONSE / GATE RESULT

_(to fill. Three blocks, in this order, because they are produced in this order: the **sweep
curve** (Part 4a), then the **gate table** (Part 6) with the unroutable-pair count, then the
**verdict**. A gate result with no sweep curve behind it is not reviewable.)_

## Decisions Recorded

- **The thresholds are proposals, stated as such, and are revised in writing after the first
  run.** What is *not* provisional is the shape: a flat-area invariance floor, a genuine-case
  existence check, a median-detour ceiling, a p99 detour ceiling, a hot-path cost bound, and
  a monotonicity check. A plan with only a median is a plan that ships a 40 % detour to
  someone. **After the pre-falsification above, the *order* is also fixed: sweep first, then
  thresholds, then flip.** The first draft proposed to assert thresholds against a single
  default weight set that measurement showed was inert, which would have produced a confident
  "no-go" for the wrong reason.
- **A "flat" control area is certified, not assumed.** See Part 2 Step 1. The first draft's box
  contained 371 m of relief; a flatness control that is not flat converts every outcome into an
  uninterpretable one.
- **G1 (flat invariance) is disqualifying.** Optimising for a minority of hilly trips at the
  cost of degrading every flat trip is a bad trade for a platform whose majority of cities are
  flat. If the DEM is not clean enough to be a no-op on flat ground, it is not ready.
- **Demonstration cases are discovered, not authored.** A hand-picked pair proves nothing
  about the distribution; the seeded sweep plus a human check of the top 10 is the honest
  version.
- **A gate with no recorded verdict has not been run.** Same rule as plan 03.
- **The product question is escalated, not answered.** An engineer silently deciding that
  riders should pay for flatter routes is a scope error.

## Alternatives & Future

- **Multi-objective / Pareto routing** (offer the rider "fastest" vs "flattest"): the right long
  term, needs a second endpoint or a query parameter, and an app change. Stage 05's additive
  fields are the stepping stone.
- **Elevation-aware *time* rather than distance** (grade-dependent speed): arguably a better
  objective than ascent surcharge, since drivers care about time and fuel. It needs a
  speed-vs-grade model and it changes `total_duration_s` → fares → apps. Deliberately stage 05
  and opt-in.
- **Learned weights** (fit `AscentW` on driver traces): the honest long-term answer, and it
  needs data this platform does not have yet. Named so it is not reinvented.
- **k-hop elevation smoothing**, but **not** triggered by the `short − long` delta — that
  estimator measured 1.00× and demands nothing. The trigger is the Part 4a deadband axis: if
  raising `DeadbandM` past the flat-street noise band does **not** improve the median `AscentM`
  ratio, the error is spatially correlated and smoothing is the next move. Compute once at graph
  build, freeze, and re-run G1 — smoothing that improves G3 but breaks G1 is a bad trade and
  the gate will say so.

## Files to Modify

- `internal/repository/elevation_acceptance_integration_test.go` *(new, integration-tagged)* —
  the seeded sweep, the five tests, the real-data benchmark, the printed tables.
- `internal/routing/elevation.go` — **only** the `Path.Expanded` counter.
- `internal/config/config.go` — **only if G6 changes a default**: update the calibrated
  `DeadbandM` (and any other weight) with the measured justification in the comment, and record
  the before/after here. A weight change with no measured reason recorded is not allowed.
- `api_plans/04_[elevation]_calibration_and_rollout_gate.md` — results + verdict.
- If the gate passes: `.env.example`, `AGENTS.md`, and `api_plans/STATUS.md` get the
  flipped default, in a separate commit from the measurements.
