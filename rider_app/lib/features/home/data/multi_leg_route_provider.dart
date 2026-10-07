import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import 'home_provider.dart' show NavigationRoute;

/// One ordered intermediate stop of a pre-booking itinerary, held **by value**
/// so a [RoutePlan] family key is stable across rebuilds. A `Place` compares by
/// identity, so keying the family on `Place` would re-fetch the route on every
/// frame; the raw coordinates cannot drift that way.
class RouteWaypoint {
  final double lat;
  final double lng;

  const RouteWaypoint(this.lat, this.lng);

  @override
  bool operator ==(Object other) =>
      other is RouteWaypoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);
}

/// The pre-booking itinerary: pickup → ordered intermediate stops → the final
/// destination. The destination is always the last leg; it is never one of
/// [stops].
class RoutePlan {
  final double fromLat;
  final double fromLng;
  final double toLat;
  final double toLng;
  final List<RouteWaypoint> stops;

  const RoutePlan({
    required this.fromLat,
    required this.fromLng,
    required this.toLat,
    required this.toLng,
    this.stops = const [],
  });

  List<LatLng> get points => [
        LatLng(fromLat, fromLng),
        for (final stop in stops) LatLng(stop.lat, stop.lng),
        LatLng(toLat, toLng),
      ];

  @override
  bool operator ==(Object other) {
    if (other is! RoutePlan) return false;
    if (other.fromLat != fromLat ||
        other.fromLng != fromLng ||
        other.toLat != toLat ||
        other.toLng != toLng ||
        other.stops.length != stops.length) {
      return false;
    }
    for (var i = 0; i < stops.length; i++) {
      if (other.stops[i] != stops[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(fromLat, fromLng, toLat, toLng, Object.hashAll(stops));
}

/// The pre-booking multi-leg preview.
///
/// Routes every consecutive pair of the itinerary (pickup → stop 1 → … → the
/// final destination) through `GET /navigation/route` and concatenates the
/// legs, summing distance and duration. It speaks the same [NavigationRoute]
/// vocabulary as the single-leg provider, so
/// `HomeRoutePreview.fromAsync` derives the map/numbers status unchanged and
/// the `[map]` honesty contract still holds:
///
///  * a leg the API flags `is_estimate` makes the whole preview an estimate
///    (grey dashed, labeled) while keeping the API's geometry;
///  * any failed or malformed leg makes the whole preview fail with **no**
///    polyline, so a partial itinerary can never be drawn as a confident line.
///
/// It is deliberately independent of `TripRouteNotifier`: that notifier owns
/// the active-ride lifecycle and its refresh tick, this one is a plain
/// preview-shaped future.
final multiLegRouteProvider =
    FutureProvider.family<NavigationRoute, RoutePlan>((ref, plan) async {
  final apiClient = ref.read(apiClientProvider);
  final points = plan.points;
  if (points.length < 2) {
    throw const _UnrouteableItinerary();
  }

  final polyline = <LatLng>[];
  var estimate = false;
  double distance = 0;
  double duration = 0;

  for (var i = 0; i < points.length - 1; i++) {
    final from = points[i];
    final to = points[i + 1];
    if (from == to) continue;
    final leg = await _fetchLeg(apiClient, from, to);
    if (leg.polyline.length < 2) {
      throw const _UnrouteableItinerary();
    }
    if (leg.isEstimate) estimate = true;
    distance += leg.totalDistanceM;
    duration += leg.totalDurationS;
    for (final point in leg.polyline) {
      if (polyline.isNotEmpty && polyline.last == point) continue;
      polyline.add(point);
    }
  }

  if (polyline.length < 2) {
    throw const _UnrouteableItinerary();
  }

  return NavigationRoute(
    polyline: List<LatLng>.unmodifiable(polyline),
    totalDistanceM: distance,
    totalDurationS: duration,
    isEstimate: estimate,
  );
});

Future<NavigationRoute> _fetchLeg(
  ApiClient apiClient,
  LatLng from,
  LatLng to,
) async {
  final response = await apiClient.dio.get(
    ApiEndpoints.navigationRoute,
    queryParameters: {
      'from_lat': from.latitude,
      'from_lng': from.longitude,
      'to_lat': to.latitude,
      'to_lng': to.longitude,
    },
  );
  return NavigationRoute.fromJson(response.data as Map<String, dynamic>);
}

/// A plan that cannot be routed at all (fewer than two points, or a leg whose
/// body is not a route). Rendered by `HomeRoutePreview` as its honest
/// `unavailable` fallback — never as synthesized geometry.
class _UnrouteableItinerary implements Exception {
  const _UnrouteableItinerary();
}
