import 'package:flutter/material.dart';

import 'app_nav_item.dart';

/// The profile screen's menu card: `Card > Column > ListTile` rows separated by
/// a hairline divider.
///
/// Takes the **same** [AppNavItem] list the sidebar takes, which is the whole
/// point — the two surfaces used to read their own hardcoded icons and labels
/// and had already drifted inside a single app (the rider's sidebar called
/// `/payment` `Icons.payment` while its profile card called the same destination
/// `Icons.credit_card`).
///
/// [onItemSelected] is required and has no default, because this card is used
/// *outside* the sidebar, on a page where there is nothing to pop and no router
/// in this package to push with.
///
/// ⚠️ The seven `ListTile` subtitles the two apps' cards carry today have no
/// [AppNavItem] field and are dropped by this widget. That is a deliberate
/// content change recorded in both adoption stages, not an oversight —
/// [AppNavItem] carries label, icon and route only.
class AppNavLinkCard extends StatelessWidget {
  const AppNavLinkCard({
    super.key,
    required this.items,
    required this.onItemSelected,
  });

  /// Rows to render, in order.
  final List<AppNavItem> items;

  /// Called with the tapped row's item.
  final ValueChanged<AppNavItem> onItemSelected;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            ListTile(
              key: Key('nav-link-${items[i].id}'),
              leading: Icon(items[i].icon),
              title: Text(items[i].label),
              onTap: () => onItemSelected(items[i]),
            ),
          ],
        ],
      ),
    );
  }
}
