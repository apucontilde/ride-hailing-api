# Rider App Next Steps

## Current State

Last visible commits:

- `10ee90c` `Fresh slop`
- `747bb97` `sloppiest`

What is already in place:

- Flutter app scaffold and platform targets
- Riverpod auth state, secure token storage, and API client
- GoRouter auth redirects and basic screens for splash, login, register, forgot password, home, location search, and driver matching
- WebSocket service with header-based bearer auth
- Auth restore/login/logout wiring for WebSocket connect and disconnect
- Initial API guide with websocket auth and event sections updated
- Windows build currently passes

## Gaps To Close

- Router mismatch: `DriverMatchingScreen` navigates to `/active-ride`, but the route is not defined.
- Active ride screen still mocks ride cancellation.
- WebSocket event handling is still based on old/local contract names in places and needs to be aligned end-to-end with `ride.updated` and `driver.location`.
- Location permission flow is incomplete on the home screen.
- Several guide endpoints are documented but not implemented in the app.
- Several route/API payload shapes in the guide do not match the current client expectations.

## Immediate Plan

1. Fix navigation completeness.
- Add `/active-ride` to `lib/core/router/app_router.dart`.
- Wire it to `ActiveRideScreen`.

2. Replace mocked ride actions.
- Implement real cancel ride logic in `ActiveRideScreen`.
- Add ride loading/error handling where the UI currently assumes success.

3. Align WebSocket ride state handling.
- Update `ride_status_provider.dart` to consume the guide's `ride.updated` and `driver.location` event shapes.
- Make the active ride UI resilient to missing or partial ride payloads.

4. Finish location bootstrap.
- Request location permission before reading current position.
- Add fallback UI when location is unavailable.

5. Align backend contract usage.
- Confirm ride creation response shape and make app/docs consistent.
- Confirm the real response shape for `GET /geo/nearby-drivers`, `GET /estimates/price`, and `GET /places/autocomplete`.
- Update `POST /rides` docs to match the app payload if the API stays on the current client shape.

6. Update `RIDER_API_GUIDE.md`.
- Add a routes section for the actual app paths.
- Document which endpoints are implemented, stubbed, or not yet wired in the app.
- Mark known mismatches and planned follow-up work clearly.

## Missing Functionality

- Active ride screen route and navigation wiring
- WebSocket-driven ride state updates
- Live driver tracking beyond the current local position stream
- Real ride cancellation API call
- Rating flow
- Tip flow
- Receipt screen/data binding
- Profile and payment methods screens
- Ride history screens
- SOS flow

## Recommended Order

1. Router fix
2. Ride cancel and ride state handling
3. Location permission flow
4. Guide update
5. Remaining feature screens

## Done Criteria

- App navigation no longer hits missing routes
- Auth flow and WebSocket connection are consistent
- API guide matches implemented routes and payloads
- Stubbed functionality is explicitly labeled or replaced
