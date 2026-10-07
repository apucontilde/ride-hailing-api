import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/features/home/data/home_provider.dart';
import 'package:rider_app/features/home/data/home_route_preview.dart';
import 'package:rider_app/features/home/data/trip_route_provider.dart'
    show TripRouteStatus;

NavigationRoute route({
  List<LatLng>? polyline,
  bool isEstimate = false,
  double distance = 1500,
  double duration = 180,
}) {
  return NavigationRoute(
    polyline: polyline ??
        const [
          LatLng(9.9281, -84.0907),
          LatLng(9.934, -84.095),
          LatLng(9.94, -84.10),
        ],
    totalDistanceM: distance,
    totalDurationS: duration,
    isEstimate: isEstimate,
  );
}

/// The state Riverpod produces when a provider that already has data is
/// refreshed and the refresh fails: `AsyncError` that still carries the
/// previous value ([AsyncValue.copyWithPrevious]).
AsyncValue<NavigationRoute> staleError(
  NavigationRoute previous,
  Object error,
) {
  return AsyncValue<NavigationRoute>.error(error, StackTrace.empty)
      .copyWithPrevious(AsyncValue.data(previous));
}

void main() {
  group('HomeRoutePreview.fromAsync', () {
    test('no route args (null) is idle, not loading', () {
      final preview = HomeRoutePreview.fromAsync(null);
      expect(preview.status, TripRouteStatus.idle);
      expect(preview.polyline, isEmpty);
      expect(preview.hasError, isFalse);
    });

    test('a pending first fetch is loading with no geometry', () {
      final preview =
          HomeRoutePreview.fromAsync(const AsyncValue<NavigationRoute>.loading());
      expect(preview.status, TripRouteStatus.loading);
      expect(preview.polyline, isEmpty);
      expect(preview.hasError, isFalse);
    });

    test('a non-estimate road route is ready and keeps the API geometry', () {
      final api = route();
      final preview = HomeRoutePreview.fromAsync(AsyncValue.data(api));

      expect(preview.status, TripRouteStatus.ready);
      expect(preview.hasRoadRoute, isTrue);
      expect(preview.isEstimate, isFalse);
      expect(preview.hasError, isFalse);
      expect(preview.polyline, same(api.polyline));
      expect(preview.totalDistanceM, 1500);
      expect(preview.totalDurationS, 180);
      expect(preview.message, isNull);
    });

    test('an is_estimate body is estimate with the API geometry, labeled', () {
      final api = route(isEstimate: true);
      final preview = HomeRoutePreview.fromAsync(AsyncValue.data(api));

      expect(preview.status, TripRouteStatus.estimate);
      expect(preview.hasRoadRoute, isFalse);
      expect(preview.isEstimate, isTrue);
      expect(preview.hasError, isFalse);
      expect(preview.polyline, same(api.polyline));
      expect(preview.message, HomeRoutePreview.estimateReason);
    });

    test('a non-estimate body with <2 points is unavailable, not a fallback', () {
      final preview = HomeRoutePreview.fromAsync(
        AsyncValue.data(route(polyline: const [LatLng(9.9, -84.1)])),
      );
      expect(preview.status, TripRouteStatus.unavailable);
      expect(preview.polyline, isEmpty);
      expect(preview.hasError, isTrue);
      expect(preview.message, HomeRoutePreview.unavailableReason);
    });

    test('an estimate body with <2 points is unavailable too', () {
      final preview = HomeRoutePreview.fromAsync(
        AsyncValue.data(
          route(polyline: const [LatLng(9.9, -84.1)], isEstimate: true),
        ),
      );
      expect(preview.status, TripRouteStatus.unavailable);
      expect(preview.polyline, isEmpty);
    });

    test('an error with no previous value is unavailable with the API message',
        () {
      final preview = HomeRoutePreview.fromAsync(
        AsyncValue<NavigationRoute>.error(
          ApiException('invalid coordinates', statusCode: 422),
          StackTrace.empty,
        ),
      );
      expect(preview.status, TripRouteStatus.unavailable);
      expect(preview.polyline, isEmpty);
      expect(preview.hasError, isTrue);
      expect(preview.message, 'invalid coordinates');
    });

    test('a failed refresh retains the previous road route and surfaces the error',
        () {
      final previous = route();
      final preview = HomeRoutePreview.fromAsync(
        staleError(previous, ApiException('failed to calculate route')),
      );

      expect(preview.status, TripRouteStatus.ready);
      expect(preview.polyline, same(previous.polyline),
          reason: 'the road route must not be swapped for a straight line');
      expect(preview.isStale, isTrue);
      expect(preview.hasError, isTrue);
      expect(preview.message, 'failed to calculate route');
    });

    test('a failed refresh retains a previous estimate as an estimate', () {
      final previous = route(isEstimate: true);
      final preview = HomeRoutePreview.fromAsync(
        staleError(previous, ApiException('boom')),
      );

      expect(preview.status, TripRouteStatus.estimate);
      expect(preview.polyline, same(previous.polyline));
      expect(preview.isStale, isTrue);
      expect(preview.hasError, isTrue);
      expect(preview.message, 'boom');
    });
  });
}
