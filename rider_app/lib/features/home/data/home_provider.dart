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

final priceEstimatesProvider = FutureProvider.family<List<RideEstimate>, Map<String, double>>((ref, coords) async {
  final apiClient = ref.read(apiClientProvider);
  final response = await apiClient.dio.get(
    ApiEndpoints.priceEstimate,
    queryParameters: {
      'pickup_lat': coords['pickup_lat'],
      'pickup_lng': coords['pickup_lng'],
      'dropoff_lat': coords['dropoff_lat'],
      'dropoff_lng': coords['dropoff_lng'],
    },
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

  Future<void> cancelRide(String rideId) async {
    state = state.copyWith(isCancelling: true, cancelError: null);
    try {
      await _apiClient.dio.post(ApiEndpoints.cancelRide(rideId));
      if (_disposed) return;
      state = state.copyWith(isCancelling: false);
    } on DioException catch (e) {
      if (_disposed) return;
      state = state.copyWith(
        isCancelling: false,
        cancelError: _errorMessage(e),
      );
    } on ApiException catch (e) {
      if (_disposed) return;
      state = state.copyWith(
        isCancelling: false,
        cancelError: e.message,
      );
    }
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
