import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/ride_provider.dart';

/// The post-completion 1–5★ prompt (LC-3).
///
/// Pops with the submitted score, or `null` when the rider skipped / the ride
/// was already rated elsewhere.
///
/// The stars are the double-submit guard. The backend's `POST /rides/:id/rate`
/// has **no** completed/party check and `UNIQUE(ride_id, rater_role)` turns a
/// second score into a conflict, so a tap that lands twice must never leave the
/// screen: `RideDetailState.isRating` disables all five targets for the whole
/// round trip, and the notifier drops a second call even if the UI is bypassed.
class RatingPromptDialog extends ConsumerStatefulWidget {
  const RatingPromptDialog({super.key, required this.rideId});

  final String rideId;

  @override
  ConsumerState<RatingPromptDialog> createState() => _RatingPromptDialogState();
}

class _RatingPromptDialogState extends ConsumerState<RatingPromptDialog> {
  int _score = 0;

  Future<void> _submit(int score) async {
    setState(() => _score = score);
    // The outcome is returned for THIS ride; reading the shared
    // `RideDetailState.rating` here would leak a previous ride's outcome into
    // this one.
    final notifier = ref.read(rideDetailProvider.notifier);
    final outcome = await notifier.rateRide(widget.rideId, score);
    if (!mounted) return;
    if (outcome == RatingOutcome.failed) return; // hold the dialog for a retry
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rideDetailProvider);
    final busy = state.isRating;

    return AlertDialog(
      title: const Text('Rate your ride'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (index) {
              final value = index + 1;
              return IconButton(
                key: ValueKey<String>('rating-star-$value'),
                // Disabled for the whole in-flight window: no second submit.
                onPressed: busy ? null : () => _submit(value),
                icon: Icon(
                  value <= _score ? Icons.star : Icons.star_border,
                  size: 36,
                  color: value <= _score ? Colors.amber : Colors.grey,
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Text(
            busy ? 'Sending your rating...' : 'Tap a star to rate your driver',
            style: TextStyle(color: Colors.grey[600], fontSize: 13),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 8),
            Text(
              state.error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(null),
          child: const Text('Skip'),
        ),
      ],
    );
  }
}
