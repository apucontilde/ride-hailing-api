import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_provider.dart';
import '../features/home/data/current_ride_provider.dart';

/// The one-time session bootstrap: authenticate, then restore an in-progress
/// ride before the router reads the session.
///
/// This closes the web-reload defect: go_router boots at the reloaded route
/// (a hash URL carries `/#/home`), so `SplashScreen` — the historical only
/// caller of `checkAuth()` — never mounts. Running the probe here, once, on
/// every entry path (cold start, reload, login) and gating the redirect on
/// [complete] means an authenticated session is known before any route
/// decision.
///
/// [run] is idempotent: it performs exactly one `checkAuth()` (one `/me`/refresh
/// probe) per app launch even if the root widget rebuilds.
class SessionBootstrap extends ChangeNotifier {
  SessionBootstrap(this._ref);

  final Ref _ref;
  bool _started = false;
  bool _disposed = false;
  bool _complete = false;

  /// Whether `checkAuth()` (and, when authenticated, the ride restore) has
  /// settled. The router redirect blocks on this.
  bool get complete => _complete;

  Future<void> run() async {
    if (_started || _disposed) return;
    _started = true;
    await _ref.read(authProvider.notifier).checkAuth();
    if (_ref.read(authProvider).isAuthenticated) {
      // Restore an in-progress ride before the first route decision so a reload
      // lands on the trip, not Home. A transient failure degrades to /home — it
      // never fabricates a restore (the poll surfaces only real rides).
      await _ref.read(currentRideProvider.notifier).checkOnce();
    }
    if (_disposed) return;
    _complete = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final sessionBootstrapProvider = Provider<SessionBootstrap>((ref) {
  final bootstrap = SessionBootstrap(ref);
  ref.onDispose(bootstrap.dispose);
  return bootstrap;
});
