import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks the app's [AppLifecycleState] so the location layer can restore
/// tracking when the driver returns to the foreground.
///
/// The widget layer feeds every transition in (see `app.dart`, which installs a
/// `WidgetsBindingObserver`); the pure state machine lives here so it can be
/// unit-tested without a widget binding.
class AppLifecycleNotifier extends StateNotifier<AppLifecycleState> {
  AppLifecycleNotifier() : super(AppLifecycleState.resumed);

  /// Invoked exactly once for each background→foreground transition. Wired to
  /// the location service so a resumed driver immediately re-publishes a fix
  /// instead of waiting for the next movement event.
  VoidCallback? onResumed;

  /// Records [state]. Fires [onResumed] only on a genuine transition into
  /// [AppLifecycleState.resumed], never on a duplicate event.
  void update(AppLifecycleState state) {
    if (state == this.state) return;
    this.state = state;
    if (state == AppLifecycleState.resumed) {
      onResumed?.call();
    }
  }
}

final appLifecycleProvider =
    StateNotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
  (ref) => AppLifecycleNotifier(),
);
