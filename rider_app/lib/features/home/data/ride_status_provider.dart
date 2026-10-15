import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/websocket_service.dart';
import '../model/driver.dart';
import '../model/fare.dart';
import '../model/ride_detail.dart';

enum RideStatus { matching, driverApproaching, driverArrived, onTrip, completed, cancelled, noDriverAvailable, idle }

class RideState {
  final RideStatus status;
  final String? rideId;
  final DriverInfo? driver;
  final DriverLocation? driverLocation;
  final String? cancelledBy;
  final int? etaSeconds;

  /// The straight-line distance the last live ETA was computed over, when
  /// `/geo/eta` supplied one. Null means "unknown" — never rendered as `0`.
  final double? etaDistanceM;

  /// The driver id from a `GET /rides/current` payload, which carries
  /// `driver_id` without a nested `driver` object. Lets the location poll attach
  /// after a cold start even when the accept `ride.updated` was missed.
  final String? driverId;

  /// `driver.location` proximity flag forwarded by the API (`near_pickup`,
  /// `distance_to_pickup_m`). Advisory only; the server owns the geofence.
  final bool nearPickup;
  final double? nearPickupDistanceM;

  final Fare? fare;
  final Map<String, dynamic>? rideData;

  RideState({
    this.status = RideStatus.idle,
    this.rideId,
    this.driver,
    this.driverLocation,
    this.cancelledBy,
    this.etaSeconds,
    this.etaDistanceM,
    this.driverId,
    this.nearPickup = false,
    this.nearPickupDistanceM,
    this.fare,
    this.rideData,
  });

  /// The driver id to poll `GET /drivers/{id}/location` with, whichever channel
  /// supplied it: the nested accept payload (`driver.id`) or the REST
  /// `driver_id` from `/rides/current`.
  String? get effectiveDriverId => driver?.id ?? driverId;

  RideState copyWith({
    RideStatus? status,
    String? rideId,
    DriverInfo? driver,
    DriverLocation? driverLocation,
    String? cancelledBy,
    int? etaSeconds,
    double? etaDistanceM,
    String? driverId,
    bool? nearPickup,
    double? nearPickupDistanceM,
    bool resetNearby = false,
    Fare? fare,
    Map<String, dynamic>? rideData,
  }) {
    return RideState(
      status: status ?? this.status,
      rideId: rideId ?? this.rideId,
      driver: driver ?? this.driver,
      driverLocation: driverLocation ?? this.driverLocation,
      cancelledBy: cancelledBy ?? this.cancelledBy,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      etaDistanceM: etaDistanceM ?? this.etaDistanceM,
      driverId: driverId ?? this.driverId,
      nearPickup: resetNearby ? false : (nearPickup ?? this.nearPickup),
      nearPickupDistanceM: resetNearby
          ? null
          : (nearPickupDistanceM ?? this.nearPickupDistanceM),
      fare: fare ?? this.fare,
      rideData: rideData ?? this.rideData,
    );
  }
}

class RideStatusNotifier extends StateNotifier<RideState> {
  final WebSocketService _wsService;
  StreamSubscription? _subscription;

  RideStatusNotifier(this._wsService) : super(RideState()) {
    _listenToEvents();
  }

  void _listenToEvents() {
    _subscription = _wsService.events.listen((event) {
      final type = event['type'] as String?;
      final data = event['data'] as Map<String, dynamic>?;

      switch (type) {
        case 'ride.updated':
          _handleRideUpdated(data);
          break;
        case 'driver.location':
          _handleDriverLocation(data);
          break;
        default:
          break;
      }
    });
  }

  void _handleRideUpdated(Map<String, dynamic>? data) {
    if (data == null) return;
    final backendStatus = data['status'] as String?;
    final status = _statusFromBackend(backendStatus);
    if (backendStatus == null || status == null) return;

    if (backendStatus == 'pending') {
      state = RideState(
        status: status,
        rideId: data['ride_id'] as String?,
        etaSeconds: (data['eta_seconds'] as num?)?.toInt(),
        rideData: data,
      );
      return;
    }

    final driverJson = data['driver'];
    final fareJson = data['fare'];
    final nextDriverId = data['driver_id'] as String? ??
        (driverJson is Map<String, dynamic>
            ? driverJson['id'] as String?
            : null);
    final approaching = status == RideStatus.driverApproaching;

    state = state.copyWith(
      status: status,
      rideId: data['ride_id'] as String?,
      driver: driverJson is Map<String, dynamic>
          ? DriverInfo.fromJson(driverJson)
          : state.driver,
      driverId: nextDriverId,
      cancelledBy: data['cancelled_by'] as String?,
      etaSeconds: (data['eta_seconds'] as num?)?.toInt(),
      // A stale "nearby" flag must not survive arrival or trip start; the
      // server's hysteresis handles the within-`accepted` flicker.
      resetNearby: !approaching,
      fare: fareJson is Map<String, dynamic> ? Fare.fromJson(fareJson) : null,
      rideData: data,
    );
  }

  // A `GET /rides/current` payload uses model.Ride json (`id`,`status`,
  // pickup fields) rather than the WS event shape (`ride_id`). Normalize and
  // feed it through the same WS handler so both sources converge.
  void updateFromCurrentRide(Map<String, dynamic>? ride) {
    if (ride == null) return;
    final normalized = Map<String, dynamic>.from(ride);
    normalized['ride_id'] = ride['id'];
    _handleRideUpdated(normalized);
  }

  void _handleDriverLocation(Map<String, dynamic>? data) {
    if (data == null) return;
    final location = DriverLocation.fromJson(data);
    // The API omits both fields when there is no `accepted` active ride and
    // omits `near_pickup` while false, so absence clears the notice. A genuine
    // `0.0` is also dropped by Go `omitempty`; null therefore means "unknown".
    final hasNearby =
        location.nearPickup || location.distanceToPickupM != null;
    state = state.copyWith(
      rideId: data['ride_id'] as String? ?? state.rideId,
      driverLocation: location,
      nearPickup: location.nearPickup,
      nearPickupDistanceM: location.distanceToPickupM,
      resetNearby: !hasNearby,
    );
  }

  /// Publishes a driver fix obtained outside the WS stream (the
  /// `GET /drivers/{id}/location` polling fallback, see
  /// `driver_tracking_provider.dart`).
  ///
  /// Deliberately narrow: it touches ONLY [RideState.driverLocation] so the
  /// HTTP path cannot clear the driver identity, status or ride id the WS
  /// stream owns — and the screen keeps rendering a single marker regardless of
  /// which channel fed it.
  void applyDriverLocation(DriverLocation location) {
    state = state.copyWith(driverLocation: location);
  }

  /// Writes a live driver→pickup ETA computed by the rider (`GET /geo/eta`),
  /// preserving status/driver/fare.
  ///
  /// Only ever called with a trustworthy value: the caller refuses to write the
  /// backend `300` placeholder or a non-positive number, and on a failed compute
  /// it simply does not call this, so `copyWith`'s `??` keeps the last known
  /// value (per the `[ontrip]` ETA honesty contract).
  void applyLiveEta(int seconds, {double? distanceM}) {
    state = state.copyWith(etaSeconds: seconds, etaDistanceM: distanceM);
  }

  /// Merges the authoritative `GET /rides/:id` object into the live state.
  ///
  /// Only the fields the REST object actually owns are written — status, ride
  /// id and (once priced) the fare. Everything else the screen renders comes
  /// from the WS stream and must survive this merge, which is why this does not
  /// reuse [updateFromCurrentRide]: that path is the poll's, and it deliberately
  /// drops the driver/location/fare it has no opinion about.
  void applyRideDetail(RideDetail detail) {
    final status = _statusFromBackend(detail.status);
    state = state.copyWith(
      status: status ?? state.status,
      rideId: detail.id,
      fare: detail.hasFare ? detail.fare : state.fare,
    );
  }

  RideStatus? _statusFromBackend(String? status) {
    switch (status) {
      case 'pending':
        return RideStatus.matching;
      case 'accepted':
        return RideStatus.driverApproaching;
      case 'driver_arrived':
        return RideStatus.driverArrived;
      case 'in_progress':
        return RideStatus.onTrip;
      case 'completed':
        return RideStatus.completed;
      case 'cancelled':
        return RideStatus.cancelled;
      case 'no_driver_available':
        return RideStatus.noDriverAvailable;
      default:
        return null;
    }
  }

  void reset() {
    state = RideState();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final rideStatusProvider = StateNotifierProvider<RideStatusNotifier, RideState>((ref) {
  final wsService = ref.read(webSocketServiceProvider);
  return RideStatusNotifier(wsService);
});