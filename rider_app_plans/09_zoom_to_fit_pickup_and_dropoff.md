# Plan: Zoom Map to Fit Pickup and Dropoff

## Problem
When a destination is selected, the map does not adjust its viewport to show both the pickup and dropoff markers. The user sees only the destination marker at the last zoom level, requiring manual pinch-to-zoom.

## Current Behavior
- `home_screen.dart:339-341` — After destination is set via `context.push<Place>`, only `setState(() => _destination = place)` is called. No map movement.
- `home_screen.dart:308-311` — When pickup is selected, the map moves to the pickup location at zoom 15.0, but does not account for destination.

## Solution
Compute a bounding box that contains both pickup and dropoff points, then use `fitCamera` to adjust the map viewport.

### Files to Modify
- `rider_app/lib/features/home/presentation/home_screen.dart`

### Changes

1. **Create a helper method `_fitBounds`** that accepts two `LatLng` points and uses `mapController.fitCamera()` with `CameraFit.bounds()` from `flutter_map`. Add padding to keep markers visible.

2. **Call `_fitBounds` when destination is set** (line 339-341):
   ```dart
   if (place != null && mounted) {
     setState(() => _destination = place);
     final pickup = _pickupLocation != null
         ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
         : _currentPosition;
     if (pickup != null) {
       _fitBounds(pickup, LatLng(place.lat, place.lng));
     }
   }
   ```

3. **Call `_fitBounds` when pickup is set** (line 306-312):
   Replace the hard-coded `_mapController.move(...)` with `_fitBounds` if destination is already set, otherwise keep the move to pickup location.

4. **Helper method:**
   ```dart
   void _fitBounds(LatLng pointA, LatLng pointB) {
     _mapController.fitCamera(
       CameraFit.bounds(
         bounds: LatLngBounds(pointA, pointB),
         padding: const EdgeInsets.all(60),
         maxZoom: 16.0,
       ),
     );
   }
   ```

## Max Zoom Cap
`CameraFit.bounds` defaults `maxZoom` to the map's maximum (19). When pickup and dropoff are close together (same block/neighborhood), the fit zooms to street level and the surrounding context is lost. Pass `maxZoom: 16.0` so the fit never exceeds a neighborhood-level zoom while still framing both markers. `CameraFit.bounds` clamps the computed zoom to this value (see `camera_fit.dart` `_getBoundsZoom` / `fit` in flutter_map 7).

### Verification
- Set pickup, then set destination → map should zoom to show both markers with padding
- Nearby pickup/dropoff (same block) → map should stop at zoom 16, not street level
- Set destination, then change pickup → map should adjust
- Set only pickup (no destination) → map should move to pickup at zoom 15 (existing behavior preserved)
