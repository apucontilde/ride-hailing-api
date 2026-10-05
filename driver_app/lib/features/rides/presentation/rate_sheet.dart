import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/rated_rides_provider.dart';
import '../data/rides_repository.dart';

/// Opens the rating sheet for a completed ride (US-D10).
Future<void> showRateSheet(BuildContext context, WidgetRef ref,
    {required String rideId}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => RateSheet(rideId: rideId),
  );
}

/// 1–5 star rating with an optional comment, submitted to
/// `POST /driver/rides/:id/rate`.
///
/// A submit in flight disables the control, and a failure keeps the sheet open
/// with an inline error — a dropped rating is silent data loss, since the
/// server gives the driver no way to see that it did not land.
class RateSheet extends ConsumerStatefulWidget {
  final String rideId;

  const RateSheet({super.key, required this.rideId});

  @override
  ConsumerState<RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends ConsumerState<RateSheet> {
  int _score = 0;
  final TextEditingController _comment = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  /// The server range-checks 1..5 and the repository re-checks it locally, so
  /// an unsubmitted sheet is simply not submittable.
  bool get _canSubmit => _score >= 1 && _score <= 5 && !_submitting;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(ridesRepositoryProvider).rateRide(
            rideId: widget.rideId,
            score: _score,
            comment: _comment.text,
          );
      if (!mounted) return;
      // The server has the rating now; retire the prompt immediately rather
      // than waiting for the rated-rides list to catch up with it.
      ref.read(ratedRidesProvider.notifier).markRated(widget.rideId);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks — rating sent')),
      );
    } on ArgumentError {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Pick between 1 and 5 stars.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not send your rating. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Lift the sheet above the keyboard when the comment field is focused.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Rate your rider',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'How was the trip?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var star = 1; star <= 5; star++)
                  IconButton(
                    key: Key('rate-star-$star'),
                    onPressed: _submitting
                        ? null
                        : () => setState(() => _score = star),
                    icon: Icon(
                      star <= _score ? Icons.star : Icons.star_border,
                      size: 36,
                      color: Colors.amber,
                    ),
                    tooltip: '$star star${star == 1 ? '' : 's'}',
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('rate-comment'),
              controller: _comment,
              enabled: !_submitting,
              maxLength: 280,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Comment (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                key: const Key('rate-error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('rate-submit'),
              onPressed: _canSubmit ? _submit : null,
              child: _submitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Submit rating'),
            ),
            TextButton(
              key: const Key('rate-skip'),
              onPressed: _submitting ? null : () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}
