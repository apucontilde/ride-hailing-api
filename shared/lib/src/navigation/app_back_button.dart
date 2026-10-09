import 'package:flutter/material.dart';

/// The back affordance both apps use, so the driver and rider point-back UX is
/// identical.
///
/// Mirrors [AppSidebarToggleButton]: a real `IconButton` rendering a real
/// `Icon`, so `find.byIcon(Icons.arrow_back)` works in both apps' widget tests.
/// It sits safely in an `AppBar(leading:)` as well as in a body overlay.
///
/// This package owns no router, so it never calls `go`/`push`: when [onPressed]
/// is not supplied it pops the enclosing navigator if it can, and otherwise
/// hands control to the app-supplied [onFallback].
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    super.key,
    this.onPressed,
    this.onFallback,
    this.tooltip = 'Back',
    this.icon,
  });

  /// Explicit target, highest precedence. When null the button pops if the
  /// navigator canPop, else calls [onFallback].
  final VoidCallback? onPressed;

  /// Called when the navigator cannot pop (entered via `go`, e.g. a top-level
  /// section). Apps pass `() => context.go('/home')` here.
  final VoidCallback? onFallback;

  /// Accessibility tooltip. Defaults to `'Back'`.
  final String? tooltip;

  /// Glyph to render. Null falls back to [Icons.arrow_back].
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon ?? Icons.arrow_back),
      tooltip: tooltip,
      onPressed: onPressed ??
          () {
            final navigator = Navigator.of(context);
            if (navigator.canPop()) {
              navigator.pop();
            } else {
              onFallback?.call();
            }
          },
    );
  }
}
