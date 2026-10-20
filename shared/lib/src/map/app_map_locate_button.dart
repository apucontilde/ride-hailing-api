import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The one bottom-right map control shared by the rider and driver apps.
///
/// Presses alternate **fit route → current location → fit route → …**. On the
/// initial mount and whenever [routeKey] changes, if [hasRoute] is true the
/// widget schedules a post-frame [onFitRoute]; a successful auto-fit counts as
/// the fit phase, so the next press locates. A failed action stays on that
/// action and retries; a failed locate calls [onLocationUnavailable].
class AppMapLocateButton extends StatefulWidget {
  const AppMapLocateButton({
    super.key,
    required this.routeKey,
    required this.hasRoute,
    required this.onFitRoute,
    required this.onCurrentLocation,
    this.onLocationUnavailable,
  });

  /// Changes only on a material route/itinerary change; triggers auto-fit and
  /// starts a new cycle.
  final Object? routeKey;

  /// `false` when there is no route/itinerary to fit; no auto-fit occurs and
  /// every press locates.
  final bool hasRoute;

  /// Fits the camera to the drawn route. Return `true` once the camera moved,
  /// so the action advances to the current location.
  final bool Function() onFitRoute;

  /// Resolves the current-location target and centers on it. Return `false`
  /// when no fix or no move was possible; the action stays on locate.
  final Future<bool> Function() onCurrentLocation;

  final VoidCallback? onLocationUnavailable;

  @override
  State<AppMapLocateButton> createState() => _AppMapLocateButtonState();
}

class _AppMapLocateButtonState extends State<AppMapLocateButton> {
  /// Whether the next press locates (true) or fits the route (false).
  bool _nextIsLocate = false;

  /// In-flight guard: a second tap while a locate is unresolved is a no-op.
  bool _locating = false;

  /// Invalidates a scheduled auto-fit when the route changes again first.
  int _autoFitToken = 0;

  @override
  void initState() {
    super.initState();
    if (widget.hasRoute) _scheduleAutoFit();
  }

  @override
  void didUpdateWidget(AppMapLocateButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeKey != widget.routeKey) {
      // A material change starts a fresh cycle; a successful auto-fit below
      // moves it on to the locate half.
      _nextIsLocate = false;
      if (widget.hasRoute) _scheduleAutoFit();
    }
  }

  /// The single cross-app implementation of the auto-fit decision: a post-frame
  /// fit whenever the route first appears or materially changes. A stale token
  /// (another change landed first) is discarded.
  void _scheduleAutoFit() {
    final token = ++_autoFitToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _autoFitToken || !widget.hasRoute) return;
      var fitted = false;
      try {
        fitted = widget.onFitRoute();
      } catch (_) {
        fitted = false;
      }
      if (!mounted) return;
      setState(() => _nextIsLocate = fitted);
    });
  }

  Future<void> _handlePress() async {
    if (_locating) return;

    // Still on the fit half of the cycle.
    if (widget.hasRoute && !_nextIsLocate) {
      var fitted = false;
      try {
        fitted = widget.onFitRoute();
      } catch (_) {
        fitted = false;
      }
      if (!mounted) return;
      // A failed fit stays on fit (the next press retries).
      setState(() => _nextIsLocate = fitted);
      return;
    }

    // Locate half (or there is no route at all).
    setState(() => _locating = true);
    var located = false;
    try {
      located = await widget.onCurrentLocation();
    } catch (_) {
      located = false;
    } finally {
      if (mounted) setState(() => _locating = false);
    }
    if (!mounted) return;
    if (located) {
      setState(() => _nextIsLocate = false);
    } else {
      widget.onLocationUnavailable?.call();
    }
  }

  String get _tooltip =>
      (_nextIsLocate || !widget.hasRoute) ? 'Current location' : 'Fit route';

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      key: const Key('map-locate-button'),
      tooltip: _tooltip,
      backgroundColor: AppColors.surface,
      onPressed: _handlePress,
      child: const Icon(Icons.my_location, color: AppColors.info),
    );
  }
}
