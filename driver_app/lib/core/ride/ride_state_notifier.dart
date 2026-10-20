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

  /// Why the outstanding offer closed (`expired`, `declined`, `cancelled`,
  /// `accepted_elsewhere`, `withdrawn`, `accept_failed`). Null until a close
  /// frame (or an explicit local expiry) records one; cleared by the next
  /// `ride.offer`.
  final String? offerClosedReason;

  /// The public sentence the offer sheet renders for [offerClosedReason].
  final String? offerClosedMessage;

  const RideState({
    this.currentRide,
    this.offeredRideId,
    this.offerExpiresAt,
    this.offerClosedReason,
    this.offerClosedMessage,
  });

  RideState copyWith({
    Ride? currentRide,
    bool clearRide = false,
    String? offeredRideId,
    DateTime? offerExpiresAt,
    bool clearOffer = false,
    String? offerClosedReason,
    String? offerClosedMessage,
    bool clearOfferClosed = false,
  }) {
    return RideState(
      currentRide: clearRide ? null : currentRide ?? this.currentRide,
      offeredRideId: clearOffer ? null : offeredRideId ?? this.offeredRideId,
      offerExpiresAt: clearOffer ? null : offerExpiresAt ?? this.offerExpiresAt,
      offerClosedReason: clearOfferClosed
          ? null
          : offerClosedReason ?? this.offerClosedReason,
      offerClosedMessage: clearOfferClosed
          ? null
          : offerClosedMessage ?? this.offerClosedMessage,
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
      case WsEventType.offerClosed:
        _onOfferClosed(event.data);
      case WsEventType.acceptFailed:
        _onAcceptFailed(event.data);
      case WsEventType.location:
        break;
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
    // When the held ride is terminal (completed / cancelled), adopt the
    // update as a fresh ride — a new ride's broadcast must not be dropped.
    // For a non-terminal in-progress ride, ignore a patch for a different
    // ride so a stale previous-ride event cannot swap out the trip.
    if (held != null && held.id.isNotEmpty) {
      if (!held.isTerminal && held.id != update.rideId) return;
    }
    final base = (held != null && held.id == update.rideId)
        ? held
        : (held != null && held.isTerminal)
            ? null
            : held;
    state = state.copyWith(
      currentRide: update.applyTo(base),
      clearOffer: update.status != 'pending',
    );
  }

  /// A `ride.offer_closed` frame carries the reason the offer ended. It only
  /// applies to the outstanding offer (or, when the offer was already cleared,
  /// to a held ride with the same id — the following `ride.updated` owns the
  /// ride). It never touches [RideState.currentRide].
  void _onOfferClosed(Map<String, dynamic> data) {
    final rideId = data['ride_id'] as String?;
    if (rideId == null || rideId.isEmpty) return;
    final offered = state.offeredRideId;
    if (offered != null && rideId != offered) return;
    if (offered == null && state.currentRide?.id != rideId) return;
    final reason = data['reason'] as String?;
    expireOffer(reason: reason, message: _offerClosedMessage(reason));
  }

  /// A `ride.accept_failed` frame means the accept never committed. Clear the
  /// offer and, if the old optimistic placeholder is still held, null it so
  /// Home's `_tripPushed` latch can reset. A server-confirmed accepted ride
  /// (with coordinates) is never touched.
  void _onAcceptFailed(Map<String, dynamic> data) {
    final rideId = data['ride_id'] as String?;
    if (rideId == null || rideId.isEmpty) return;
    // Never clear a different, currently outstanding offer.
    if (state.offeredRideId == null || state.offeredRideId == rideId) {
      expireOffer(reason: 'accept_failed', message: data['message'] as String?);
    }
    _clearPhantomFor(rideId);
  }

  static String _offerClosedMessage(String? reason) => switch (reason) {
    'expired' => 'Offer expired',
    'cancelled' => 'The rider cancelled this trip.',
    'declined' ||
    'accepted_elsewhere' ||
    'withdrawn' => 'This offer is no longer available.',
    _ => 'This offer is no longer available.',
  };

  /// Clears the legacy optimistic placeholder (`status: accepted` with no
  /// pickup coordinates) for [rideId]. A real accepted ride always carries the
  /// pickup coordinates, so it is left alone. A *different* outstanding offer
  /// is never cleared: the `ride.accept_failed` frame names [rideId], not the
  /// live offer.
  void _clearPhantomFor(String rideId) {
    final held = state.currentRide;
    final isPlaceholder =
        held != null &&
        held.id == rideId &&
        !held.isTerminal &&
        held.status == 'accepted' &&
        held.pickupLat == null &&
        held.pickupLng == null;
    final offered = state.offeredRideId;
    state = state.copyWith(
      clearRide: isPlaceholder,
      clearOffer: offered == null || offered == rideId,
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
      // A stale close reason must never label the new offer.
      clearOfferClosed: true,
    );
    _offerTimer = Timer(offerTimeout, () {
      if (state.offeredRideId != rideId) return;
      state = state.copyWith(clearOffer: true);
    });
  }

  /// Stops the local offer deadline before a server-confirmed accept POST.
  ///
  /// Once an accept is in flight only the server is authoritative for closing
  /// the offer: a local 30 s deadline that fires during a slow round-trip (or
  /// while the committed accept's ride read is retried) would paint
  /// `Offer expired` over that accept. A retryable failure deliberately does
  /// not re-arm the timer — the original deadline may already have passed and
  /// the POST may even have committed before the connection failed, so the
  /// `ride.updated`/`ride.offer_closed` frames (or the next HTTP read) decide.
  void beginAccept() {
    _offerTimer?.cancel();
    _offerTimer = null;
  }

  /// Clears the outstanding offer, recording why (the sheet renders the
  /// message and pins itself to the explicit Dismiss). Never touches the held
  /// ride: `ride.updated`/`adoptRide` own that.
  void expireOffer({String? reason, String? message}) {
    _offerTimer?.cancel();
    state = state.copyWith(
      clearOffer: true,
      offerClosedReason: reason,
      offerClosedMessage: message,
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

  /// Resets the held ride after completion/cancellation acknowledgement.
  /// [clearOffer] also drops an outstanding offer (the post-200
  /// `no_driver_available` path, where the ride is not this driver's trip).
  void clearRide({bool clearOffer = false}) {
    state = state.copyWith(clearRide: true, clearOffer: clearOffer);
  }
}

final rideStateProvider = StateNotifierProvider<RideStateNotifier, RideState>((
  ref,
) {
  return RideStateNotifier(
    ref.read(driverWebSocketServiceProvider),
    apiClient: ref.read(apiClientProvider),
  );
});
