# Plan: Fix Screen Not Refreshing After Dropoff Selection

## Problem
After selecting a destination (dropoff) via the location search screen, the home screen does not visually refresh until the user taps somewhere on the screen. The polyline and markers appear stale.

## Root Cause Analysis
The issue is in `home_screen.dart:339-341`:
```dart
if (place != null && mounted) {
  setState(() => _destination = place);
}
```

`setState` is called, which should trigger a rebuild. However, the `flutter_map` `PolylineLayer` and `MarkerLayer` may not be rebuilding because:

1. The `PolylineLayer` is gated on `_currentPosition != null || _pickupLocation != null || _destination != null` (line 86), which should pass once destination is set.
2. The markers layer is gated on `_currentPosition != null || _pickupLocation != null` (line 100) — **this does NOT include `_destination`**, so destination markers may not render immediately.

Additionally, the `DraggableScrollableSheet` overlay sits on top of the map and may be intercepting touch events, preventing the map from repainting.

### Files to Modify
- `rider_app/lib/features/home/presentation/home_screen.dart`

### Changes

1. **Fix the MarkerLayer gate** (line 100): Add `_destination != null` to the condition:
   ```dart
   if (_currentPosition != null || _pickupLocation != null || _destination != null)
   ```

2. **Force map tile repaint** by using a `Key` on `FlutterMap` that changes when destination changes. Add a `ValueKey`:
   ```dart
   FlutterMap(
     key: ValueKey('map_${_destination?.id ?? 'none'}'),
     ...
   )
   ```
   This ensures the entire map widget rebuilds when destination changes. *(Use only if step 1 alone is insufficient.)*

3. **Alternative — use `WidgetsBinding.instance.addPostFrameCallback`** to trigger a map invalidate after `setState`:
   ```dart
   if (place != null && mounted) {
     setState(() => _destination = place);
     WidgetsBinding.instance.addPostFrameCallback((_) {
       _mapController.fitCamera(...); // also applies zoom-to-fit from Plan 01
     });
   }
   ```

### Verification
- Select a destination → polyline and markers should appear immediately without requiring a tap
- The bottom sheet should not block map updates
- Rapidly changing destinations should not cause flickering
