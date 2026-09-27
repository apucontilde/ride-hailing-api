import 'package:flutter/material.dart';

/// The hamburger both apps open the sidebar with.
///
/// The rider hand-rolls one as a floating `IconButton` over the map (it has no
/// `AppBar`, the map is edge-to-edge); the driver gets Flutter's implicit
/// `AppBar` hamburger. Same glyph, two different widgets — this is the one
/// widget that replaces both.
///
/// [icon] defaults to `Icons.menu` and renders a real `Icon`, which the rider's
/// `auth_flow_test.dart` and `home_screen_test.dart` both assert with
/// `find.byIcon(Icons.menu)`. Positioning stays app-side: the rider keeps its
/// `Positioned(left: 16)` wrapper around this.
class AppSidebarToggleButton extends StatelessWidget {
  const AppSidebarToggleButton({
    super.key,
    this.icon = Icons.menu,
    this.style,
    this.tooltip,
  });

  /// Glyph to render. Null falls back to [Icons.menu].
  final IconData? icon;

  /// Button chrome — the rider passes a white background with elevation so it
  /// reads against the map.
  final ButtonStyle? style;

  /// Accessibility tooltip.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon ?? Icons.menu),
      style: style,
      tooltip: tooltip,
      // Exactly what Flutter's own `DrawerButton` does, so this is safe in an
      // `AppBar(leading:)` as well as in a body overlay.
      onPressed: () => Scaffold.of(context).openDrawer(),
    );
  }
}
