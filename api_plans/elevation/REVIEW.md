# Adversarial review — `api_plans/elevation/` (series v1, pre-implementation)

**Reviewed:** 2026-09-25, before any code was written. The whole series is a **proposal**;
nothing in stages 01–05 has been implemented.

**Method.** An independent reviewer was given the five stage docs and the repo, and three
instructions: *find missing context a fresh model would need*, *find over-broad or vague scope*,
and *find implementation defects a smaller model would fall into*. It was also asked to treat
the plan's own numbers as claims to be attacked. It did so partly empirically: it stood up a
throwaway implementation of the cost model, sampled the **real** DEM, and ran 2,000 OD pairs
rather than reasoning about them on paper.

Every finding below is dispositioned: **accepted** (fixed in the named file), **accepted with
correction** (the finding exposed the right problem with a wrong mechanism), or **rejected**
(with the reason). §6 lists what the review did *not* manage to falsify, because "the reviewer
found nothing wrong with X" is weaker than "X was tested".

---

## 1. Blockers — factual errors that would have broken the implementation

### 1.1 The DEM URL in stage 03 does not exist — **accepted, fixed**

Stage 03's first draft specified
`s3://elevation-tiles-prod/srtmgl1/N09W085.hgt` as the elevation source. There is no
`srtmgl1` prefix in that bucket. Verified live:

```
$ curl -sI .../srtmgl1/N09W085.hgt
HTTP/1.1 404  — ~290-byte XML <Error><Code>NoSuchKey>
$ curl -sI .../skadi/N09/N09W085.hgt.gz
HTTP/1.1 200  Content-Type: application/x-gzip   Content-Length: 7798473
```

The bucket's actual prefixes are `docs/ geotiff/ lib/ logs/ normal/ skadi/ terrarium/ v2/`.
Everything in stage 03 was written for a **raw 16-bit** `.hgt`; the served payload is
**gzipped** and needs `compress/gzip`. Nothing about the cost model, migration, or engine is
affected, but stage 03 as written could not have run.

**Fixed in** `03_dem_ingest_and_noise_control.md` Part 1 (source table now names the verified
`skadi` URL, keeps the 404 row as a recorded mistake, and states the gzip requirement) and
Part 2 (`ParseHGT(name string, gzipped []byte)`, dimensions validated *after* decompression,
`elevation_source` written as `skadi:<tile>`).

### 1.2 Stage 03's tile list is wrong in both directions — **accepted, fixed**

The first draft listed five tiles: `N08W085 N09W085 N09W084 N10W085 N10W084`. Bucketing the
152,665 live vertices by their own 1° tile gives:

| tile | vertices |
|---|---|
| `N08W084` | **7** (missing from the draft) |
| `N09W085` | 79,731 |
| `N09W084` | 38,141 |
| `N10W085` | 31,690 |
| `N10W084` | 3,096 |
| `N08W085` | **0** (included in the draft) |

Six tiles are *candidates* for the bbox; five are *needed*. The draft's error would have
produced 7 unmatched vertices and 12 half-elevation edges — failing the stage's own "0
unmatched" and "query 5 = 0" assertions, and, per stage 02 Part 3a, silently manufacturing
exactly the NULL-endpoint state that rule exists to prevent.

**Fixed in** `03` (tile table with the derivation, and the rule that the fetch set is driven
by the **vertex set**, not the bbox corners) and in the new `tiles_test.go` requirement, which
tests `tileNameFor(lat, lng)` as a pure function so a bbox-derived set cannot pass.

### 1.3 The "flat control area" is not flat — **accepted, fixed**

Stage 04's disqualifying gate (G1) was anchored to `lat 9.90–10.00, lng −84.12…−84.02`,
described as "a few tens of metres of relief". On the real DEM it spans **986–1,358 m — 371 m
of relief**. The most important anti-regression check in the series was measuring a slope, so
it could only ever fail for the wrong reason (or pass, if the deadband was large enough to
flatten a 371 m hill, which would have concealed a broken DEM).

**Fixed in** `04` Part 2, which is now two steps: **certify** the box from the data (relief
≤ 15 m, ≥ 500 vertices, measured relief recorded in MEASURED), then run invariance on it. The
95 %/2 % bars are also marked as unvalidated, with the observed rate to become the baseline.

### 1.4 Test count is wrong in two stages — **accepted, fixed**

`internal/routing/routing_test.go` contains **11** test functions, not 7 (seven exercise route
cost; four are `TestNearestNodeGrid*`). Two stages told a fresh context to keep "the existing
7" unmodified. A model that counted them and found 11 would reasonably conclude the plan had
read the wrong file. Corrected in `01` (Context, the Tests heading, and the Files section, with
the actual line numbers) and `04`.

### 1.5 Stale line references — **accepted, fixed**

`getFloat` is at `internal/config/config.go:129`, not `132-136`;
`NewRoutingRepository` is at `internal/repository/pgrouting_repo.go:70`, not `67-79`;
`benchmark_test.go`'s lattice is at `28-32`, not `35`. In a series whose entire premise is
that a fresh context reads *only* the named files, a wrong line number is an open door to
re-deriving a fact that was supposed to be given. Fixed in `01` and `02`.

### 1.6 The plan's framing of the import/elevation interaction is too weak — **accepted, fixed**

Stage 02 said a forced import "truncates the tables, so elevation is wiped", implying a race a
careful operator could sequence around. The stronger truth: `import-road-network.sh:318` runs
that `TRUNCATE` on **every** import path, and the importer **never writes `elevation_m` at
all** — so a post-import graph has **zero coverage by construction**, not stale coverage. The
coverage gate is the only thing standing between a routine re-import and silently-flat
routing, and nothing asserted that.

**Fixed in** `02` Part 5 (full restatement + the "do not fix this in the importer heredoc"
note, since `psql_run` has no `ON_ERROR_STOP`) and `03` (the runbook now ends `import →
elevation → restart`, and a **post-import coverage assertion that exits non-zero** is part of
the stage's verification rather than a nicety).

### 1.7 The rider app *does* have a `fromJson` — **accepted with correction**

Stage 05 stated that both Flutter apps read the route response "with plain map access, not
`fromJson`". The driver app does read the map directly; the rider app has a **hand-written**
`NavigationRoute.fromJson(Map<String, dynamic>)` factory that indexes `json['…']` per key. The
reviewer's conclusion — additive fields are safe — is **right**, and for a reason the plan did
not give: a hand-written factory ignores unknown keys, and neither app uses
`json_serializable`. Fixed in `05` and `04` (the same claim appears in the product-question
section), each now flagging that the argument dies if either app is migrated to code generation
with strict key handling.

---

## 2. Correctness defects in the specified model

### 2.1 `Validate` did not reject negative weights — **accepted, fixed (highest severity)**

Stage 01's `CostWeights.Validate` rejected `DescentW·MaxGrade >= 1`, `MaxGrade < 0`, and NaN.
It did **not** reject `DescentW < 0` or `AscentW < 0`, both reachable from environment config.

With `DescentW = -0.3, MaxGrade = 0.15`, `heuristicScale = 1 - (-0.3)(0.15) = 1.045`. The
heuristic then claims `cost >= 1.045 · haversine` while a descent edge actually costs **less**
than its meters. The heuristic is inadmissible *and* internally inconsistent, and A\* responds
by returning silently suboptimal paths — no error, no log line, no failed test. The lower-bound
proof in the same document assumed non-negativity on both branches; the code gate did not
enforce what the proof assumed.

**Fixed in** `01`: `Validate` now rejects negative `AscentW`/`DescentW` as a first-class case
with the failure mode spelled out, and `TestWeightsRejectNegative` was added with a sub-case per
rejected field (asserting both the error **and** flat-routing behaviour from
`RouteWithWeights`).

### 2.2 The cost identity was stated as if it were the shipped model — **accepted, fixed**

Stage 01 (and the series README) presented `cost(path) = meters + w·total_ascent` as *the*
model. It is only true with `DeadbandM = 0` and no clamp binding. The shipped model inserts a
deadband and a grade cap, so `g'·meters ≠ Δz` for most edges — measured at `DeadbandM = 3`,
the deadband touches **59.5 %** of edges and the cap **5.0 %**. The conclusion that "total
ascent is additive over edges, so this is a plain single-objective search" survives, but the
*quantity being minimized* is not total ascent, and stage 04's ascent-ratio thresholds were
written as if it were.

**Fixed in** `01` (the identity is now scoped to the deadband-free case, with the real
per-edge formula and the measured percentages) and the series README. `AscentM` is now
explicitly labelled a **proxy**, so `AscentM_flat / AscentM_elev` is a comparison across weight
sets, not a claim about the optimized objective.

### 2.3 `MaxGrade`'s scope was overstated — **accepted, fixed**

Stage 01 implied the grade cap bounds the elevation influence of a route. It bounds **one
edge**; a path of *n* steep edges still accumulates `n · meters · (1 + w·MaxGrade)`. There is
**no ascent budget, detour cap, or penalty ceiling anywhere in the model**, so a route can be
arbitrarily bad on the objective and still win. Stage 04's p99 distance ceiling is the only
guard, and it is a *measurement*, not a mechanism.

**Fixed in** `01` (a new "Part 2b — what the model does NOT do" section) and cross-referenced
from stage 04's Part 4, which already preferred "a detour cap, not a smaller weight" as the
remedy. The two now agree.

### 2.4 Partial coverage could reach the hot loop — **accepted, fixed**

The `MinCoverage = 0.99` gate is a whole-graph question and does not answer what the cost
function does with the ~1 % of edges that have a NULL endpoint. On this network that is ~1,500
NULL vertices and ~1,800 edges — a state that **passes** the gate. The two plausible
implementations are a nil dereference and a coalesce-to-zero, and the second is worse than a
crash: a 1,164 m vertex beside a `NULL` vertex is a 1,164 m grade, clamped to 22.5 % — a
permanent uphill tax on a flat road. The proposed tests only exercised coverage *below* the
gate (0.67, 0.98), i.e. the state that never reaches the hot loop.

**Fixed in** `02` Part 3a (new): an edge with any unknown endpoint contributes **zero**
elevation delta, never a coalesce-to-zero; the two implementation options (per-node known-bit
vs post-build propagation) are stated with a recommendation, and the implementer must pick one
and record it. `TestNativeRepoPartialCoverage` at coverage **0.995** is required, not 0.98.
Invariant 4 in the series README was strengthened to match.

### 2.5 A "log line is not a control" — **accepted, fixed**

Stage 02 warns when elevation is requested on a non-native engine. The reviewer's point:
`ROUTING_ENGINE` is a boot-time choice, so the combination is *knowable* at boot, and a warning
that nothing reads is not a control.

**Fixed in** `02` Part 4: one combined boot line (`routing engine=native elevation=on
coverage=… weights=…`) so one `docker logs | grep` answers "is this live here?", plus a new
gate **G8** in stage 04 that makes the engine a **gate criterion** — a gate run under
`ROUTING_ENGINE=pgrouting` would pass every quality criterion and deliver **zero** behaviour
change, and a later default flip would be a silent no-op in production. This is the main
coupling to plan 03, and it is the reason invariant 2 is re-checked at flip time rather than
assumed.

---

## 3. Gates that measurement contradicts

### 3.1–3.3 The provisional weights are inert — **accepted, fixed (restructured stage 04)**

At the code defaults `1.5 / 0.3 / 0.15 / 3`, over 2,000 random OD pairs on the real DEM:

- median `AscentM` ratio = **1.0000**
- median `Meters` ratio = **1.0001**
- only **45 of 2,000** pairs met the climb-avoidance filter
  (`AscentM_elev < 0.75·AscentM_flat` **and** `Meters_elev ≤ 1.05·Meters_flat`)

So the feature is, for the typical trip, measurably indistinguishable from off. The original
stage 04 proposed to run the gate *once* at these values and read a failure as "the DEM is bad" —
it would have produced a confident, wrong no-go, and the sweep that would have found the real
answer was written as a late "Tests to add" afterthought with four hand-picked weight sets.

**Fixed in** `04`: the stage is now **sweep-first**. A new Part 4a runs a 216-point sweep
(`AscentW ∈ {0.5,1.5,3,6,12,25}`, `DescentW ∈ {0,0.1,0.3}`, `MaxGrade ∈ {0.10,0.15,0.25}`,
`DeadbandM` including the stage-03 noise band) and records a `WEIGHT RESPONSE` block *before*
any gate is asserted. Two properties are mandatory in that curve: **monotonicity** (median
ascent falls as `AscentW` rises — free, and the best guard against a sign error) and the
**existence of a usable operating point**. If no point satisfies both the ascent target and the
detour ceilings, the verdict is "the detour cap is required" — a publishable result, not a
reason to tune forever. The committed test subset is chosen *from* the curve.

### 3.4 The deadband calibration estimator measures nothing — **accepted, estimator deleted**

Stage 03 proposed deriving `DeadbandM` from `mean grade on short edges − mean grade on long
edges`. Measured: **exactly 1.00×** (5.197 % vs 5.197 % over 55,906 short and 127,460 long
edges). Its premise was also wrong — an edge shorter than a DEM cell does not automatically
land on a different post, and the network's edges are not randomly placed relative to the DEM
grid. Worse, its decision rule ("small difference ⇒ lower the deadband") pointed the wrong way.

**Fixed in** `03` Part 4a: the estimator is **deleted**, and a replacement is specified that
isolates sampling noise by comparing grade against **DEM cell-boundary straddling**, plus a
better assumption-free check — the `Δz` spread along a handful of known-flat urban arterials.
The `short − long` query is kept, explicitly relabelled as a **tripwire** ("did the DEM change
underneath us"), never as a calibration input. Stage 04's `G6` was rewritten to match.

### 3.5 The deadband default is too small, and 5 m is not the fix — **accepted, corrected**

Stage 03 recommended raising the deadband to 5.0 m. The measured distribution says the deadband
at 3 m already touches 59.5 % of edges, and the band it does **not** touch is the noisy one:
**25.1 % of edges carry 3–10 m of |Δz| with a mean of 5.43 m**, which on a 30 m edge is an
~18 % grade. The deadband does nothing to that class; the clamp pins it at 15 %; the cost
function then prices it as a full 22.5 % surcharge. That converts random DEM noise into a
**systematic uphill tax** — the exact failure the section claimed to prevent.

**Fixed in** `03` Part 4 (the measured band is now in the table, and the deadband value is
declared an **open question owned by stage 04's sweep**, not a datasheet figure) and in the
series README's banner.

### 3.6 Unroutable OD pairs were not accounted for — **accepted, fixed**

Stage 04's ratios (`Meters_elev / Meters_flat`, `AscentM` ratios) are undefined for pairs that
do not snap or do not connect. The original text seeded from a bbox and said nothing about
them. A denominator that silently loses its unroutable members is not comparable to a
previously recorded run, and `seededPairs` returning only the routable set would make the loss
invisible.

**Fixed in** `04` Part 3 (unroutable pairs are counted, their reasons recorded, and excluded
from **every** ratio in Parts 3 and 4) and Part 4 (the same rule restated where the ratios are
defined). The unroutable count is a required field in the gate output.

### 3.7 The "top pair" assertion was unmeasured and the ranking was biased — **accepted, fixed**

G2 asserted "≥ 20 qualifying pairs, and the top pair's `AscentM_elev < 0.6·AscentM_flat`". Two
problems: a single-pair statistic with no measured support (it would regress on the next
re-import), and the ranking was ambiguous about its population — the review's unfiltered
top-5,101 came out at 0.737, which is what happens when a naive sort runs over 2,000 pairs of
which most have `AscentM_elev == AscentM_flat`.

**Fixed in** `04` Part 3: the filter is applied **before** ranking (stated explicitly), the
`< 0.6×` assertion is **dropped in favour of** reporting the qualifying count, and the top-10
set is kept as the *human-inspection* artefact it always was.

---

## 4. Other findings

### 4.1 The gzip download halves the git-ignore risk — **accepted, corrected**

Stage 03 asserted "130 MB of tiles must not be committed". That figure assumed uncompressed
`.hgt`. The five fetched tiles are **~39 MB** gzipped (~130 MB expanded). The git-ignore
requirement is unchanged; the number was not.

### 4.2 The benchmark baseline was taken on different hardware — **accepted, corrected**

Stage 04 required `BenchmarkRoute/{corner,hop}` to be "unchanged vs the stage-01 numbers" and
quoted plan 01's `~1.4 µs` / `~267 ms`. Stage 01 itself cannot claim a performance-neutral
refactor: the `metersScore` map is allocated and written on every improving relaxation
**including the zero-weight path**, and `Path` replaces a bare `[]int64` return. The default is
*behaviourally* identical (the existing tests prove it) but not *performanceally* identical.

**Fixed in** `01` (the current machine's baseline is recorded — `Route/hop 1.50 µs`,
`Route/corner 326 ms`, `NearestNodeGrid 169 ns`, `NewGraph 150 ms` — with an explicit "expect a
small regression, do not claim otherwise", and a threshold above which the map should become a
slice indexed by a dense node ordinal) and `04`.

### 4.3 The region flag depends on a column that does not exist — **accepted, noted**

Stage 03's `-region` flag is specified against a `region_id` column that plan 04 introduces
later. The stage already requires an `information_schema` probe and an error, which is the
right behaviour, but the coupling was not stated in the series README, so a reader could
reasonably read "-region" as available today.

**Fixed in** the series README's relationship-to-regions section, including a warning not to
"fix" the probe by hardcoding the province bbox.

---

## 5. Scope and context-model findings

- **Each stage's Context block was checked against the file list** and the read/write
  boundaries are explicit, including "Do NOT touch" lists. No finding. The
  `rand.NewSource(42)` determinism requirement in stage 04 exists precisely because the
  thresholds are asserted against a fixed sample, and the review confirmed that is necessary.
- **Stage 03 was the broadest** (a new `cmd/`, a new `Makefile` target, a new script, a parser,
  diagnostics, a runbook, and a data directory). It was left as one stage rather than split,
  on the grounds that splitting it would produce two stages that cannot be verified
  independently — the parser is worthless without the ingest that exercises it. Flagged here as
  a **judgement call, not a verified conclusion**: if an executor finds the stage too large for
  their context, the natural split is **03a** (parser + pure tile selection, no DB) and
  **03b** (ingest, diagnostics, runbook). The `tiles_test.go` / `hgt_test.go` requirements were
  deliberately written DB-free so that 03a is independently verifiable.
- **The series README's "Authoritative sources" listed `REVIEW.md` before it existed.** Fixed —
  the file now exists, and the README's own pre-falsification banner links into it.

---

## 6. What the review did NOT falsify

Recorded because silence is not evidence:

- **The A\* admissibility argument** (stage 01 Part 2) was re-derived and is sound, *given*
  non-negative weights — which is exactly why finding 2.1 matters. The proof also correctly
  identifies that `DescentW·MaxGrade < 1` is the binding constraint, not
  `DescentW < 1`.
- **Invariant 1** (`total_distance_m` stays true meters) is correctly traced end to end:
  `routing.Path.Meters` → `RouteResult.AggCost` → `service/navigation.go:41` →
  `FareService.CalculateEstimate` (`fare.go:33-41`). The hazard of writing weighted `Cost` into
  `AggCost` is identified and the correct alternative is named. Confirmed against the live code.
- **The `NavigationRepository.GetShortestPath` freeze** and the "richer type travels on the
  routing package, not the interface" approach are correct, and the mock repo in
  `tests/testutil/mock_navigation_repo.go` (fixed 5000 m / 454 s, with tests asserting those
  numbers) is correctly identified as the file that breaks first in stage 05.
- **Migration numbering (015)** is correct: 013 is claimed by plan 04, 014 is reserved by
  plan 07's archived section, and the runner does not require contiguity.
- **The 009-is-dead finding** is correct and independently confirmed: `sample_elevation()`
  returns `0`, its `UPDATE`s ran at migration time against an empty `road_vertices`, and
  routing reads `road_network_*_pgr` (011), not `road_*` (008).
- **No new module dependencies** is respected throughout; the gzip requirement (§1.1) is
  satisfied by `compress/gzip`.

---

## 7. Disposition summary

| # | Finding | Severity | Status |
|---|---|---|---|
| 1.1 | `srtmgl1` DEM URL 404s; payload is gzipped | blocker | fixed in `03` |
| 1.2 | Wrong DEM tile list (7 vertices lost, 1 empty tile fetched) | blocker | fixed in `03` |
| 1.3 | "Flat" control area has 371 m of relief | blocker | fixed in `04` |
| 1.4 | Test count 7 → 11 in two stages | major | fixed in `01`, `04` |
| 1.5 | Stale line refs (`config.go`, `pgrouting_repo.go`, `benchmark_test.go`) | major | fixed in `01`, `02` |
| 1.6 | Import never populates `elevation_m` — zero coverage by construction | major | fixed in `02`, `03` |
| 1.7 | Rider app does have a `fromJson` (conclusion still holds) | minor | corrected in `05`, `04` |
| 2.1 | `Validate` accepts negative weights → inadmissible heuristic, silently suboptimal A\* | **critical** | fixed in `01` |
| 2.2 | Cost identity stated as the shipped model | major | fixed in `01`, README |
| 2.3 | `MaxGrade` scope overstated; no ascent budget exists | major | fixed in `01` |
| 2.4 | NULL-endpoint edges can reach the hot loop | major | fixed in `02` (new Part 3a) |
| 2.5 | Engine/flag combination warned, not controlled | major | fixed in `02`, new `G8` in `04` |
| 3.1 | Provisional weights inert (median ratio 1.0000) | major | stage 04 restructured sweep-first |
| 3.3 | 45/2,000 qualifying pairs; top-N ranking biased | major | fixed in `04` |
| 3.4 | `short − long` estimator measures 1.00× (no signal) | major | deleted, replaced in `03` |
| 3.5 | Deadband 3 m too small; 5 m is not the fix | major | corrected in `03` |
| 3.6 | Unroutable OD pairs unaccounted for in ratios | moderate | fixed in `04` |
| 3.7 | Unmeasured single-pair assertion in G2 | moderate | fixed in `04` |
| 4.1 | "130 MB of tiles" assumed uncompressed | minor | corrected in `03` |
| 4.2 | Benchmark baseline from different hardware; refactor is not perf-neutral | moderate | corrected in `01`, `04` |
| 4.3 | `-region` depends on a plan-04 column | minor | noted in README |
| 5 | Stage 03 breadth | judgement | left as one stage, split documented as 03a/03b |

**Nothing in the series was found to be architecturally wrong.** The plan's core claim —
"trade a little distance for less climbing, provably, with the reported distance untouched" —
survives the review intact. What the review found is that **the constants were never measured**,
the DEM source was wrong, and two safety rules (negative weights, NULL endpoints) were assumed
rather than enforced. Stages 01–03 are ready to execute; stage 04 is now honest about being the
stage that has to earn the constants.
