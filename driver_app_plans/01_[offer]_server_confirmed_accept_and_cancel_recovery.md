---
tag: offer
depends_on: ["api_plans/[rides]_cancel_accept_race.md"]
status: open
---

# [offer] Server-confirmed accept and cancel-trip recovery

> **Owner:** `driver-planner`. **Stage `01` of the `[offer]` chain.** The dependency names an
> **open** plan — `api_plans/[rides]_cancel_accept_race.md` (`status: open`) — which is the
> canonical owner of the accept/cancel HTTP status maps and the WS frame names. This plan adopts
> §4 of that file **verbatim** and never renames `ride.accept_failed`, `ride.offer_closed`,
> `OFFER_EXPIRED`/`RIDE_NOT_PENDING`/`NOT_OFFERED`, or the 404/409/422/500 outcomes.
>
> **Nothing here is implemented yet.** This is a plan only. The server half is the dependency;
> the driver app must not depend on the old `200`-without-assignment or the blanket `400`.
>
> **Server authorization dependency (reviewer new finding 1):** today
> `POST /driver/rides/:id/accept` calls `AcceptRide` directly and never checks that *this* driver
> was offered the ride — `internal/handler/ride.go:681-685` → `internal/service/dispatch.go:400-412`
> (`FindByID` + status check + `AssignDriver`, no offer-ownership check). Any driver can therefore
> accept any `pending` ride by UUID. The API plan's dispatch funnel (`api_plans/[rides]_cancel_accept_race.md`)
> owns that fix; **this plan depends on it and must not attempt a client-side workaround** (the
> driver app cannot prove offer ownership and must not pretend to). No new client scope is added
> for it.

## Incident this plan fixes (2026-10-19)

A rider cancelled ride `83ccb6f7-…` while a driver held its offer. The driver tapped Accept; the
API had no active offer and only logged `failed to handle ride accept: no active offer for ride
<id>`. The app had already claimed the offer optimistically (WS accept is fire-and-forget),
closed the offer sheet and pushed `/trip` with a placeholder `Ride(id, riderId:'', status:
'accepted')`. The ride's `driver_id` was NULL, so `ride.updated cancelled` never reached that
driver, and the driver's two Cancel-trip POSTs answered `400` (already cancelled). The phantom
trip has no self-correction path. See the evidence map in §2.

**Goal:** the driver never leaves `/home` on an unconfirmed accept, and can always recover from
`/trip` when the server says the ride is gone, terminal, or already cancelled.

---

## 1. Canonical API contract (copied verbatim from `api_plans/[rides]_cancel_accept_race.md` §4)

### 1.1 `POST /api/v1/driver/rides/:id/accept`

| Outcome | Status | Body |
| --- | --- | --- |
| assignment committed | `200` | `{"message":"ride accepted"}` |
| no live offer for **this** driver (expired/withdrawn/other driver) | `404 NOT_FOUND` | `{"error":{"code":"NOT_FOUND","message":"no active offer for this ride"}}` |
| ride no longer pending (cancelled/taken) | `409 CONFLICT` | `{"error":{"code":"CONFLICT","message":"ride is no longer available"}}` |
| malformed `:id` | `422 VALIDATION_ERROR` | `{"error":{"code":"VALIDATION_ERROR","message":"invalid ride id"}}` |
| repo/write failure | `500 INTERNAL` | `{"error":{"code":"INTERNAL","message":"failed to accept ride"}}` |

`200` is returned **only after** `AssignDriver` committed. A repo error is never a 2xx.

### 1.2 `POST /api/v1/driver/rides/:id/cancel` (unchanged route)

| Outcome | HTTP |
| --- | --- |
| success / authorized repeat cancel | `200` `{"ride":<fresh ride>}` |
| malformed `:id` | `422 VALIDATION_ERROR "invalid ride id"` |
| ride missing or **not the caller's** (a driver holding only an offer is NOT the driver) | `404 NOT_FOUND "ride not found"` |
| `in_progress`/`completed`/`no_driver_available` | `409 CONFLICT "ride can no longer be cancelled"` |
| repo/write failure | `500 INTERNAL "failed to cancel ride"` |

### 1.3 WS frames (names and shapes are pinned; do not rename)

```json
{"type":"ride.accept_failed","data":{"ride_id":"<uuid>","code":"OFFER_EXPIRED|RIDE_NOT_PENDING|NOT_OFFERED","message":"<public sentence>"}}
```

```json
{"type":"ride.offer_closed","data":{"ride_id":"<uuid>","reason":"expired|declined|cancelled|accepted_elsewhere|withdrawn"}}
```

```json
{"type":"ride.updated","data":{"ride_id":"<uuid>","status":"cancelled","cancelled_by":"rider"}}
```

The cancel `ride.updated` now also reaches the **offered** driver even when `driver_id` is NULL,
and `ride.offer_closed reason:"cancelled"` is sent on rider cancel. `message` in
`ride.accept_failed` is a fixed public sentence, never `err.Error()`.

---

## 2. Evidence map (verified in the working tree, 2026-10-19)

| Claim | Evidence |
| --- | --- |
| Accept is WS-first and closes immediately without a server ack | `driver_app/lib/features/rides/presentation/offer_sheet.dart:129-155` (WS branch `:138-142`; HTTP fallback `:146-154`) |
| The WS branch sends `ride.accept` and creates the placeholder | `driver_app/lib/core/ride/ride_state_notifier.dart:132-137`, `:147-153` (`Ride(id: rideId, riderId:'', status:'accepted')`) |
| The HTTP fallback claims the offer only on success, but only maps 409 | `driver_app/lib/features/rides/presentation/offer_sheet.dart:146-154`; `driver_app/lib/features/rides/data/rides_repository.dart:127-140` (`:135` maps 409 only) |
| Any non-null `currentRide` pushes `/trip` | `driver_app/lib/features/home/presentation/home_screen.dart:134-141` |
| `WsEventType` has no offer-closed/accept-failed kinds | `driver_app/lib/core/network/ws_event.dart:6-18` |
| The driver facade passes `acceptOffer` through to shared (shared untouched) | `driver_app/lib/core/network/websocket_service.dart:70-71`; `shared/lib/src/network/websocket_service.dart:227` |
| `ride.updated` is merged onto the held ride; a different ride is ignored only while the held ride is non-terminal | `driver_app/lib/core/ride/ride_state_notifier.dart:81-101` (guard `:89-91`; `clearOffer` `:99`) |
| Trip state seeds/listens to `RideState`; it never re-fetches the ride itself | `driver_app/lib/features/trip/providers/trip_notifier.dart:170-180`, `:192-217`; `_ensureStopsLoaded` `:222-239` fetches only `stops` |
| Cancel-trip swallows every exception | `driver_app/lib/features/trip/providers/trip_notifier.dart:356-369` (`catch (_) {}` `:366-368`) |
| Cancel success adopts the response; reset clears state | `trip_notifier.dart:446-451`, `:438-441` |
| Driver may cancel only pre-`in_progress` | `trip_notifier.dart:117-120`; `trip_screen.dart:631-637` |
| The cancel copy falsely says "goes back to dispatch" | `driver_app/lib/features/trip/presentation/trip_screen.dart:102-126` (copy `:108-111`) |
| A terminal cancelled view already exists (`Cancelled by the rider` + Back to home) | `driver_app/lib/features/trip/presentation/trip_screen.dart:443-475`; stage mapping `trip_notifier.dart:182-190`, `:207-215` |
| `GET /driver/rides/:id` exists and returns `{ride,stops}` | `driver_app/lib/core/api/endpoints.dart:31`; route `internal/router/router.go:251`; handler `internal/handler/ride.go:295-314` |
| `GET /driver/rides/current` filters to active statuses only — it **excludes** `no_driver_available` | `internal/repository/ride_repo.go:255-265` |
| `_ensureStopsLoaded` fetches the full itinerary but discards `itinerary.ride` (uses only `.stops`) | `driver_app/lib/features/trip/providers/trip_notifier.dart:222-239` (`.stops` at `:232`); `RideItinerary.ride` exists at `driver_app/lib/features/rides/data/rides_repository.dart:105-107` |
| `no_driver_available` is **not** a `TripStage`; unmapped statuses fall through to `pre` | `driver_app/lib/features/trip/providers/trip_notifier.dart:182-190` (`_ => TripStage.pre` at `:189`); `shared/lib/src/models/ride.dart:64` (`isTerminal` covers only `completed`/`cancelled`) |
| Home's `_tripPushed` latch resets only when `currentRide == null` | `driver_app/lib/features/home/presentation/home_screen.dart:134-141` (reset `:134-135`, push `:136-141`) |
| Accept has no offer-ownership check (server dependency, reviewer new finding 1) | `internal/handler/ride.go:681-685`; `internal/service/dispatch.go:400-412` |
| Concurrent uncommitted arrival fix (preserve) | `driver_app/lib/features/trip/presentation/trip_screen.dart:35-42,196-202`; `driver_app/test/features/trip/presentation/trip_screen_test.dart:288-313` |

**Drift found while verifying this map** (do not silently fix by trusting the incident text):

- `driver_app/lib/core/api/endpoints.dart:34` is **decline**; the by-id read is `:31`.
- `acceptOffer` is `:132-137`, `claimOfferViaHttp` `:141-145`, `_claimOffer` `:147-153` (the
  incident text said `:132-140`/`:141-144`/`:147-155`).
- `_onRideUpdated`'s different-ride guard is `:89-91` (not `:93-95`) and `clearOffer` is `:99`
  (not `:107`).
- `canCancel` is the getter at `:117-120` (not `:351-355`); `cancelTrip` is `:356-369`.
- The terminal cancelled view is `trip_screen.dart:443-475` (not `:439-476`).
- The "back to dispatch" copy is real and false: the canonical server cancels the ride and never
  re-dispatches it (`api_plans/[rides]_cancel_accept_race.md` decision `e`).

---

## 3. Accept becomes server-confirmed (scope 1 + 2)

### 3.1 Repository status map (`rides_repository.dart`)

Replace the 409-only catch in `acceptRideHttp` (`:127-140`) with:

| Server outcome | Client behaviour |
| --- | --- |
| `200` | resolve; the caller must then load the real ride (§3.2) |
| `404` (no live offer for this driver) | throw `OfferExpiredException` |
| `409` (ride no longer pending) | throw `OfferExpiredException` |
| `422` (malformed id) | rethrow (`ValidationException`/`DioException`) — a programming error, not a user state |
| `500` / timeout / network | rethrow — retryable, the sheet stays usable |

`OfferExpiredException` already extends `ConflictException`
(`shared/lib/src/api/api_exceptions.dart:76-78`), so no shared change is needed. The two states
share one user-facing copy (§7c); the API `message` is preserved on the exception for logs/tests.

**Rule:** `acceptRideHttp` must never normalise a non-2xx into success. Today a `404` escapes as a
generic `NotFoundException`, so a dead-socket driver sees "Could not accept" instead of the
truthful "Trip no longer available".

### 3.2 `_accept()` — HTTP-primary, adopt before close (`offer_sheet.dart:129-155`)

Recommended shape (decision `a`): **delete the WS accept branch** and always use the synchronous
HTTP accept. Do not close the sheet or let Home navigate on a placeholder.

```dart
Future<void> _accept() async {
  final rideId = ref.read(rideStateProvider).offeredRideId;
  // A committed accept is never POSTed twice; only the read is retried.
  if (rideId == null || _expired || _accepting || _acceptConfirmed) return;
  setState(() => _accepting = true);
  try {
    await ref.read(ridesRepositoryProvider).acceptRideHttp(rideId); // 200 after commit
    _acceptConfirmed = true;                                         // POST is done, no re-POST
    await _loadAcceptedRide(rideId);                                 // real ride, never a placeholder
  } on OfferExpiredException {
    ref.read(rideStateProvider.notifier).expireOffer(reason: 'expired');
    _expireNow(message: 'Trip no longer available');
  } on Exception {
    _showMessage('Could not accept. Please try again.');             // sheet stays usable
  } finally {
    if (mounted) setState(() => _accepting = false);
  }
}

Future<void> _loadAcceptedRide(String rideId) async {
  try {
    final ride = await ref.read(ridesRepositoryProvider).fetchRide(rideId);
    if (!mounted) return;
    switch (ride.status) {
      case 'accepted':
      case 'driver_arrived':
        _postAcceptClose = true; // this closure owns the pop, not the offer listener
        ref.read(rideStateProvider.notifier).adoptRide(ride);
        _closeAsAccepted(); // the only path that may say "Trip accepted"
      case 'cancelled':
      case 'completed':
        // The accept committed, but the ride ended before this read returned.
        // Adopt the real terminal ride so the held state is truthful; never
        // claim a live trip and never re-POST accept.
        _postAcceptClose = true;
        ref.read(rideStateProvider.notifier).adoptRide(ride);
        _closeAsEnded('This trip has already ended.');
      case 'no_driver_available':
        // Not an assigned trip for this driver: reset, stay on Home, never
        // adopt it as a live ride (it is not a TripStage; see §5.1/§7f).
        _postAcceptClose = true;
        ref.read(rideStateProvider.notifier).clearRide();
        _closeAsEnded('No active trip.');
      default:
        // Any other status (e.g. `pending` from a read that raced the commit)
        // proves nothing: keep the sheet usable and retry the read, no claim.
        setState(() => _acceptConfirmedButUnloaded = true);
    }
  } catch (_) {
    // The accept DID commit (200). Do not re-POST accept; offer a load retry.
    setState(() => _acceptConfirmedButUnloaded = true);
  }
}
```

Requirements this encodes:

- **Only `200` starts the claim.** Never call `acceptOffer`/`claimOfferViaHttp`/`_claimOffer` from
  the sheet. The placeholder path is removed (§7e).
- **Branch on the fetched ride's status (reviewer finding 6).** A `200` can be followed by a rider
  cancel before the post-accept `GET /driver/rides/:id` returns, so the read may already answer
  `cancelled`/`completed`/`no_driver_available`. Adopt whatever is fetched is **wrong**:
  - only `accepted` (and, if applicable, `driver_arrived`) may use `adoptRide` + `_closeAsAccepted`
    ("Trip accepted");
  - `cancelled`/`completed` adopt the real terminal ride and close the sheet as **ended** — the
    terminal `Cancelled by the rider` / receipt view is the only thing `/trip` may show;
  - `no_driver_available` **resets** the held ride (`clearRide()`) and closes as ended — never a
    live claim, never `/trip`, Home stays put;
  - the post-commit read is **never** re-POSTed as a new accept, in any branch.
- **Adopt the real ride before navigating.** `adoptRide(ride)` is what sets
  `currentRide` and therefore what makes Home push `/trip` (`home_screen.dart:134-141`). It must
  receive the `GET /driver/rides/:id` response, never a hand-built `Ride`. The server's fresh
  `status: accepted` also clears the offer in the same update
  (`ride_state_notifier.dart:106-112`).
- **Success ordering:** `adoptRide(realRide)` → `_closeAsAccepted()` (pop + "Trip accepted").
  Because `adoptRide` clears `offeredRideId`, the sheet's own listener
  (`offer_sheet.dart:213-227`) would otherwise pin it to expired; set `_postAcceptClose = true`
  before the adopt so the listener returns early when it observes the cleared offer. The same flag
  is set on the terminal paths so their pop also wins.
- **Post-commit load failure is not a failed accept.** If `fetchRide` fails after a `200`, the
  ride is already assigned. Set `_acceptConfirmed = true` immediately after the `200` (before the
  read), and render an explicit **Retry loading** button in place of Accept/Pass whenever
  `_acceptConfirmedButUnloaded && !_postAcceptClose`; Retry calls only `_loadAcceptedRide`, so the sheet can
  never re-POST the accept. Fall back once to `currentRide()` (`rides_repository.dart:161-167`)
  only if the by-id read keeps failing. Never re-POST accept (it would now answer `404` and
  wrongly expire the sheet). Never fabricate the placeholder.
- **404/409** → `_expireNow(message: 'Trip no longer available')` **and** clear the held offer
  through `RideStateNotifier.expireOffer(...)`; a single Dismiss remains. Do not close silently
  (the landed explicit-dismiss contract, `driver_app_plans/STATUS.md` `[offer]`, bug #20).
- **422/500/network** → retryable SnackBar; the Accept/Pass actions stay live, `_expired` stays
  false. No state claim, no navigation.
- Add `_accepting` to block a double tap/Double-POST while the HTTP call is in flight.

### 3.3 `_closeAsAccepted` / `_expireNow` changes

- `_closeAsAccepted()` (`:176-182`) keeps its pop + "Trip accepted" SnackBar. It is called **only**
  for a fetched `status` of `accepted`/`driver_arrived`; it no longer has a WS caller and is
  never used for a terminal read.
- Add `_closeAsEnded(String message)`: pop the sheet and show the message as a SnackBar, with
  **no** "Trip accepted" text. Used by the post-200 `cancelled`/`completed`/`no_driver_available`
  branches; it claims no live trip.
- `_expireNow()` (`:167-174`) gains an optional `String? message` and stores it in a new
  `_closedMessage` field. The expired block (`:291-304`) renders `_closedMessage ?? 'Offer expired'`
  above the existing Dismiss button. Cancelling the timer and setting `_secondsLeft = 0` are
  unchanged.
- The offered-id listener (`:213-227`) keeps both arms (replaced offer pops; cleared offer pins
  to expired) but:
  - if `_postAcceptClose` is true, it does nothing (the post-200 close path owns the pop);
  - when `next == null`, it reads `RideState.offerClosedReason`/`offerClosedMessage` and passes
    the message to `_expireNow` (so a server close shows the truthful reason); the nullable
    fields are cleared by the next `ride.offer` (§4.2).
- `_expireNow` stays idempotent (`if (_expired) return;`).

### 3.4 Home's navigation contract (unchanged code, new guarantee)

`home_screen.dart:134-141` still pushes `/trip` on any non-null `currentRide` and keeps
`_tripPushed` true until `heldRide == null` (`:134-135`). This plan does not change that; it makes
the guarantee true by construction and by **nulling the phantom on every failure/terminal path**:

- `accepted`/`driver_arrived` → `adoptRide(realRide)` → Home pushes `/trip` (a live trip).
- `cancelled`/`completed` → `adoptRide(terminal realRide)` → Home may push `/trip`, which renders
  the existing terminal view (`trip_screen.dart:443-475`); it never claims a live trip.
- `no_driver_available` and every accept failure (`ride.accept_failed`, 404/409 expiry) →
  `clearRide()`/`reset()` so `currentRide == null`; the latch resets at `:134-135`, Home stays,
  and the next real accepted ride auto-pushes `/trip` again. Every path that clears must actually
  null the phantom — merely leaving a stale placeholder would keep `_tripPushed` true forever.

No placeholder is created anywhere in the accept path.

---

## 4. New WS lifecycle frames (scope 3)

### 4.1 `WsEventType` (`driver_app/lib/core/network/ws_event.dart:6-18`)

Add exactly:

```dart
enum WsEventType {
  offer,
  updated,
  offerClosed,   // ride.offer_closed
  acceptFailed,  // ride.accept_failed
  location,
  other;

  static WsEventType fromRaw(String? raw) => switch (raw) {
        'ride.offer'        => WsEventType.offer,
        'ride.updated'      => WsEventType.updated,
        'ride.offer_closed' => WsEventType.offerClosed,
        'ride.accept_failed'=> WsEventType.acceptFailed,
        'driver.location'   => WsEventType.location,
        _ => WsEventType.other,
      };
}
```

`DriverWebSocketService._normalize` (`websocket_service.dart:60-65`) passes the type through, so
no facade change is needed for decoding. `shared/` is not edited.

### 4.2 `RideState` additions + exhaustive switch (`ride_state_notifier.dart:13-37`, `:64-74`)

Two nullable fields **and their clear flags** (a nullable cannot be cleared through `copyWith`
otherwise — `:24-36`):

- `String? offerClosedReason` (`expired|declined|cancelled|accepted_elsewhere|withdrawn|accept_failed`);
- `String? offerClosedMessage` (the public sentence the sheet renders);
- `bool clearOfferClosed = false` in `RideState.copyWith`, with the two fields assigned as
  `clearOfferClosed ? null : offerClosedReason ?? this.offerClosedReason` (and likewise for the
  message). This is the **explicit clear flag** for both fields.

Extend `copyWith` exactly:

```dart
RideState copyWith({
  Ride? currentRide,
  bool clearRide = false,
  String? offeredRideId,
  DateTime? offerExpiresAt,
  bool clearOffer = false,
  String? offerClosedReason,
  String? offerClosedMessage,
  bool clearOfferClosed = false,
}) { ... }
```

Add `expireOffer({String? reason, String? message})`:

- cancel `_offerTimer`;
- `state = state.copyWith(clearOffer: true, offerClosedReason: reason,
  offerClosedMessage: message)` (leave `clearOfferClosed` false so the values write);
- never touch `currentRide`;
- clear both fields when a new offer arrives: `_onOffer` ends with
  `state = state.copyWith(offeredRideId: rideId, offerExpiresAt: ..., clearOfferClosed: true)`,
  so a stale reason cannot label the next offer.

Add the two new **exhaustive** switch arms in `onWsEvent` (`:64-74`; the switch has no `default`):

```dart
case WsEventType.offerClosed:
  _onOfferClosed(event.data);
case WsEventType.acceptFailed:
  _onAcceptFailed(event.data);
```

- `_onOfferClosed(Map<String, dynamic> data)`: reads `ride_id` + `reason`; acts only when
  `ride_id == state.offeredRideId` (or the offered id is null and a held ride matches — the
  following `ride.updated` owns the ride). Calls `expireOffer(reason: reason, message: <mapped
  public sentence>)`. It never touches `currentRide`.
- `_onAcceptFailed(Map<String, dynamic> data)`: reads `ride_id`, `code`, `message`; calls
  `expireOffer(reason: 'accept_failed', message: data['message'] as String?)` then
  `_clearPhantomFor(ride_id)`.

Add `_clearPhantomFor(String rideId)`:

- clears `currentRide` only when it matches `rideId`, is non-terminal, and is the old optimistic
  placeholder shape (`status == 'accepted'` and no `pickupLat`/`pickupLng`); a server-confirmed
  accepted ride always has coordinates and is left untouched;
- clears the offer in the same update;
- because it **nulls** `currentRide`, Home's `_tripPushed` latch resets (`home_screen.dart:134-141`).

### 4.3 Exact transitions

| Frame | State before | Transition | Navigation |
| --- | --- | --- | --- |
| `ride.offer_closed {reason:"expired"}` | offer open, sheet up | `expireOffer(reason:'expired', message:'Offer expired')` | no; sheet pins to Dismiss |
| `ride.offer_closed {reason:"cancelled"}` | offer open, sheet up | `expireOffer(reason:'cancelled', message:'The rider cancelled this trip.')` | no; sheet pins to Dismiss |
| `ride.offer_closed {declined\|accepted_elsewhere\|withdrawn}` | offer open | `expireOffer(...)` with "This offer is no longer available." | no |
| `ride.offer_closed` | no offer / already held | clear the offer only; held ride unchanged | no; the following `ride.updated` handles the ride |
| `ride.accept_failed {ride_id, code, message}` | optimistic placeholder for that id (legacy/in-flight app only) | `expireOffer(reason:'accept_failed', message: server message)` + `_clearPhantomFor(ride_id)` | **never** `/trip`; Home sees `currentRide == null` |
| `ride.accept_failed` | server-confirmed ride with the same id | clear the offer; keep the ride (a broadcast confirmed it) | no |
| `ride.updated {status:"cancelled",cancelled_by}` | phantom/held ride, same id, on `/trip` | existing merge → terminal `cancelled`, clear offer | `/trip` already mounted; shows the `Trip cancelled` view + Back to home |
| `ride.updated {status:"cancelled"}` | no held ride, `ride_id == offeredRideId` | adopt the terminal cancelled ride; clear offer | the offer sheet pins closed; Home may push `/trip`, which renders the terminal view. No auto-home (decision `d`) |
| `ride.updated {status:"no_driver_available"}` (if received — the server pushes it only to the **rider**, `internal/service/dispatch.go:181-190`; the driver's source is the by-id read) | held/phantom ride, same id | **no active trip**: clear/reset the held ride (`_clearPhantomFor` or `clearRide`); `TripNotifier` requests an exit (§5.1/§5.3) | `/trip` leaves to Home via `_finishTrip`; the latch resets; **never** the cancelled/post view |
| `ride.updated` for a **different** ride | non-terminal held ride | unchanged guard (`:89-91`): ignore | no |

The important incident path is row 7: the offered driver whose phantom is `accepted` receives the
terminal `cancelled` patch, the merge keeps the id/coords it already held, `clearOffer` fires,
and the trip screen maps `cancelled` to `TripStage.cancelled` (`trip_notifier.dart:182-190`,
`:207-215`) instead of staying on an accepted phantom forever.

`no_driver_available` needs explicit handling because `Ride.isTerminal` is only
`completed`/`cancelled` (`shared/lib/src/models/ride.dart:64`) and `_stageFromStatus` has no case
for it (`trip_notifier.dart:182-190`, falling to `pre` at `:189`). The driver app must not render
it as "Waiting for the trip to start" with `canCancel == true` (`:117-120`); §5.1/§7f specify the
clear-and-leave handling and why no `TripStage` is added.

### 4.4 Where the message reaches the UI

`OfferSheet` reads `offerClosedMessage` in its existing offered-id listener (§3.3). Since
`ride.accept_failed` also clears the offer, the sheet pins to Dismiss and shows the server's
public sentence. When no sheet is open, the message is simply not rendered (the state still
records it for the next mount); no SnackBar is required off-screen. `shared/` remains aware of
none of this.

---

## 5. Cancel-trip recovery (scope 4)

### 5.1 `TripNotifier.cancelTrip` (`trip_notifier.dart:356-369`)

Replace the swallowed catch with one reconcile path:

| Server outcome | Action |
| --- | --- |
| `200` | unchanged: `_adoptServerRide(response.data)` (`:446-451`) → fresh cancelled ride, `TripStage.cancelled` |
| `404` (this ride is not assigned to this driver — e.g. only an offer was held) | **no generic error**: request exit; the screen's finish action clears the held ride and resets. This is the incident's unstuck path |
| `409` (`in_progress`/`completed`/`no_driver_available`) | set `cancelError` to `apiErrorMessage(e, 'This trip can no longer be cancelled.')` once, then reconcile with `GET /driver/rides/:id`. `completed`/`cancelled` → `adoptRide` the fresh terminal ride → terminal cancelled/post view. `in_progress` → `adoptRide` → driving (Cancel button disappears). **`no_driver_available` → not a stage and not a receipt**: request exit (§5.2) so `_finishTrip` clears/resets and returns to Home; do **not** promise the cancelled/post view (see §7f). 404 on the re-read → request exit |
| `422`/`5xx`/network | set `cancelError` (`'Could not cancel the trip. Please try again.'`); do **not** navigate; do not swallow. The Cancel button stays available so the driver can retry |

New `TripState` fields (`trip_notifier.dart:94-145`):

- `String? cancelError` — rendered inline above the Cancel button and/or shown once as a SnackBar
  by the screen (§5.2). Cleared on a new ride and on a successful cancel.
- `bool exitRequested` — the notifier's signal that the trip screen must leave. Set on the `404`
  path (after the notifier has decided the ride is not ours). `reset()` clears it.

`_requestExit()` helper: `state = state.copyWith(exitRequested: true)`; do not call
`clearRide()`/`reset()` inside the notifier for this path — the screen's `_finishTrip()` is the
single place that clears the WS store and the trip cache (and calling `clearRide()` first would
sync `_syncFromRideState` to `const TripState()` and drop the flag). For the 409 re-read, use the
existing `_adoptServerRide`-style flow with `ridesRepositoryProvider.fetchRide(rideId)` (REST
shape, full ride) and `RideStateNotifier.adoptRide`; it flows through `_syncFromRideState`.

Exception detection: catch `DioException` and switch on `e.response?.statusCode`. A null response
is a network failure → retryable branch.

### 5.2 How the screen learns to leave, without touching the arrival hunks

Add one **new** `ref.listen<TripState>` after the existing arrival listener
(`trip_screen.dart:196-202` — do not edit that block):

```dart
ref.listen<TripState>(tripNotifierProvider, (previous, next) {
  if (next.exitRequested) _finishTrip();
  if (next.cancelError != null && next.cancelError != previous?.cancelError) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(next.cancelError!)),
    );
  }
});
```

`_finishTrip()` (`trip_screen.dart:96-100`) already calls `clearRide()` + `reset()` +
`context.go('/home')`, so the 404 path needs no new navigation primitive. Do not reuse or rewrite
the uncommitted `_publishArrivalFix` hunks (`trip_screen.dart:35-42,196-202`); the new listener is
an adjacent hunk. `PopScope`/back handling (`:204-209`) is unchanged.

### 5.3 Self-correcting by-id read (`TripNotifier._ensureStopsLoaded`, `trip_notifier.dart:222-239`)

`_ensureStopsLoaded` already calls `fetchRideItinerary(ride.id)` (`:227-228`) but uses only
`itinerary.stops` (`:232`) and discards `itinerary.ride` (`rides_repository.dart:105-107`). Reconcile
that ride instead of throwing it away, so the trip screen self-corrects even if the driver missed
the WS frame (the incident's NULL-`driver_id` case):

- guard the in-flight result as today (`state.currentRide?.id != ride.id` → return, `:230`);
- set `_loadedStopsForRideId = ride.id` **before** any `adoptRide` so the `_syncFromRideState`
  listener does not re-enter and fetch the same id again;
- `state = state.copyWith(stops: itinerary.stops)` as today;
- if `itinerary.ride.status == 'no_driver_available'` → `_requestExit()` (§5.2): the screen's
  `_finishTrip()` clears the held ride/resets and returns to Home. Never adopt it as a live ride
  and never render a stage;
- if `itinerary.ride.status == 'cancelled'` or `'completed'` → the held ride is stale; call
  `RideStateNotifier.adoptRide(itinerary.ride)` so the merge produces `TripStage.cancelled`/
  `TripStage.post` without waiting for a WS frame;
- a non-terminal differing status may also be adopted (the by-id read is server truth), but a
  failed read stays non-fatal as today (`:233-235`). No re-POST and no navigation beyond the
  `no_driver_available` exit.
- Independently, `_syncFromRideState` (`:192-217`) must check `ride.status == 'no_driver_available'`
  **before** `_stageFromStatus` and call `_requestExit()` instead of computing a stage. That covers
  a no-driver ride adopted from any read path (and the unlikely broadcast), so it can never render
  `pre`/"Waiting for the trip to start" with `canCancel == true` (`:117-120`, `:189`).

### 5.4 Copy correction (truthful cancellation)

In `_confirmCancel` (`trip_screen.dart:102-126`), replace the false copy at `:108-111`
("The rider is notified and the trip goes back to dispatch.") with a truthful sentence, e.g.:

> "The rider is notified and the trip is cancelled. It will not be offered to another driver.
> This cannot be undone."

The server cancels the ride and never re-dispatches it (canonical decision `e`); the driver's copy
must not promise a re-dispatch that does not exist. This hunk is outside the concurrent arrival
diff and is safe to edit.

---

## 6. Tests (inspect the existing suites; add/replace with these names)

### 6.1 `driver_app/test/features/rides/presentation/offer_sheet_test.dart`

Replace the WS-first accept test (`:283-301`) and adapt the 409 test (`:323-340`):

- `an accept over a live websocket still uses the HTTP endpoint` — assert
  `mockRepo.acceptRideHttp('r1')`, `verifyNever(mockWs.acceptOffer)`, and no placeholder.
- `200 closes only after the real ride is adopted` — stub `fetchRide` to return, on its **second**
  call (the post-accept read; the first is the sheet's initial load), a full `status:'accepted'`
  ride with pickup coords; assert `currentRide!.pickupLat` is non-null, the offer cleared, the
  sheet popped after the adopt, and "Trip accepted".
- `404 from the HTTP accept closes as expired with 'Trip no longer available'` — single Dismiss,
  no current ride, no trip navigation.
- `409 from the HTTP accept closes as expired with 'Trip no longer available'` (adapt `:323`).
- `500 from the HTTP accept keeps the sheet usable and shows a retryable message` — Accept still
  present, `_expired` false, current ride null.
- `a 200 whose ride read fails offers a retry and never re-POSTs accept` — no placeholder, no
  pop; Accept is replaced by Retry; tapping Retry calls only `fetchRide` (assert
  `acceptRideHttp` was called exactly once) and the successful retry adopts and pops.
- `a 200 whose ride is already cancelled closes as ended, never as accepted` — the second
  `fetchRide` answers `status:'cancelled'`; assert no "Trip accepted", the sheet popped, the
  held ride is the real terminal cancelled ride (or null), and accept was POSTed exactly once.
- `a 200 whose ride is completed adopts the terminal receipt and does not claim a live trip` —
  second read `status:'completed'`; no "Trip accepted", terminal post view is what `/trip` can
  render.
- `a 200 whose ride is no_driver_available clears the held ride and stays on Home` — second read
  `status:'no_driver_available'`; assert `currentRide == null`, no "/trip" push, no "Trip accepted",
  accept POSTed once.
- `a server offer_closed reason cancelled pins the sheet with the cancelled message` — feed the
  frame through `events`, assert the offered id cleared and the reason copy rendered.
- `a server accept_failed clears the phantom and never claims the trip` — seed the placeholder
  shape, feed the frame, assert `currentRide == null` and the public message shown.
- Keep the existing estimate/fare/dismissal/back-gesture tests unchanged.

### 6.2 `driver_app/test/core/ride/ride_state_notifier_test.dart`

- `ride.offer_closed clears the offer and records the reason` (new).
- `ride.accept_failed clears the phantom ride and keeps it out of currentRide` (new; seed the
  placeholder shape).
- `ride.accept_failed leaves a server-confirmed accepted ride alone` (new; coordinates present).
- `a cancelled ride.updated reaches an offered driver` (new/adapt `:246`, `:82-96`): offered id
  set, no held ride → terminal cancelled adopted and offer cleared.
- `a cancelled update for a phantom placeholder maps it to terminal` (new).
- `the next ride.offer clears the previous offer_closed reason and message` (new): `expireOffer`
  leaves reason/message non-null, then a `ride.offer` frame clears both via `clearOfferClosed` and
  the new offer is not labelled with the old reason.
- `ride.accept_failed clears the phantom so Home's latch can reset` (new): assert
  `currentRide == null` after the frame (`home_screen.dart:134-141`).
- Replace `acceptOffer sends the accept and flips to an accepted placeholder` (`:108-122`) and
  `acceptOffer is a no-op…` (`:124-128`) with the expiry/accept-failed coverage above (the
  placeholder API is deleted, decision `e`).

### 6.3 `driver_app/test/core/network/websocket_service_test.dart`

Extend `broadcast messages decode into typed WsEvents` (`:167`) to map
`ride.offer_closed → WsEventType.offerClosed` and
`ride.accept_failed → WsEventType.acceptFailed`. Update `driver sends the nested wire format for
accept/decline/ping` (`:143`) if the facade's `acceptOffer` is deleted (§7e).

### 6.4 `driver_app/test/features/rides/data/rides_repository_test.dart`

- `acceptRideHttp throws OfferExpiredException on 404` (new).
- Keep/adapt `acceptRideHttp throws OfferExpiredException on 409` (`:50`).
- `acceptRideHttp rethrows 422 and 500 as retryable failures` (new).

### 6.5 `driver_app/test/features/trip/providers/trip_notifier_test.dart`

Keep `posts the cancel endpoint and lands on cancelled` (`:320-340`); add:

- `cancel 404 requests an exit instead of a generic error` — `exitRequested` true,
  `cancelError` null.
- `cancel 409 reconciles to the server's in-progress ride and stays` — re-read returns
  `in_progress`; stage `driving`, `canCancel` false, error surfaced once.
- `cancel 409 on a completed ride adopts the terminal receipt` — re-read returns `completed`.
- `cancel 409 on a no_driver_available ride requests an exit, not a cancelled view` — re-read
  returns `no_driver_available`; assert `exitRequested` true and the state never becomes a live
  `pre` stage with `canCancel == true` (`_stageFromStatus` default at `:189`).
- `a no_driver_available ride.updated requests an exit, never a live stage` — assert the
  `exitRequested` path rather than `TripStage.pre`.
- `a cancelled by-id itinerary read self-corrects the trip to cancelled` — stub
  `fetchRideItinerary` to return `itinerary.ride.status == 'cancelled'` with a `cancelled_by`;
  assert the held/trip ride becomes terminal cancelled and the stops still load (§5.3).
- `a no_driver_available itinerary read requests an exit and never adopts a live ride` — stub the
  itinerary read with `no_driver_available`; assert `exitRequested` true and no live stage.
- `cancel 500 surfaces a retryable error and stays on the trip` — `exitRequested` false,
  `cancelError` non-null.

### 6.6 `driver_app/test/features/trip/presentation/trip_screen_test.dart`

- `a 404 cancel leaves the trip screen for home` — the new listener calls `_finishTrip`, asserting
  home is rendered and the held ride cleared.
- `a 500 cancel shows the error and stays on the trip`.
- `the cancel dialog does not claim the trip returns to dispatch` — pin the corrected copy.
- **Keep green, do not rewrite:** the uncommitted arrival tests
  `mounting an accepted trip re-publishes the cached fix` and
  `a server-confirmed accept after mount publishes again` (`:289`, `:301`), plus the existing
  `a rider cancellation is reported and clears the trip` (`:737-751`) and terminal cancelled view.
- Add `a no_driver_available cancel reconcile returns to home without a cancelled view` — the new
  `exitRequested` listener calls `_finishTrip` and `/home` renders.

### 6.7 `driver_app/test/features/home/presentation/home_screen_test.dart`

- `an accept_failed on Home clears the phantom and a later accepted ride still pushes /trip`
  (new): mount Home with a seeded optimistic placeholder (the pre-fix shape), feed
  `ride.accept_failed` through `events`, assert Home stays mounted with no `/trip` push and
  `currentRide == null`, then adopt a real `status:'accepted'` ride and assert the auto-push
  fires. This pins the `_tripPushed` latch reset (`home_screen.dart:134-141`) that the phantom
  path previously could not reach.

---

## 7. Decisions (recommendations; product owner confirms)

| # | Decision | Recommendation | Rationale / impact |
| --- | --- | --- | --- |
| a | HTTP-primary accept vs keep WS with an ack | **HTTP-primary**: the sheet always calls `acceptRideHttp`; delete the fire-and-forget WS accept branch. If a later feature insists on WS, it must wait for `ride.updated accepted` or `ride.accept_failed` before claiming — never close on send | The synchronous `200` is the only signal that the assignment committed (canonical §4.2). A WS round-trip needs a new wait/timeout state machine and still duplicates the assignment funnel; HTTP is already the fallback and costs one request |
| b | After accept, fetch `GET /driver/rides/:id` vs adopt `/driver/rides/current` | **Fetch `:id` first**, use `/current` only as a one-shot fallback | `:id` is targeted and returns the ride in every status (handler `internal/handler/ride.go:295-314`). `/current` filters to `accepted/driver_arrived/in_progress` (`internal/repository/ride_repo.go:255-265`), so after a concurrent cancel it returns `null` — exactly the incident's ambiguity. `/current` also cannot return a cancelled ride to reconcile a 409 |
| c | 404 accept copy | **"Trip no longer available"** for both 404 and 409 | Either way the offer is gone and the sheet must pin; distinguishing "expired" from "taken" adds friction with no action difference. The API message is preserved on the exception for logs/tests |
| d | Rider-cancel update while on `/trip` | **Show the terminal `Cancelled by the rider` view**; do not auto-home | The landed terminal view already has a "Back to home" action (`trip_screen.dart:443-475`), it confirms why the trip ended, and auto-navigation could race the sheet/route stack. For an offered-only driver the same terminal screen is reached after the offer sheet is dismissed (the sheet shows the reason copy) |
| e | Delete the now-unused WS accept client path? | **Yes — app-local only**: delete the sheet's WS branch, `RideStateNotifier.acceptOffer`/`claimOfferViaHttp`/`_claimOffer`, and the `DriverWebSocketService.acceptOffer` facade method; update the facade test. **Do not edit `shared/`**: `shared/lib/src/network/websocket_service.dart:227` stays for other consumers/tests | Nothing else calls the driver path (verified by grep); leaving it invites a regression back to the optimistic placeholder. The `ride.accept_failed` handler remains as defence-in-depth for in-flight frames and is unit-tested against the placeholder shape |
| f | Map `no_driver_available` to a `TripStage`? | **No.** Treat it as "no active trip for this driver" → clear/reset the held ride and leave `/trip` for Home (accept path: stay on Home). Do not add a stage and do not show the cancelled/post view | `_stageFromStatus` has no case and defaults to `pre` (`trip_notifier.dart:182-190`), which renders "Waiting for the trip to start" with `canCancel == true` — a false live trip. `Ride.isTerminal` also excludes it (`shared/lib/src/models/ride.dart:64`). The server sets it when dispatch gives up (no assigned driver), and `/current` deliberately excludes it (`internal/repository/ride_repo.go:255-265`), so the by-id read is the source and a receipt/cancelled view would falsely imply the driver had a trip. Adding a stage would also require inventing UI for a state the driver never owns |

---

## 8. Out of scope / invariants

- **No server changes** (the state machine/CAS, the WS server funnel and the accept/cancel handlers
  are the dependency's job), **no rider-app changes**, **no `shared/` edits**, no migration.
- **No cancellation fee** (still `0`) and **no re-dispatch**: the server cancels the ride and never
  re-offers it; the copy is corrected here to stop claiming otherwise.
- **`no_driver_available` is not a `TripStage`.** It means no active trip for this driver:
  clear/reset + leave to Home (`§5.1`, `§5.3`, `§7f`). Never render the cancelled/post view and
  never leave `canCancel == true` on a "waiting" screen. The by-id read is the source because
  `/current` excludes it (`internal/repository/ride_repo.go:255-265`).
- **Every accept-failure/terminal path must null the phantom or replace it with a real terminal
  ride** so Home's `_tripPushed` latch resets when `currentRide == null`
  (`driver_app/lib/features/home/presentation/home_screen.dart:134-141`); a stale placeholder
  would pin `_tripPushed` true forever.
- **Accept authorization is a server dependency, not a client workaround.** The accept handler
  does not verify offer ownership (`internal/handler/ride.go:681-685`;
  `internal/service/dispatch.go:400-412`); the API plan's funnel fixes it. The app must not
  invent a client-side check.
- **Preserve the concurrent uncommitted arrival/trip work.** Do not rewrite
  `driver_app/lib/features/trip/presentation/trip_screen.dart:35-42,196-202` or
  `driver_app/test/features/trip/presentation/trip_screen_test.dart:1-24,31-47,118-141,285-313`.
  If the `_publishArrivalFix` comment still says "websocket accept mounts this screen on a
  placeholder", leave it: it is a comment in the concurrent hunk and will be reconciled after that
  work is committed. The behavior it protects (publish on a server-confirmed `accepted`) remains
  correct.
- The `[offer]` explicit-dismiss contract stays: a live offer is only left via Accept, Pass, or
  the explicit Dismiss once closed (bug #20).
- Every error copy that reaches the driver comes from the API `message` via `apiErrorMessage` when
  available; never render a raw `err.toString()`.

## 9. Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

- Flutter runs are **serialized across agents** in this tree; do not run `flutter`/`dart` directly.
- The full `melos run test` counts drift after post-audit commits — **re-count from the tree and
  the actual run**, never from `driver_app_plans/STATUS.md`'s historical totals.
- Android/iOS modal dismissal, WebSocket timing and the on-device accept/cancel race are
  **UNVERIFIABLE** in this WSL tree; close those on a device.
- The dependency `api_plans/[rides]_cancel_accept_race.md` must be landed before this plan can be
  verified end-to-end; until then, the app-side tests use mocked server outcomes.

## 10. Residual

- The accept `200` body still carries only `{"message":"ride accepted"}`; the app pays one extra
  `GET /driver/rides/:id`. A future API change returning the ride would let the client drop the
  read, but this plan does not change the contract.
- `GET /driver/rides/:id` has no ownership filter (`internal/handler/ride.go:295-314`); the app
  only ever calls it for the id it just accepted. Tightening the server read is out of scope.
- A pre-fix client (or a frame already in flight) can still carry an optimistic placeholder; the
  `ride.accept_failed` / terminal-`ride.updated` handlers clear/terminate it, but the old client
  binary itself is not repaired by this plan.
