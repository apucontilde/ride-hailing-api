import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/auth_provider.dart';
import 'ride/ride_state_notifier.dart';
import '../features/rides/data/rides_repository.dart';

/// The one-time session bootstrap: authenticate, then restore an in-progress
/// ride before the router reads the session.
///
/// This closes the web-reload defect
/// (`driver_app_plans/[auth]_web_reload_session_bootstrap.md`): go_router boots
/// at the reloaded route (a hash URL carries `/#/trip`), so `SplashScreen` —
/// the historical only caller of `checkAuth()` — never mounts. Running the
/// probe here, once, on every entry path (cold start, reload, login) and gating
/// the redirect on [complete] means an authenticated session is known before
/// any route decision.
///
/// It also owns the active-trip restore
/// (`driver_app_plans/01_[trip]_post_auth_live_trip_restore.md`): after auth
/// resolves for a driver it calls `GET /driver/rides/current` once and adopts
/// any live ride, so a reload on any route can be routed onto `/trip`. The same
/// restore re-runs on a later unauthenticated→authenticated transition (the
/// launch-logged-out-then-login path) via the auth listener wired in
/// [sessionBootstrapProvider], so "after login" restores too.
///
/// [run] is idempotent: it performs exactly one `checkAuth()` (one `/me`/refresh
/// probe) and one current-ride fetch per app launch even if the root widget
/// rebuilds.
class SessionBootstrap extends ChangeNotifier {
  SessionBootstrap(this._ref);

  final Ref _ref;
  bool _started = false;
  bool _disposed = false;
  bool _complete = false;
  bool _restoreAttempted = false;
  bool _tripRestorePending = false;
  String? _restoredRideId;

  /// Whether `checkAuth()` (and, when authenticated, the ride restore) has
  /// settled. The router redirect blocks on this.
  bool get complete => _complete;

  /// Whether the bootstrap took ownership of the active-trip restore. The
  /// Home-mount fallback consults this so the server is not polled twice.
  bool get restoreAttempted => _restoreAttempted;

  /// The id of the ride adopted during the bootstrap, or `null` when there was
  /// no active trip.
  String? get restoredRideId => _restoredRideId;

  /// One-shot acknowledgement of the restored-trip auto-route. Returns `true`
  /// exactly once (the first call after a live trip was restored) and consumes
  /// the pending flag. Deliberately does **not** notify listeners: it is called
  /// from the router `redirect`, and notifying would re-enter the redirect.
  bool consumeTripRestore() {
    if (!_tripRestorePending) return false;
    _tripRestorePending = false;
    return true;
  }

  Future<void> run() async {
    if (_started || _disposed) return;
    _started = true;
    await _ref.read(authProvider.notifier).checkAuth();
    if (_disposed) return;

    // The auth listener may already have started the restore while
    // `checkAuth()` resolved (it fires on the unauthenticated→authenticated
    // edge); this is then a latch no-op. It still matters when no state edge
    // is observed, e.g. a container that is already authenticated.
    await _restoreActiveTripIfNeeded();

    if (_disposed) return;
    _complete = true;
    notifyListeners();
  }

  /// The auth-transition seam. A driver who logs in — or is promoted by
  /// onboarding — **after** the bootstrap already ran still gets their live ride
  /// restored and routed onto `/trip`. Signing out rearms the one-shot latch so
  /// the next session can restore too.
  void onAuthChanged(AuthState? previous, AuthState next) {
    if (_disposed) return;
    if (!next.isAuthenticated) {
      // New (or cleared) session: rearm so the next login can restore.
      _restoreAttempted = false;
      _restoredRideId = null;
      _tripRestorePending = false;
      return;
    }
    if (next.isDriver) {
      unawaited(_restoreActiveTripIfNeeded());
    }
  }

  /// Fetches and adopts the server's active ride for the current driver, at
  /// most once per authenticated session. Non-fatal: any failure means "no
  /// active trip". On success, arms the one-shot `/trip` route that the router
  /// `redirect` consumes exactly once.
  Future<void> _restoreActiveTripIfNeeded() async {
    if (_disposed) return;
    // No latch for a rider/unauthenticated account: a rider is on its way to
    // onboarding and must not probe the driver endpoint, and leaving the latch
    // false lets the post-promotion transition restore.
    if (!_ref.read(authProvider).isDriver) return;
    if (_restoreAttempted) return;
    _restoreAttempted = true;

    try {
      final ride = await _ref.read(ridesRepositoryProvider).currentRide();
      if (_disposed || ride == null) return;
      _ref.read(rideStateProvider.notifier).adoptRide(ride);
      _restoredRideId = ride.id;
      _tripRestorePending = true;
      // Wake the router so the one-shot `/trip` push runs on this (login)
      // navigation, not only on the next unrelated route change.
      notifyListeners();
    } catch (_) {
      // Non-fatal: an offline or rejected restore just means no active trip.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final sessionBootstrapProvider = Provider<SessionBootstrap>((ref) {
  final bootstrap = SessionBootstrap(ref);
  // Observe every auth transition. The bootstrap may complete before a login
  // happens (a launch logged-out), so `run()` cannot be the only restore
  // trigger — the plan's goal explicitly includes "after login".
  ref.listen<AuthState>(authProvider, bootstrap.onAuthChanged);
  ref.onDispose(bootstrap.dispose);
  return bootstrap;
});
