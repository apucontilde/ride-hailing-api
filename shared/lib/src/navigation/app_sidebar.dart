import 'package:flutter/material.dart';

import 'app_nav_item.dart';
import 'app_nav_section.dart';
import 'app_sidebar_account.dart';
import 'app_sidebar_header.dart';
import 'app_sidebar_item.dart';
import 'app_sidebar_section.dart';

/// The whole sidebar: account header, the app's items grouped by section, and an
/// optional pinned footer.
///
/// Items are grouped by [AppNavSection] in the enum's declaration order and
/// empty groups are skipped, so the rider's five items and the driver's three
/// produce the same four-heading structure from the same widget. The scroller is
/// the `ListView` and the footer is its **sibling**, not a child — a footer
/// inside the list scrolls away, and sign-out must not.
///
/// Navigation is entirely app-owned: [onItemSelected] is called with the tapped
/// [AppNavItem] and nothing here pushes a route, because this package has no
/// `go_router`.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.items,
    required this.account,
    required this.onItemSelected,
    this.onAccountPressed,
    this.footer,
    this.selectedRoute,
  });

  /// The rows to render, in the order the app wants them within each section.
  final List<AppNavItem> items;

  /// Header data.
  final AppSidebarAccount account;

  /// Called with the tapped item. The app pops the sidebar and pushes the route.
  final ValueChanged<AppNavItem> onItemSelected;

  /// Called when the header is tapped. Null leaves the header inert.
  final VoidCallback? onAccountPressed;

  /// Pinned below the scroller — both apps use it for sign-out.
  final Widget? footer;

  /// Highlights the row whose [AppNavItem.route] equals this. Both apps pass
  /// it from their shell (the rider `RiderShell` and the driver `DriverShell`),
  /// wiring the current location so the active section is highlighted.
  final String? selectedRoute;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      AppSidebarHeader(account: account, onTap: onAccountPressed),
    ];
    for (final section in AppNavSection.values) {
      final group = items.where((item) => item.section == section).toList();
      if (group.isEmpty) continue;
      children.add(AppSidebarSectionHeader(section: section));
      for (final item in group) {
        children.add(
          AppSidebarItem(
            key: Key('sidebar-item-${item.id}'),
            leading: item.icon,
            label: item.label,
            selected: selectedRoute != null && selectedRoute == item.route,
            onTap: () => onItemSelected(item),
          ),
        );
      }
    }

    return Drawer(
      child: Column(
        children: [
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: children),
          ),
          ?footer,
        ],
      ),
    );
  }
}

/// Pops the sidebar.
///
/// Named to match Flutter's own `openDrawer`, and deliberately not
/// `closeAppDrawer`, so both apps write the same two lines at every call site:
///
/// ```dart
/// closeSidebar(context);
/// context.push(item.route);
/// ```
///
/// Popping **before** pushing is load-bearing: the reverse order leaves the
/// sidebar open on top of the pushed route, which is what the rider's
/// `GestureDetector` header already had to get right by hand.
void closeSidebar(BuildContext context) => Navigator.of(context).pop();
