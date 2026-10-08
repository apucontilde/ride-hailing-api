import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/ride_provider.dart';

/// Opens the post-completion 1–5★ prompt (LC-3) as the shared bottom sheet.
///
/// Resolves with the submitted [RatingOutcome], or `null` when the rider
/// skipped. A [RatingOutcome.failed] outcome is **not** popped: the sheet stays
/// open so the rider can retry, with the notifier's `RideDetailState.error`
/// rendered inline. The stars/submit are disabled for the whole in-flight
/// window by `RideDetailState.isRating`, and the notifier drops a second submit
/// even if the UI is bypassed.
Future<RatingOutcome?> showRatingPrompt(
  BuildContext context, {
  required String rideId,
}) {
  return showAppRatingSheet<RatingOutcome>(
    context,
    builder: (_) => _RatingPromptSheet(rideId: rideId),
  );
}

class _RatingPromptSheet extends ConsumerWidget {
  const _RatingPromptSheet({required this.rideId});

  final String rideId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(rideDetailProvider);

    return AppRatingSheet(
      title: 'Rate your ride',
      subtitle: 'Tap a star to rate your driver',
      // Locked 2026-10-08: driver parity — the rider gains the optional comment.
      allowComment: true,
      skipLabel: 'Skip',
      busy: state.isRating,
      errorText: state.error,
      onSubmit: (score, comment) async {
        // The outcome is returned for THIS ride; reading the shared
        // `RideDetailState.rating` here would leak a previous ride's outcome
        // into this one.
        final outcome = await ref
            .read(rideDetailProvider.notifier)
            .rateRide(rideId, score, comment: comment);
        if (!context.mounted) return;
        if (outcome == RatingOutcome.failed) {
          return; // hold the sheet for a retry
        }
        Navigator.of(context).pop(outcome);
      },
      onSkip: () => Navigator.of(context).pop(null),
    );
  }
}
