# e2e — browser suite for the Flutter web apps

End-to-end tests that drive the **real** `rider_app` and `driver_app` web UIs in
Edge against the **real** API, asserting user-visible behaviour.

This exists because of a specific bug: *a rider requested a ride and the driver
never received the offer.* Neither the Go test suite nor the Flutter widget
tests could catch it, for two independent reasons:

1. **The Go harness fabricated the driver.** `MockGeoRepo.FindNearbyDrivers`
   invented a `"simulated-driver"` whenever no real driver was online
   (`tests/testutil/mock_repos.go`), so dispatch always succeeded and
   "the driver got no offer" could never fail. Fixed by
   `FabricateNearbyDriver` + `NewStrictMockGeoRepo`.
2. **The widget tests stub the WebSocket.** They feed `ride.offer` straight
   into `RideStateNotifier`, so they prove the *reaction* to an offer but never
   that the offer is actually produced, delivered and rendered.

Only a real browser against a real server closes that gap.

## What it found

The suite is not hypothetical. Its first red run located the actual defect, and
a later one found a second:

1. **The offer was delivered and thrown away.**
   `AvailabilityNotifier.toggle()` updated only its own state and never wrote the
   resulting profile back into the shared `driverProfileProvider`; the home
   screen then gated the offer sheet on that stale cache's `isOnline`. So the
   driver was visibly online, the backend **did** send the offer (the server
   logged `all drivers declined` 30 s later), and the client dropped it on
   arrival. The gate now reads the offer itself, and the `_offerShown` latch is
   keyed to the ride id so a withdrawn offer cannot block the next one. See
   `driver_app_plans/03_offer_and_accept.md`.
2. **Going online published no position.** `LocationService` discards fixes
   while offline and geolocator only re-emits on movement, so a driver who
   toggled online while stationary had **no** `driver_positions` row and
   dispatch could not find them for as long as they stood still — online,
   waiting, never offered a ride, nothing on screen to explain it. This one
   presented as a 1-in-3 flake, because the spec used to sleep a guessed
   interval and hope a fix had landed. `waitForDriverLocation` now polls
   `GET /drivers/:id/location` until the row exists. See
   `driver_app_plans/02_online_status_loop.md`.

The suite also runs about twice as fast as it did with the sleep, because the
push now happens the instant the driver goes online instead of whenever
geolocator next felt like emitting.

## The hard problems, and how they are solved

**Flutter web paints into a `<canvas>`.** There is no DOM to query, and neither
app declares a `Semantics` label, so `page.getByText('Accept')` matches
nothing. Flutter ships a hidden `flt-semantics-placeholder` that, once
activated, builds a full semantics tree of real, focusable, aria-labelled DOM
nodes. Both `web/index.html` files auto-click it when the page is loaded with
`?e2e=1`, gated by a query flag so normal browsing is untouched.

**Geolocation is a prerequisite, not a detail.** Dispatch only finds a driver
who has a `driver_positions` row updated within the last 30 s
(`internal/repository/geo_repo.go:71-78`), and the app only pushes a fix when
the geolocator stream emits. Playwright grants the permission and pins the
position via CDP, so this is deterministic rather than dependent on a real GPS.

## Flutter-web semantics: the four things that will bite you

Measured against Flutter 3.44.2, not assumed — `scripts/dump-semantics-html.mjs`
prints the real markup if any of this drifts.

- **Every ancestor aggregates its descendants' text.** A plain
  `flt-semantics` + `hasText` match therefore resolves to the *root* of the
  tree: an "is this on screen?" assertion passes for anything, and `tap()`
  clicks the top-left corner because that node is full-bleed. All text locators
  are restricted to `flt-semantics:not(:has(flt-semantics))` — the nodes that
  actually own the text.
- **Buttons carry their label as inner text, not `aria-label`.** Filter on
  `role="button"`. Watch out for an `AppBar` title that reads the same as the
  submit button (the register screen has a heading *and* a button both reading
  "Sign Up") and comes first in DOM order.
- **Field accessible names are prefix-matched.** An empty field is
  `"Email Enter your email"` and a filled one just `"Email",` so
  `input[aria-label^="Email"]` is the reliable selector, not `="Email"`.
- **The viewport has to fit the app.** The rider home screen lays "Request
  Trip" out at y≈734, below a 720-tall viewport, so a click at the node's centre
  hit nothing. `VIEWPORT` in `helpers.ts` is 1280×1000 for this reason.

## Layout

| Path | What it is |
| --- | --- |
| `helpers.ts` | Semantics-tree locators, `tap`/`fill`, boot waits |
| `specs/ride-offer.spec.ts` | The rider-requests / driver-offers story |
| `playwright.config.ts` | Boots the API + both static servers |
| `scripts/probe-rider.mjs` | Walks a flow and dumps the tree at each step |
| `scripts/dump-semantics-html.mjs` | Prints the raw semantics markup |
| `../cmd/e2eserver` | The API under test (strict in-memory repos) |

## Running

```bash
# 1. Build both web apps against the e2e API (once, or after app changes)
cd e2e && npm install && npm run build:apps

# 2. Run
cd e2e && npm test
```

`npm run build:apps` shells out to `flutter build web` for both apps with
`--dart-define=API_BASE_URL=http://127.0.0.1:8099`; re-run it after any Dart
change or the suite tests the previous build. `playwright.config.ts` then starts
all three servers itself — nothing needs to be running first. Traces,
screenshots and video are kept **on failure only**; check `e2e/test-results/`
after a red run, and `node scripts/probe-rider.mjs` when the page snapshot is
the wrong page or not enough.

## Adding a story

1. Pick the user story (`USER_STORIES.md`, Part B driver/rider sections).
2. Drive it through the semantics tree using `button` / `field` / `text` /
   `switchToggle` from `helpers.ts`. Prefer those over raw selectors so the
   locators stay tolerant of Flutter re-parenting the tree.
3. Assert on what a *user* sees (a sheet, a fare, a status line) — not on
   network calls. The point of this suite is to catch integration breakage
   that unit tests structurally cannot.
4. Keep `workers: 1` in mind: `cmd/e2eserver` holds in-memory state, so specs
   share one server and create real users on it. Because `reuseExistingServer`
   also survives *across* runs, identities must be unique per run (see `uniq`),
   or `POST /auth/register` returns 409.
5. Do not use the 720-tall `Desktop Edge` preset; pass `VIEWPORT`.

## Known constraints

- **In-memory storage.** `cmd/e2eserver` uses the test mocks, so a restart
  wipes users. It boots the identical `router.SetupWithRepos` wiring as
  production, so only the storage layer is substituted.
- **Single worker, no parallelism,** for the reason above.
- **Not a Postgres test.** `tests/dispatch_offer_test.go` covers the same
  dispatch rules without a browser and is the faster inner loop; this suite is
  for the parts only a real UI can prove.
