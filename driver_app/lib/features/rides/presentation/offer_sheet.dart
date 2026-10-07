import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/rides_repository.dart';
import '../../../core/network/websocket_service.dart';
import '../../../core/ride/ride_state_notifier.dart';

/// Offer dialog driven by [rideStateProvider.offeredRideId].
/// Fetches ride detail, shows a countdown matching the server's 30 s window,
/// and accepts over the WS (HTTP fallback when the socket is dead) or declines
/// over the WS only.
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
  late int _secondsLeft;
  Timer? _countdownTimer;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = "Couldn't load ride details";
      });
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

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_taxi, size: 48, color: Colors.green),
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            )
          else if (_ride != null) ...[
            _row('Pickup', _ride!.pickupAddress ?? '...'),
            _row('Dropoff', _ride!.dropoffAddress ?? '...'),
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
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: _expired ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_expired) ...[
            Text(
              'Offer expired',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _expired ? null : _accept,
                  child: const Text('Accept'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _expired ? null : _decline,
                  child: const Text('Decline'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Leaving the sheet lets the server expiry handle it.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
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