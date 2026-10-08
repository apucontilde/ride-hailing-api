import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/place.dart';

/// The pickup the rider used for the last booked trip plus the pending return
/// intent, so a pickup survives `HomeScreen`'s disposal on every flow route.
class PickupMemory {
  /// The manual [Place] the last booking used, or `null` when it started from
  /// the device fix. The whole [Place] is kept (not coordinates) so the rider's
  /// chosen label survives the return.
  final Place? manualPickup;

  /// The pending return intent: `null` = no pending trip return, `true` =
  /// restore [manualPickup] (or re-acquire the device fix when it is `null`),
  /// `false` = reload the device fix only (a completed trip starts a fresh
  /// booking).
  final bool? restoreOnHome;

  const PickupMemory({this.manualPickup, this.restoreOnHome});
}

class PickupMemoryNotifier extends StateNotifier<PickupMemory> {
  PickupMemoryNotifier() : super(const PickupMemory());

  /// Records the pickup the booking actually used. `null` means the trip
  /// started from the device fix.
  void remember(Place? manualPickup) {
    state = PickupMemory(
      manualPickup: manualPickup,
      restoreOnHome: state.restoreOnHome,
    );
  }

  /// Marks the pending return intent without touching the remembered pickup.
  void markReturning({required bool restorePickup}) {
    state = PickupMemory(
      manualPickup: state.manualPickup,
      restoreOnHome: restorePickup,
    );
  }

  /// Returns the pending intent and clears it. The manual pickup is retained so
  /// a restore can still read it; callers on the reload path must [clear].
  PickupMemory consumeReturn() {
    final consumed = state;
    state = PickupMemory(manualPickup: consumed.manualPickup);
    return consumed;
  }

  /// Empties the memory (completion, logout).
  void clear() {
    state = const PickupMemory();
  }
}

/// Global (not `autoDispose`) on purpose: it must outlive `HomeScreen`, which
/// is disposed whenever a flow route (`/driver-matching`, `/active-ride`) is
/// pushed outside the shell.
final pickupMemoryProvider =
    StateNotifierProvider<PickupMemoryNotifier, PickupMemory>(
  (ref) => PickupMemoryNotifier(),
);
