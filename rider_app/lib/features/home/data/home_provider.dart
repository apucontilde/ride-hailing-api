import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';
import '../model/place.dart';
import '../model/ride_estimate.dart';
import '../model/driver.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/auth/auth_provider.dart';

final nearbyDriversProvider =
    FutureProvider.family<List<NearbyDriver>, LatLng>((ref, center) async {
  final apiClient = ref.read(apiClientProvider);
  final response = await apiClient.dio.get(
    ApiEndpoints.nearbyDrivers,
    queryParameters: {'lat': center.latitude, 'lng': center.longitude},
  );
  final data = response.data as Map<String, dynamic>;
  final drivers = data['drivers'] as List<dynamic>? ?? [];
  return drivers
      .map((json) => NearbyDriver.fromJson(json as Map<String, dynamic>))
      .toList();
});

/// One ordered intermediate stop of a price-estimate request. Held **by value**
/// so the [priceEstimatesProvider] family key is stable across rebuilds: a
/// `Place` compares by identity and would re-fetch the estimate every frame.
class EstimateStop {
  final double lat;
  final double lng;
  final String? address;

  const EstimateStop({required this.lat, required this.lng, this.address});

  @override
  bool operator ==(Object other) =>
      other is EstimateStop &&
      other.lat == lat &&
      other.lng == lng &&
      other.address == address;

  @override
  int get hashCode => Object.hash(lat, lng, address);
}

/// The `POST /estimates/price` request: the pickup/dropoff pair plus the same
/// ordered intermediate stops the create-ride body takes. Array position **is**
/// the visit order; an empty list is omitted so the single-stop body is
/// byte-for-byte the pre-waypoint payload.
class PriceEstimateArgs {
  final double pickupLat;
  final double pickupLng;
  final double dropoffLat;
  final double dropoffLng;
  final List<EstimateStop> stops;

  const PriceEstimateArgs({
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffLat,
    required this.dropoffLng,
    this.stops = const [],
  });

  @override
  bool operator ==(Object other) {
    if (other is! PriceEstimateArgs) return false;
    if (other.pickupLat != pickupLat ||
        other.pickupLng != pickupLng ||
        other.dropoffLat != dropoffLat ||
        other.dropoffLng != dropoffLng ||
        other.stops.length != stops.length) {
      return false;
    }
    for (var i = 0; i < stops.length; i++) {
      if (other.stops[i] != stops[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        pickupLat,
        pickupLng,
        dropoffLat,
        dropoffLng,
        Object.hashAll(stops),
      );
}

/// The waypoint-aware price estimate. `[fare]_waypoint_fare` hard-cut the
/// endpoint from `GET` to `POST` (the `GET` route is removed with no alias), so
/// this must use `POST` with a JSON body. The ordered `stops` are a top-level
/// sibling of the pickup/dropoff fields, mirroring `createRide` below; the API
/// prices the whole itinerary and returns the same `estimates` envelope.
final priceEstimatesProvider =
    FutureProvider.family<List<RideEstimate>, PriceEstimateArgs>((ref, args) async {
  final apiClient = ref.read(apiClientProvider);
  final body = <String, dynamic>{
    'pickup_lat': args.pickupLat,
    'pickup_lng': args.pickupLng,
    'dropoff_lat': args.dropoffLat,
    'dropoff_lng': args.dropoffLng,
  };
  if (args.stops.isNotEmpty) {
    body['stops'] = [
      for (final stop in args.stops)
        {'lat': stop.lat, 'lng': stop.lng, 'address': stop.address},
    ];
  }
  final response = await apiClient.dio.post(
    ApiEndpoints.priceEstimate,
    data: body,
  );
  final data = (response.data as Map<String, dynamic>)['estimates'] as List<dynamic>? ?? [];
  return data.map((json) => RideEstimate.fromJson(json as Map<String, dynamic>)).toList();
});

class PlaceSearchArgs {
  final String query;
  final double lat;
  final double lng;
  const PlaceSearchArgs({required this.query, required this.lat, required this.lng});

  @override
  bool operator ==(Object other) =>
      other is PlaceSearchArgs &&
      other.query == query &&
      other.lat == lat &&
      other.lng == lng;

  @override
  int get hashCode => Object.hash(query, lat, lng);
}

const _searchRadiusM = 30000.0;

final placeSearchDebounceProvider =
    Provider<Duration>((ref) => const Duration(milliseconds: 350));

final placeSearchProvider =
    FutureProvider.family<List<Place>, PlaceSearchArgs>((ref, args) async {
  if (args.query.trim().isEmpty) return [];
  final apiClient = ref.read(apiClientProvider);

  final response = await apiClient.dio.get(
    ApiEndpoints.placesAutocomplete,
    queryParameters: {
      'lat': args.lat,
      'lng': args.lng,
      'radius': _searchRadiusM,
      'q': args.query,
      'limit': 10,
    },
  );
  return (response.data['places'] as List<dynamic>? ?? [])
      .map((j) => Place.fromJson(j as Map<String, dynamic>))
      .toList();
});

class NavigationRoute {
  final List<LatLng> polyline;
  final double totalDistanceM;
  final double totalDurationS;
  final bool isEstimate;

  NavigationRoute({
    required this.polyline,
    required this.totalDistanceM,
    required this.totalDurationS,
    this.isEstimate = false,
  });

  factory NavigationRoute.fromJson(Map<String, dynamic> json) {
    final coords = json['polyline'] as List<dynamic>? ?? [];
    return NavigationRoute(
      polyline: coords
          .map((c) => LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()))
          .toList(),
      totalDistanceM: (json['total_distance_m'] as num).toDouble(),
      totalDurationS: (json['total_duration_s'] as num).toDouble(),
      isEstimate: json['is_estimate'] == true,
    );
  }
}

class RouteArgs {
  final double fromLat, fromLng, toLat, toLng;

  const RouteArgs({
    required this.fromLat,
    required this.fromLng,
    required this.toLat,
    required this.toLng,
  });

  @override
  bool operator ==(Object other) =>
      other is RouteArgs &&
      other.fromLat == fromLat &&
      other.fromLng == fromLng &&
      other.toLat == toLat &&
      other.toLng == toLng;

  @override
  int get hashCode => Object.hash(fromLat, fromLng, toLat, toLng);
}

final navigationRouteProvider =
    FutureProvider.family<NavigationRoute, RouteArgs>((ref, args) async {
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

class RideCreationState {
  final bool isLoading;
  final String? error;
  final String? rideId;
  final bool isCancelling;
  final String? cancelError;

  const RideCreationState({
    this.isLoading = false,
    this.error,
    this.rideId,
    this.isCancelling = false,
    this.cancelError,
  });

  RideCreationState copyWith({
    bool? isLoading,
    String? error,
    String? rideId,
    bool? isCancelling,
    String? cancelError,
  }) {
    return RideCreationState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      rideId: rideId ?? this.rideId,
      isCancelling: isCancelling ?? this.isCancelling,
      cancelError: cancelError,
    );
  }
}

/// The honest result of one `POST /rides/:id/cancel`, derived from the HTTP
/// status (mapped `ApiException` first, raw response second).
///
/// [cancelError] keeps carrying the API's public `message`; this outcome is the
/// caller's signal for **what to do**, not another copy of the text.
enum CancelOutcome { success, notFound, conflict, failed }

class RideCreationNotifier extends StateNotifier<RideCreationState> {
  final ApiClient _apiClient;
  bool _disposed = false;
  String? _attemptKey;

  RideCreationNotifier(this._apiClient) : super(const RideCreationState());

  Future<void> createRide({
    required double pickupLat,
    required double pickupLng,
    required String pickupAddress,
    required double dropoffLat,
    required double dropoffLng,
    required String dropoffAddress,
    required String vehicleType,
    List<Place> stops = const [],
  }) async {
    state = state.copyWith(isLoading: true, error: null);
    // LC-0: reuse one key per booking attempt so retries replay the same
    // ride instead of creating duplicates. Cleared on success.
    _attemptKey ??= _generateIdempotencyKey();
    final body = <String, dynamic>{
      'pickup_lat': pickupLat,
      'pickup_lng': pickupLng,
      'pickup_address': pickupAddress,
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
      'dropoff_address': dropoffAddress,
      'vehicle_type': vehicleType,
    };
    // `[multi]`: the ordered intermediate stops are a top-level sibling of the
    // ride fields. Order in the array **is** the sequence (the API derives it);
    // `kind` is never sent — a client `kind:"destination"` is a 422, and the
    // final destination stays the top-level `dropoff_*`. An empty list is
    // omitted so the single-stop payload is byte-for-byte unchanged.
    if (stops.isNotEmpty) {
      body['stops'] = [
        for (final stop in stops)
          {'lat': stop.lat, 'lng': stop.lng, 'address': stop.address},
      ];
    }
    try {
      final response = await _apiClient.dio.post(
        ApiEndpoints.rides,
        data: body,
        options: Options(
          headers: {'Idempotency-Key': _attemptKey},
        ),
      );
      final data = response.data as Map<String, dynamic>;
      String? rideId;
      final rideObj = data['ride'];
      if (rideObj is Map<String, dynamic>) {
        rideId = rideObj['id'] as String?;
      } else {
        rideId = data['id'] as String?;
      }

      rideId ??= await _resolveCurrentRideId();

      if (rideId != null) {
        _attemptKey = null;
      }
      state = state.copyWith(isLoading: false, rideId: rideId);
    } on DioException catch (e) {
      state = state.copyWith(isLoading: false, error: _errorMessage(e));
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<String?> _resolveCurrentRideId() async {
    try {
      final current = await _apiClient.dio.get(ApiEndpoints.currentRide);
      final data = current.data as Map<String, dynamic>?;
      final rideObj = data?['ride'];
      if (rideObj is Map<String, dynamic>) {
        return rideObj['id'] as String?;
      }
    } on DioException {
      // Fall through — caller reports the failure.
    }
    return null;
  }

  Future<CancelOutcome> cancelRide(String rideId) async {
    state = state.copyWith(isCancelling: true, cancelError: null);
    try {
      await _apiClient.dio.post(ApiEndpoints.cancelRide(rideId));
      if (_disposed) return CancelOutcome.success;
      state = state.copyWith(isCancelling: false);
      return CancelOutcome.success;
    } on DioException catch (e) {
      final mapped = e.error;
      final statusCode =
          mapped is ApiException ? mapped.statusCode : e.response?.statusCode;
      if (_disposed) return _cancelOutcomeForStatus(statusCode);
      state = state.copyWith(
        isCancelling: false,
        cancelError: _errorMessage(e),
      );
      return _cancelOutcomeForStatus(statusCode);
    } on ApiException catch (e) {
      if (_disposed) return _cancelOutcomeForStatus(e.statusCode);
      state = state.copyWith(
        isCancelling: false,
        cancelError: e.message,
      );
      return _cancelOutcomeForStatus(e.statusCode);
    }
  }

  /// `200` (including an idempotent repeat) is the only success; `404` and `409`
  /// are the two honest client-visible conflicts, everything else (today's
  /// `400`, `422`, `5xx`, transport failures with no status) stays retryable as
  /// a generic failure.
  static CancelOutcome _cancelOutcomeForStatus(int? statusCode) {
    return switch (statusCode) {
      404 => CancelOutcome.notFound,
      409 => CancelOutcome.conflict,
      _ => CancelOutcome.failed,
    };
  }

  void reset() {
    state = const RideCreationState();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String _errorMessage(DioException e) {
    final mapped = e.error;
    if (mapped is ApiException) return mapped.message;
    final data = e.response?.data;
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] != null) {
        return error['message'] as String;
      }
      if (data['message'] != null) return data['message'] as String;
    }
    return e.message ?? 'Failed to complete request';
  }

  String _generateIdempotencyKey() {
    return '${DateTime.now().millisecondsSinceEpoch}-${_randomString(8)}';
  }

  String _randomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(length, (_) => chars[DateTime.now().microsecondsSinceEpoch % chars.length]).join();
  }
}

final rideCreationProvider =
    StateNotifierProvider<RideCreationNotifier, RideCreationState>((ref) {
  final apiClient = ref.read(apiClientProvider);
  return RideCreationNotifier(apiClient);
});
