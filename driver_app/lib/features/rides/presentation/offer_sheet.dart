import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/rides_repository.dart';
import '../../../core/network/websocket_service.dart';
import '../../../core/ride/ride_state_notifier.dart';

/// Offer dialog driven by [rideStateProvider.offeredRideId].
/// Fetches ride detail, shows a countdown matching the server's 30 s window,
/// and accepts over the WS (HTTP fallback when the socket is dead) or passes
/// over the WS only.
///
/// Dismissal is explicit-only (`driver_app_plans/[offer]_no_accidental_dismiss.md`):
/// the scrim, a drag-down and the system back gesture are all blocked, so the
/// only exits are Accept, Pass, or the explicit Dismiss once the countdown has
/// expired.
class OfferSheet extends ConsumerStatefulWidget {
  const OfferSheet({super.key});

  @override
  ConsumerState<OfferSheet> createState() => _OfferSheetState();
}

class _OfferSheetState extends ConsumerState<OfferSheet> {
  static const Duration _initialWindow = Duration(seconds: 30);
  static const Duration _loadTimeout = Duration(seconds: 5);

  Ride? _ride;
  bool _loading = true;
  String? _loadError;
  RouteEstimate? _estimate;
  late int _secondsLeft;
  Timer? _countdownTimer;
  bool _expired = false;

  /// The offer id this sheet was opened for. When the held offer changes to a
  /// different id (or is withdrawn before expiry) the sheet closes itself, so a
  /// stale sheet cannot stack under a later offer.
  String? _presentedRideId;

  @override
  void initState() {
    super.initState();
    _presentedRideId = ref.read(rideStateProvider).offeredRideId;
    final expiresAt = ref.read(rideStateProvider).offerExpiresAt;
    final remaining = expiresAt == null
        ? _initialWindow.inSeconds
        : expiresAt.difference(DateTime.now()).inSeconds;
    _secondsLeft = remaining > _initialWindow.inSeconds
        ? _initialWindow.inSeconds
        : (remaining < 0 ? 0 : remaining);
    _loadRide();
    _startCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadRide() async {
    final rideId = ref.read(rideStateProvider).offeredRideId;
    if (rideId == null) return;
    try {
      final ride = await ref
          .read(ridesRepositoryProvider)
          .fetchRide(rideId)
          .timeout(_loadTimeout);
      if (!mounted) return;
      setState(() {
        _ride = ride;
        _loading = false;
      });
      await _loadEstimate(ride);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = "Couldn't load ride details";
      });
    }
  }

  /// Requests the trip estimate (pickup → dropoff) so the driver can judge the
  /// offer. Honest by construction: a failure leaves [_estimate] null and the
  /// rows show the `—` placeholder, never a fabricated number. An `is_estimate`
  /// route is labelled as such.
  Future<void> _loadEstimate(Ride ride) async {
    final fromLat = ride.pickupLat;
    final fromLng = ride.pickupLng;
    final toLat = ride.dropoffLat;
    final toLng = ride.dropoffLng;
    if (fromLat == null || fromLng == null || toLat == null || toLng == null) {
      return;
    }
    try {
      final estimate = await ref.read(ridesRepositoryProvider).routeEstimate(
            fromLat: fromLat,
            fromLng: fromLng,
            toLat: toLat,
            toLng: toLng,
          );
      if (!mounted) return;
      setState(() => _estimate = estimate);
    } catch (_) {
      // The placeholder stands in; nothing is invented.
    }
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsLeft--;
        if (_secondsLeft <= 0) {
          _expired = true;
          _secondsLeft = 0;
          timer.cancel();
        }
      });
    });
  }

  Future<void> _accept() async {
    final rideId = ref.read(rideStateProvider).offeredRideId;
    if (rideId == null || _expired) return;
    final rideState = ref.read(rideStateProvider.notifier);
    final websocket = ref.read(driverWebSocketServiceProvider);

    // Primary path: live WebSocket accept. `rideState.acceptOffer` sends the
    // nested `ride.accept` and flips the UI; the server's `ride.updated`
    // replaces the placeholder.
    if (websocket.isConnected) {
      rideState.acceptOffer();
      _closeAsAccepted();
      return;
    }

    // Fallback path: the socket is dead, so the WS accept would silently do
    // nothing. Push the HTTP accept and only claim the offer on success.
    try {
      await ref.read(ridesRepositoryProvider).acceptRideHttp(rideId);
      rideState.claimOfferViaHttp();
      _closeAsAccepted();
    } on OfferExpiredException {
      _showMessage('Trip no longer available');
    } on Exception {
      _showMessage('Could not accept. Please try again.');
    }
  }

  void _decline() {
    final rideId = ref.read(rideStateProvider).offeredRideId;
    if (rideId == null || _expired) return;
    ref.read(rideStateProvider.notifier).declineOffer();
    if (mounted) Navigator.of(context).pop();
  }

  /// Pins the sheet into its expired state (single explicit Dismiss). Used both
  /// by the local countdown and by the held offer being cleared, so the sheet
  /// never silently disappears at the 30 s boundary.
  void _expireNow() {
    if (_expired) return;
    _countdownTimer?.cancel();
    setState(() {
      _expired = true;
      _secondsLeft = 0;
    });
  }

  void _closeAsAccepted() {
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Trip accepted')),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _distanceLabel() {
    final estimate = _estimate;
    if (estimate == null) return '—';
    final km = (estimate.distanceM / 1000).toStringAsFixed(1);
    return estimate.isEstimate ? 'Estimated $km km' : '$km km';
  }

  String _durationLabel() {
    final estimate = _estimate;
    if (estimate == null) return '—';
    final minutes = (estimate.durationS / 60).ceil();
    final base = 'about $minutes min';
    return estimate.isEstimate ? 'Estimated $base' : base;
  }

  @override
  Widget build(BuildContext context) {
    // An offer ending is not an accidental dismissal. A different live offer
    // replaces this sheet, so close it to stop the two from stacking. The
    // presented offer clearing (the server's own 30 s window, an acceptance
    // elsewhere, or a withdrawal) pins this sheet into its explicit expired
    // state rather than silently vanishing — the Dismiss button is the exit.
    ref.listen<String?>(
      rideStateProvider.select((state) => state.offeredRideId),
      (previous, next) {
        if (!mounted) return;
        if (next == _presentedRideId) return;
        if (next != null) {
          // A route pop, not `maybePop`: under `PopScope(canPop: false)` the
          // route reports `doNotPop`, so `maybePop` returns `true` without
          // popping and the stale sheet would stay stacked under the next one.
          Navigator.of(context).pop();
        } else {
          _expireNow();
        }
      },
    );

    return PopScope(
      // Back/scrim/drag must never discard a live offer; the explicit actions
      // are the only exits. Programmatic `Navigator.pop` from Accept/Pass/
      // Dismiss is unaffected (PopScope only guards the system pop).
      canPop: false,
      child: AppBottomSheet(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.local_taxi, size: 48, color: AppColors.success),
            const SizedBox(height: 16),
            Text(
              'New Ride Offer',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(),
              )
            else if (_loadError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _loadError!,
                  style: AppTextStyles.body.copyWith(color: AppColors.danger),
                ),
              )
            else if (_ride != null) ...[
              _row('Pickup', _ride!.pickupAddress ?? '...'),
              _row('Dropoff', _ride!.dropoffAddress ?? '...'),
              _row('Distance', _distanceLabel()),
              _row('Est. time', _durationLabel()),
              _row(
                'Fare',
                _ride!.totalFare == null
                    ? '-'
                    : formatMoney(
                        _ride!.totalFare!,
                        currency: _ride!.fareCurrency,
                      ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.timer, size: 18),
                const SizedBox(width: 6),
                Text(
                  '${_secondsLeft}s',
                  style: AppTextStyles.title.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: _expired ? AppColors.danger : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_expired) ...[
              Text(
                'Offer expired',
                style: AppTextStyles.body.copyWith(
                  color: AppColors.danger,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              AppButton(
                key: const Key('offer-dismiss-button'),
                label: 'Dismiss',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ] else
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Accept',
                      onPressed: _accept,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppButton(
                      label: 'Pass',
                      variant: AppButtonVariant.secondary,
                      onPressed: _decline,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.bold)),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
