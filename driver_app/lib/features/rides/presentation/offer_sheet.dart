import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/rides_repository.dart';
import '../../../core/ride/ride_state_notifier.dart';

/// Offer dialog driven by [rideStateProvider.offeredRideId].
/// Fetches ride detail, shows a countdown matching the server's 30 s window,
/// accepts over the synchronous HTTP endpoint (server-confirmed) and passes
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
  String? _closedMessage;

  /// Blocks a double tap while the accept POST is in flight.
  bool _accepting = false;

  /// The accept POST answered 200: the assignment committed. A committed
  /// accept is never POSTed again; only the post-accept read is retried.
  bool _acceptConfirmed = false;

  /// The post-accept read keeps failing, so the sheet offers Retry loading
  /// instead of Accept/Pass. The ride is already assigned.
  bool _acceptConfirmedButUnloaded = false;

  /// This sheet owns the pop: set immediately before `adoptRide`/`clearRide`
  /// on the post-200 paths, so the offered-id listener stands down and cannot
  /// repaint the sheet as expired during the exit animation.
  bool _postAcceptClose = false;

  int _loadFailures = 0;
  bool _triedCurrentFallback = false;

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
      final estimate = await ref
          .read(ridesRepositoryProvider)
          .routeEstimate(
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
      if (!mounted || _acceptConfirmed || _postAcceptClose) {
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

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    }

  /// Server-confirmed accept: the HTTP `200` is the only accept claim. A `200`
  /// is followed by a real `GET /driver/rides/:id` read and only that ride is
  /// adopted — never an optimistic placeholder.
  Future<void> _accept() async {
    final rideId = ref.read(rideStateProvider).offeredRideId;
    // A committed accept is never POSTed twice; only the read is retried.
    if (rideId == null || _expired || _accepting || _acceptConfirmed) return;
    setState(() => _accepting = true);
    // Freeze the countdown before the round-trip: a 30 s boundary landing
    // inside the accept/pop must not paint `Offer expired` over a committed
    // accept.
    _cancelCountdown();
    try {
      await ref.read(ridesRepositoryProvider).acceptRideHttp(rideId);
      _acceptConfirmed = true; // the POST is done, no re-POST
      _cancelCountdown();
      await _loadAcceptedRide(rideId);
    } on OfferExpiredException catch (e) {
      // Pin the user-facing copy before clearing the offer: the offered-id
      // listener runs synchronously and would otherwise paint the raw API
      // sentence first (and `_expireNow` is idempotent).
      _expireNow(message: 'Trip no longer available');
      ref
          .read(rideStateProvider.notifier)
          .expireOffer(reason: 'expired', message: e.message);
    } on Exception {
      _showMessage('Could not accept. Please try again.');
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  /// Loads the real ride after a committed accept and closes the sheet
  /// according to the fetched status. Never re-POSTs the accept.
  Future<void> _loadAcceptedRide(String rideId) async {
    try {
      final ride = await ref.read(ridesRepositoryProvider).fetchRide(rideId);
      if (!mounted) return;
      _handleAcceptedRide(ride);
    } catch (_) {
      _loadFailures++;
      // One-shot fallback to `/driver/rides/current` only after the by-id read
      // has failed twice; the by-id shape is preferred because it can return a
      // terminal ride, which `/current` deliberately does not.
      if (!_triedCurrentFallback && _loadFailures >= 2) {
        _triedCurrentFallback = true;
        try {
          final ride = await ref.read(ridesRepositoryProvider).currentRide();
          if (ride != null && ride.id == rideId && mounted) {
            _handleAcceptedRide(ride);
            return;
          }
        } catch (_) {
          // Fall through to the Retry state.
        }
      }
      // The accept DID commit (200). Do not re-POST accept; offer a read retry.
      if (mounted) setState(() => _acceptConfirmedButUnloaded = true);
    }
  }

  void _handleAcceptedRide(Ride ride) {
    if (!mounted) return;
    switch (ride.status) {
      case 'accepted':
      case 'driver_arrived':
        _cancelCountdown();
        _postAcceptClose = true; // this closure owns the pop
        ref.read(rideStateProvider.notifier).adoptRide(ride);
        _closeAsAccepted(); // the only path that may say "Trip accepted"
      case 'cancelled':
      case 'completed':
        // The accept committed, but the ride ended before this read returned.
        // Adopt the real terminal ride so the held state is truthful; never
        // claim a live trip and never re-POST accept.
        _cancelCountdown();
        _postAcceptClose = true;
        ref.read(rideStateProvider.notifier).adoptRide(ride);
        _closeAsEnded('This trip has already ended.');
      case 'no_driver_available':
        // Not an assigned trip for this driver: reset, stay on Home, never
        // adopt it as a live ride (it is not a TripStage).
        _cancelCountdown();
        _postAcceptClose = true;
        ref.read(rideStateProvider.notifier).clearRide(clearOffer: true);
        _closeAsEnded('No active trip.');
      default:
        // Any other status (e.g. `pending` from a read that raced the commit)
        // proves nothing: keep the sheet usable and retry the read, no claim.
        setState(() => _acceptConfirmedButUnloaded = true);
    }
  }

  Future<void> _retryLoad() async {
    final rideId = _presentedRideId;
    if (rideId == null || _accepting) return;
    setState(() => _accepting = true);
    await _loadAcceptedRide(rideId);
    if (mounted) setState(() => _accepting = false);
  }

  void _decline() {
    final rideId = ref.read(rideStateProvider).offeredRideId;
    if (rideId == null || _expired) return;
    ref.read(rideStateProvider.notifier).declineOffer();
    if (mounted) Navigator.of(context).pop();
  }

  /// Pins the sheet into its expired state (single explicit Dismiss). Used by
  /// the local countdown, the held offer being cleared, and the 404/409 accept
  /// outcomes, so the sheet never silently disappears.
  void _expireNow({String? message}) {
    if (_expired || _acceptConfirmed || _postAcceptClose) return;
    _cancelCountdown();
    setState(() {
      _expired = true;
      _secondsLeft = 0;
      _closedMessage = message ?? _closedMessage;
    });
  }

  void _closeAsAccepted() {
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Trip accepted')));
  }

  /// Closes the sheet after a committed accept that turned out to be terminal
  /// (or not this driver's). No "Trip accepted" claim.
  void _closeAsEnded(String message) {
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
        // A committed accept (and its post-200 close path) owns the pop: a
        // self-initiated clear or a late `offer_closed {reason:"expired"}`
        // must not repaint `Offer expired` during the read/Retry window or the
        // exit animation.
        if (_acceptConfirmed || _postAcceptClose) return;
        if (next == _presentedRideId) return;
        if (next != null) {
          // A route pop, not `maybePop`: under `PopScope(canPop: false)` the
          // route reports `doNotPop`, so `maybePop` returns `true` without
          // popping and the stale sheet would stay stacked under the next one.
          Navigator.of(context).pop();
        } else {
          final state = ref.read(rideStateProvider);
          _expireNow(message: state.offerClosedMessage);
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
                _closedMessage ?? 'Offer expired',
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
            ] else if (_acceptConfirmedButUnloaded)
              AppButton(
                key: const Key('offer-retry-button'),
                label: 'Retry loading',
                onPressed: _accepting ? null : _retryLoad,
              )
            else
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Accept',
                      onPressed: _accepting ? null : _accept,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppButton(
                      label: 'Pass',
                      variant: AppButtonVariant.secondary,
                      onPressed: _accepting ? null : _decline,
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
        Text(
          label,
          style: AppTextStyles.body.copyWith(fontWeight: FontWeight.bold),
        ),
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
