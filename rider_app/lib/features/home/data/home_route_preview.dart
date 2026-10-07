import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'home_provider.dart';
import 'trip_route_provider.dart' show TripRouteStatus;

/// The Home route preview, derived from [navigationRouteProvider]'s
/// `AsyncValue`.
///
/// It speaks the active trip's vocabulary ([TripRouteStatus]) so the preview
/// and the active-trip flow cannot drift apart:
///
/// * [TripRouteStatus.ready] — the API's road geometry, drawn solid blue.
/// * [TripRouteStatus.estimate] — the API's own geometry, drawn grey dashed and
///   labeled "Estimated"; never a client-synthesized straight line.
/// * [TripRouteStatus.unavailable] — no geometry at all; [message] carries the
///   API's error and the info row offers a Retry.
/// * [TripRouteStatus.loading] — nothing trustworthy yet.
///
/// A failed **refresh** that still has a previously fetched route keeps that
/// road geometry ([isStale]) and surfaces the error, instead of swapping the
/// road route for a straight line.
class HomeRoutePreview {
  final TripRouteStatus status;

  /// The geometry to draw, straight from the API. Empty unless [isReady] or
  /// [isEstimate].
  final List<LatLng> polyline;
  final double totalDistanceM;
  final double totalDurationS;

  /// Why the preview is an estimate, or the failure text; rendered verbatim.
  final String? message;

  /// True when this is a retained route whose latest refresh failed.
  final bool isStale;

  const HomeRoutePreview({
    this.status = TripRouteStatus.idle,
    this.polyline = const [],
    this.totalDistanceM = 0,
    this.totalDurationS = 0,
    this.message,
    this.isStale = false,
  });

  static const String estimateReason =
      'Part of this route is outside the mapped road network.';
  static const String unavailableReason =
      'No road route is available right now.';

  bool get isReady => status == TripRouteStatus.ready;
  bool get isEstimate => status == TripRouteStatus.estimate;
  bool get isLoading => status == TripRouteStatus.loading;
  bool get isUnavailable => status == TripRouteStatus.unavailable;

  /// A solid, road-following route.
  bool get hasRoadRoute => status == TripRouteStatus.ready;

  /// Any drawable geometry (road or API-flagged estimate).
  bool get hasRoute => isReady || isEstimate;

  /// A failure is on screen: either nothing was ever routed, or a retained
  /// route's refresh failed.
  bool get hasError => isUnavailable || isStale;

  factory HomeRoutePreview.fromAsync(AsyncValue<NavigationRoute>? async) {
    if (async == null) return const HomeRoutePreview();
    final route = async.valueOrNull;

    if (async.hasError && route == null) {
      return HomeRoutePreview(
        status: TripRouteStatus.unavailable,
        message: apiErrorMessage(async.error!, unavailableReason),
      );
    }
    if (route == null) {
      return const HomeRoutePreview(status: TripRouteStatus.loading);
    }

    // A retained route survives a failed refresh: keep the geometry it came
    // with and surface the error as a stale state rather than a straight line.
    final stale = async.hasError;
    final errorMessage =
        stale ? apiErrorMessage(async.error!, unavailableReason) : null;

    // Fewer than two points is not a route, estimate flag or not.
    if (route.polyline.length < 2) {
      return HomeRoutePreview(
        status: TripRouteStatus.unavailable,
        message: errorMessage ?? unavailableReason,
      );
    }

    if (route.isEstimate) {
      return HomeRoutePreview(
        status: TripRouteStatus.estimate,
        polyline: route.polyline,
        totalDistanceM: route.totalDistanceM,
        totalDurationS: route.totalDurationS,
        message: errorMessage ?? estimateReason,
        isStale: stale,
      );
    }

    return HomeRoutePreview(
      status: TripRouteStatus.ready,
      polyline: route.polyline,
      totalDistanceM: route.totalDistanceM,
      totalDurationS: route.totalDurationS,
      message: errorMessage,
      isStale: stale,
    );
  }
}
