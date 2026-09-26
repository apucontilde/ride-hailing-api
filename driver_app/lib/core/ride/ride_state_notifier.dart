import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../network/websocket_service.dart';
import '../network/ws_event.dart';
import '../auth/auth_provider.dart';
import 'ride_update.dart';

/// The driver's single source of truth for the offer + ride touchpoints:
/// the outstanding offer (id + 30 s deadline) and the currently held ride.
class RideState {
  final Ride? currentRide;
  final String? offeredRideId;
  final DateTime? offerExpiresAt;
  final Map<String, dynamic>? lastLocation;

  const RideState({
    this.currentRide,
    this.offeredRideId,
    this.offerExpiresAt,
    this.lastLocation,
  });

  RideState copyWith({
    Ride? currentRide,
    bool clearRide = false,
    String? offeredRideId,
    DateTime? offerExpiresAt,
    bool clearOffer = false,
    Map<String, dynamic>? lastLocation,
    bool clearLocation = false,
  }) {
    return RideState(
      currentRide: clearRide ? null : currentRide ?? this.currentRide,
      offeredRideId: clearOffer ? null : offeredRideId ?? this.offeredRideId,
      offerExpiresAt: clearOffer ? null : offerExpiresAt ?? this.offerExpiresAt,
      lastLocation: clearLocation ? null : lastLocation ?? this.lastLocation,
    );
  }
}

class RideStateNotifier extends StateNotifier<RideState> {
  RideStateNotifier(
    this.websocket, {
    required this.apiClient,
    this.offerTimeout = const Duration(seconds: 30),
  }) : super(const RideState()) {
    _subscription = websocket.events.listen(onWsEvent);
  }

  final DriverWebSocketService websocket;
  // The API client is kept for future plans (offers, trip, history) that fetch
  // ride data over HTTP; it is intentionally not read yet.
  final ApiClient apiClient;
  final Duration offerTimeout;

  StreamSubscription<WsEvent>? _subscription;
  Timer? _offerTimer;

  @override
  void dispose() {
    _offerTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  void onWsEvent(WsEvent event) {
    switch (event.type) {
      case WsEventType.offer:
        _onOffer(event.data['ride_id'] as String?);
      case WsEventType.updated:
        _onRideUpdated(event.data);
      case WsEventType.location:
        state = state.copyWith(lastLocation: event.data);
      case WsEventType.other:
        break;
    }
  }

  /// `ride.updated` is a *patch* keyed by `ride_id` with nested pickup/dropoff
  /// and fare objects, so it is merged onto the held ride — a plain
  /// `Ride.fromJson` of the event would blank the id and the coordinates the
  /// trip screen and the next status call depend on.
  void _onRideUpdated(Map<String, dynamic> data) {
    final update = RideUpdate.fromJson(data);
    if (update.rideId.isEmpty || update.status.isEmpty) return;
    final held = state.currentRide;
    // Ignore traffic for a ride this driver is not holding, so a late event
    // for a previous ride cannot swap the trip out from under the screen.
    if (held != null && held.id.isNotEmpty && held.id != update.rideId) return;
    state = state.copyWith(
      currentRide: update.applyTo(held),
      clearOffer: update.status != 'pending',
    );
  }

  /// Adopts a ride the app learned about over HTTP — the `advance`/cancel
  /// responses, or the `GET /driver/rides/current` launch restore — so the
  /// websocket store and the HTTP store agree on what the driver holds.
  void adoptRide(Ride ride) {
    if (ride.id.isEmpty) return;
    state = state.copyWith(
      currentRide: ride,
      clearOffer: ride.status != 'pending',
    );
  }

  void _onOffer(String? rideId) {
    if (rideId == null || rideId.isEmpty) return;
    // Single-offer policy: ignore a second offer while one is open.
    if (state.offeredRideId != null) return;
    _offerTimer?.cancel();
    state = state.copyWith(
      offeredRideId: rideId,
      offerExpiresAt: DateTime.now().add(offerTimeout),
    );
    _offerTimer = Timer(offerTimeout, () {
      if (state.offeredRideId != rideId) return;
      state = state.copyWith(clearOffer: true);
    });
  }

  /// Accepts the outstanding offer over the websocket (primary path) and flips
  /// the UI immediately to an accepted placeholder; the server's `ride.updated`
  /// broadcast replaces it with real ride data.
  Future<void> acceptOffer() async {
    final rideId = state.offeredRideId;
    if (rideId == null) return;
    websocket.acceptOffer(rideId);
    _claimOffer(rideId);
  }

  /// Claims the outstanding offer after a successful HTTP accept (the
  /// websocket may be dead). No WS message is sent.
  void claimOfferViaHttp() {
    final rideId = state.offeredRideId;
    if (rideId == null) return;
    _claimOffer(rideId);
  }

  void _claimOffer(String rideId) {
    _offerTimer?.cancel();
    state = state.copyWith(
      currentRide: Ride(id: rideId, riderId: '', status: 'accepted'),
      clearOffer: true,
    );
  }

  /// Declines the outstanding offer via the websocket and clears it locally.
  void declineOffer() {
    final rideId = state.offeredRideId;
    if (rideId == null) return;
    websocket.declineOffer(rideId);
    _offerTimer?.cancel();
    state = state.copyWith(clearOffer: true);
  }

  /// Resets the held ride + location after completion/cancellation
  /// acknowledgement.
  void clearRide() {
    state = state.copyWith(clearRide: true, clearLocation: true);
  }
}

final rideStateProvider =
    StateNotifierProvider<RideStateNotifier, RideState>((ref) {
  return RideStateNotifier(
    ref.read(driverWebSocketServiceProvider),
    apiClient: ref.read(apiClientProvider),
  );
});
