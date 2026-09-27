import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_settings_row.dart';

/// A titled group of [AppSettingsRow]s rendered as one `Card`.
///
/// Both apps' settings screens are three single-row cards separated by 12 dp
/// today, so a one-row section reproduces that exactly; a multi-row section is
/// what `extraSections` uses for anything new (the driver's safety plan asks for
/// a settings entry tile and has nowhere else to put it).
class AppSettingsSection extends StatelessWidget {
  const AppSettingsSection({super.key, this.title, required this.rows, this.icon});

  /// Heading above the card. Omit for a bare group, which is what every row in
  /// both apps' settings screens is today.
  final String? title;

  /// The rows, in order, separated by hairline dividers.
  final List<AppSettingsRow> rows;

  /// Optional group icon, rendered before [title].
  ///
  /// Reserved: no app passes it yet, and a shared-only test proves it renders.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final heading = title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (heading != null && heading.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xs,
              bottom: AppSpacing.sm,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: Colors.grey[700]),
                  const SizedBox(width: 6),
                ],
                Text(heading, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _SettingsRow(row: rows[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.row});

  final AppSettingsRow row;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final color = row.isDestructive ? error : null;
    return ListTile(
      leading: row.leading == null ? null : Icon(row.leading, color: color),
      title: Text(
        row.title,
        style: color == null ? null : TextStyle(color: color),
      ),
      subtitle: row.subtitle == null ? null : Text(row.subtitle!),
      trailing: row.trailing,
      onTap: row.onTap,
    );
  }
}
