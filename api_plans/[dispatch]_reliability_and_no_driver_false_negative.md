---
tag: dispatch
depends_on: []
status: open
---

# Dispatch reliability: "rider gets no driver though a driver is clearly online"

Net-new reliability work. Two independent gaps produce the false negative — an
online driver is invisible to, or skipped by, dispatch. Plan the API-side fixes;
the driver-side keep-alive is a cross-app dependency owned by `driver-planner`.

## Gap A — freshness window hides stationary / just-online drivers

- `FindNearbyDrivers` only considers a driver whose position row is younger than
  30 s — `internal/repository/geo_repo.go:73`
  (`updated_at > NOW() - INTERVAL '30 seconds'`, plus `status = 'online'`).
- A driver who goes online while stationary, or who just came online, can hold
  **no** `driver_positions` row at all: geolocator only re-emits on movement, and
  the `_onPosition` stream discards fixes while offline — see
  `driver_app/lib/core/location/location_service.dart:147-167` (`publishLastPosition`,
  whose docstring describes exactly this invisibility). That driver is never offered
  a ride, with nothing on screen to explain why.
- **Opportunity:** `MarkStaleDriversOffline` exists in the interface
  (`internal/repository/geo_repo.go:125-129`, sets `status='offline'` where
  `status='online' AND updated_at < now()-30s`) but is **never called** — no cron,
  no goroutine invokes it. It's also not a *liveness* mechanism (it only sweeps
  stale rows; it does not re-mark a just-online-but-no-row driver online). Plan a
  callable sweeper and a liveness strategy.

## Gap B — WS-state gate skips a DB-fresh driver

- Dispatch *search* reads the DB and ignores WS state, but the offer loop then
  skips any driver whose socket isn't in the hub map — `internal/service/dispatch.go:101-105`
  (`offerRideToDriver` returns false when `!s.hub.IsConnected(driverID)`), and the
  hub's notion of "connected" is just map presence — `internal/websocket/hub.go:120-125`
  (`IsConnected` looks up `h.clients[userID]`).
- No keep-alive `ping()` is sent driver-side, so a stale entry (or the absence of a
  fresh connection after a reconnect) makes a DB-fresh driver get skipped.
- Net effect: the search says "a driver exists," the offer loop drops them, and the
  loop can exhaust with `no_driver_available` despite a genuinely online driver.

## Scope (API-side, owned by this plan)

1. Reconcile dispatch search and offer eligibility so DB-freshness and WS-state
   don't diverge (e.g., treat "not in hub map" as retryable-backoff rather than a
   hard skip, or amend the search to reflect real liveness), and record why a driver
   was skipped.
2. Wire `MarkStaleDriversOffline` into an actual cron/goroutine (or remove it from
   the interface if it isn't the intended mechanism), and design the liveness source
   of truth so a just-online/stationary driver is *not* invisible.
3. Ensure the false-negative is observable: log a structured reason on every
   offer-skip and on `no_driver_available` so a support trace can distinguish
   "genuinely no drivers" from "drivers existed but were skipped."

## Cross-app dependency

- Driver-side keep-alive `ping()` (and re-publish on reconnect) is the
  `driver-planner`'s; this plan only defines the API-side contract it must satisfy.

## Invariants carried in

- Route cost stays meters; `NavigationRepository.GetShortestPath` frozen (unaffected,
  but path selection around stops must not regress it).
- Success paths/status codes for valid requests never change (this is a *selection*
  fix, not a contract change).