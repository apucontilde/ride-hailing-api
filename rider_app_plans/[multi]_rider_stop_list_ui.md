---
tag: multi
depends_on: []
status: open
---

# [multi] Rider stop-list UI (OUTLINE — to be fleshed out)

> **OUTLINE ONLY.** Skeleton for a future `rider-planner` pass. Not implementation-ready:
> the current-state citations below are unverified placeholders and every section needs
> real `file:line` evidence before this plan is actionable.

## Goal

Let the rider add/remove/reorder **intermediate stops** on the Home request surface and
change the destination mid-trip, consuming the API `[multi]` contract that already landed
(see `api_plans/STATUS.md` → Landed `[multi]`). The API plan deliberately stopped at the
contract and named this app surface as the cross-app fold-out.

## Current state (verify before fleshing out)

- The rider Home surface holds two `Place?` fields — `rider_app/lib/features/home/presentation/home_screen.dart`
  (`_pickupLocation`, `_destination`). No stop list exists.
- API contract already live:
  - create accepts an ordered intermediate `stops` array (sibling of `ride`); a client stop
    with `kind:"destination"` is rejected `422`; the top-level `dropoff_*` is always the
    destination (`internal/handler/ride.go`, `internal/service/ride.go:BuildItinerary`).
  - `GET /rides/:id`, `/rides/current`, `/rides/history` return the itinerary as a sibling
    `stops` array (`internal/handler/ride.go`).
  - `PUT /rides/:id/destination` changes the final destination (`internal/handler/ride.go`,
    `internal/router/router.go`).
- The active-trip route already consumes `stops` as legs
  (`rider_app/lib/features/home/data/trip_route_provider.dart`).
- The Home preview route is the subject of `[map]_route_failure_honesty.md`.

## Scope (to be detailed)

- Stop-list widget on Home: add / remove / reorder; validation (minimum pickup + destination;
  ordered, `sequence` derived from array position).
- Send `stops` on ride create; show fare/route estimate with waypoints.
- Mid-trip "change destination" surface calling `PUT /rides/:id/destination`, then re-request
  the route (the client re-requests; the server does not re-route).
- Empty / loading / error states consistent with the app's existing patterns.

## Open questions (resolve when fleshing out)

- Reorder UX, and confirming the API preserves array order (it does — position = `sequence`).
- Fare impact of stops: does the API reprice on create with stops? (Verify; the landed
  `[multi]` work recorded that a destination change never reprices.)
- Whether the Home preview route should route multi-leg via the same provider as the active trip.
- Interaction with `[history]_rated_seed_past_cap.md` / `[map]_route_failure_honesty.md`.

## Invariants carried in

- Never render a confident, road-less route; an estimate must be labeled (see `[map]`).
- `stops` is always a **sibling** of `ride`, never a field inside it.
- Success paths / status codes for valid existing requests never change.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze && melos run test
```
