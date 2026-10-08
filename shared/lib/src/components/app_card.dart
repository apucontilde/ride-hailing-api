import 'package:flutter/material.dart';

/// The shared card surface.
///
/// A thin, parameterized wrapper over Material's `Card` so a screen does not
/// re-pick its margin/padding each time. The defaults match the history tile
/// (12 dp horizontal, 6 dp vertical margin; 12 dp inner padding).
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.onTap,
  });

  final Widget child;

  /// Inner padding. Omitted leaves the child flush with the card.
  final EdgeInsetsGeometry? padding;

  /// Outer margin. Defaults to the history tile's `12`/`6`.
  final EdgeInsetsGeometry? margin;

  /// Optional ink tap target wrapping the padded child.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    if (onTap != null) {
      content = InkWell(onTap: onTap, child: content);
    }
    return Card(
      margin:
          margin ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: content,
    );
  }
}
