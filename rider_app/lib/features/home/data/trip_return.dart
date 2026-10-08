import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'current_ride_provider.dart';
import 'home_provider.dart';
import 'pickup_memory_provider.dart';
import 'ride_status_provider.dart';

/// Resets the session-scoped ride state a finished trip leaves behind, so a
/// sticky `cancelled`/`completed` cannot leak into the next booking.
void resetRideState(WidgetRef ref) {
  ref.read(rideStatusProvider.notifier).reset();
  ref.read(rideCreationProvider.notifier).reset();
  ref.read(currentRideProvider.notifier).stopPolling();
}

/// Centralized "leave the flow and go Home" for every terminal ride exit: it
/// marks the pickup-return intent, resets the trip state and navigates, so the
/// matching/active screens cannot drift on `restore` and cleanup.
void markTripReturn(WidgetRef ref, {required bool restorePickup}) {
  ref
      .read(pickupMemoryProvider.notifier)
      .markReturning(restorePickup: restorePickup);
  resetRideState(ref);
}
