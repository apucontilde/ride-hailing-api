import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../data/rated_rides_provider.dart';
import '../data/rides_repository.dart';

/// Opens the rating sheet for a completed ride (US-D10).
Future<void> showRateSheet(
  BuildContext context,
  WidgetRef ref, {
  required String rideId,
}) {
  return showAppRatingSheet<void>(
    context,
    builder: (_) => RateSheet(rideId: rideId),
  );
}

/// 1–5 star rating with an optional comment, submitted to
/// `POST /driver/rides/:id/rate`, on top of the shared [AppRatingSheet].
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
  bool _submitting = false;
  String? _error;

  Future<void> _submit(int score, String comment) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      // The repository range-checks 1..5 locally, so a rejected score throws
      // `ArgumentError` before any request is sent.
      await ref
          .read(ridesRepositoryProvider)
          .rateRide(rideId: widget.rideId, score: score, comment: comment);
      if (!mounted) return;
      // The server has the rating now; retire the prompt immediately rather
      // than waiting for the rated-rides list to catch up with it.
      ref.read(ratedRidesProvider.notifier).markRated(widget.rideId);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Thanks — rating sent')));
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
    return AppRatingSheet(
      title: 'Rate your rider',
      subtitle: 'How was the trip?',
      allowComment: true,
      busy: _submitting,
      errorText: _error,
      onSubmit: _submit,
      onSkip: () => Navigator.of(context).pop(),
    );
  }
}
