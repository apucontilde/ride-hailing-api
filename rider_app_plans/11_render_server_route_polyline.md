# Plan: Render Server-Computed Route Polyline Instead of Straight Line

## Problem
When both pickup and dropoff are set, the map shows a straight line between the two points. It should show the actual road-following route returned by the backend's `/api/v1/navigation/route` endpoint.

## Current State
- `home_screen.dart:89-97` — Polyline is two points (pickup → destination), straight line.
- Backend endpoint `GET /api/v1/navigation/route` exists and returns:
  ```json
  {
    "polyline": [{"lat": ..., "lng": ...}, ...],
    "total_distance_m": 1234.5,
    "total_duration_s": 112
  }
  ```
- `endpoints.dart` does NOT include a navigation route endpoint.

## Solution

### Files to Modify
1. `rider_app/lib/core/api/endpoints.dart` — Add route endpoint
2. `rider_app/lib/features/home/data/home_provider.dart` — Add route provider
3. `rider_app/lib/features/home/model/place.dart` — (no change needed, `LatLng` already used)
4. `rider_app/lib/features/home/presentation/home_screen.dart` — Consume route provider, render polyline

### Changes

#### 1. Add endpoint (`endpoints.dart`)
```dart
static const String navigationRoute = '$prefix/navigation/route';
```

#### 2. Add route model and provider (`home_provider.dart`)

Create a lightweight model (or inline the response):
```dart
class NavigationRoute {
  final List<LatLng> polyline;
  final double totalDistanceM;
  final double totalDurationS;

  NavigationRoute({required this.polyline, required this.totalDistanceM, required this.totalDurationS});

  factory NavigationRoute.fromJson(Map<String, dynamic> json) {
    final coords = json['polyline'] as List<dynamic>? ?? [];
    return NavigationRoute(
      polyline: coords.map((c) => LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble())).toList(),
      totalDistanceM: (json['total_distance_m'] as num).toDouble(),
      totalDurationS: (json['total_duration_s'] as num).toDouble(),
    );
  }
}
```

Add args class and provider:
```dart
class RouteArgs {
  final double fromLat, fromLng, toLat, toLng;
  const RouteArgs({required this.fromLat, required this.fromLng, required this.toLat, required this.toLng});

  @override
  bool operator ==(Object other) =>
      other is RouteArgs &&
      other.fromLat == fromLat && other.fromLng == fromLng &&
      other.toLat == toLat && other.toLng == toLng;

  @override
  int get hashCode => Object.hash(fromLat, fromLng, toLat, toLng);
}

final navigationRouteProvider = FutureProvider.family<NavigationRoute, RouteArgs>((ref, args) async {
  final apiClient = ref.read(apiClientProvider);
  final response = await apiClient.dio.get(
    ApiEndpoints.navigationRoute,
    queryParameters: {
      'from_lat': args.fromLat,
      'from_lng': args.fromLng,
      'to_lat': args.toLat,
      'to_lng': args.toLng,
    },
  );
  return NavigationRoute.fromJson(response.data as Map<String, dynamic>);
});
```

#### 3. Update home screen (`home_screen.dart`)

- Compute the `RouteArgs` when both pickup and destination are set.
- Watch the `navigationRouteProvider`.
- Replace the straight-line `Polyline` with the server route polyline.
- Show a loading indicator while the route is fetching.
- Fall back to straight line on error.

```dart
// Compute route args
final pickup = _pickupLocation != null
    ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
    : _currentPosition;
final routeArgs = (pickup != null && _destination != null)
    ? RouteArgs(
        fromLat: pickup.latitude,
        fromLng: pickup.longitude,
        toLat: _destination!.lat,
        toLng: _destination!.lng,
      )
    : null;

// Watch route
final routeAsync = routeArgs != null ? ref.watch(navigationRouteProvider(routeArgs)) : null;

// In PolylineLayer:
PolylineLayer(
  polylines: [
    if (routeAsync != null)
      routeAsync.when(
        data: (route) => Polyline(
          points: route.polyline,
          color: Colors.blue,
          strokeWidth: 4.0,
        ),
        loading: () => Polyline(
          points: [if (pickup != null) pickup, LatLng(_destination!.lat, _destination!.lng)],
          color: Colors.grey,
          strokeWidth: 2.0,
        ),
        error: (_, __) => Polyline(
          points: [if (pickup != null) pickup, LatLng(_destination!.lat, _destination!.lng)],
          color: Colors.blue,
          strokeWidth: 4.0,
        ),
      ),
  ],
),
```

#### 4. Display distance/duration (optional enhancement)
Show route distance and duration in the bottom sheet or a small info chip above the "Request Trip" button, using `route.totalDistanceM` and `route.totalDurationS`.

### Verification
- Select pickup and destination → server route polyline (following roads) should render
- While route is loading → grey fallback straight line or loading state
- If route API fails → graceful fallback to straight line
- Zoom-to-fit (Plan 01) should work with the route polyline bounds
- Screen should refresh immediately (Plan 02)
