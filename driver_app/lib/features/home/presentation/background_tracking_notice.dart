import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// Whether the one-time background-tracking notice has already been shown this
/// session. Reset only by process restart; the notice is informational, not a
/// hard gate.
final backgroundTrackingNoticeShownProvider = StateProvider<bool>((ref) => false);

/// Opens the OS app-permission settings. Injectable so a widget test can assert
/// the deep-link without touching the platform channel.
final openAppSettingsProvider = Provider<Future<bool> Function()>(
  (ref) => LocationHelper.openAppSettings,
);

/// One-time explainer shown the first time the driver goes online.
///
/// Android 11+ can only grant "Allow all the time" from system settings, so the
/// copy names that path and offers the deep-link rather than pretending the
/// in-app request is sufficient.
class BackgroundTrackingNotice extends ConsumerWidget {
  const BackgroundTrackingNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      key: const Key('background-tracking-notice'),
      title: const Text('Stay online with the screen off'),
      content: const Text(
        "While you're online, the app keeps sharing your location with "
        'dispatch even if you switch apps or lock the screen, so you keep '
        'receiving ride offers. A notification shows while this is active. '
        'For this to work, open settings and set location to '
        '"Allow all the time" (and allow notifications on Android 13+).',
      ),
      actions: [
        TextButton(
          key: const Key('background-tracking-dismiss'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
        FilledButton(
          key: const Key('background-tracking-open-settings'),
          onPressed: () {
            ref.read(openAppSettingsProvider)();
            Navigator.of(context).pop();
          },
          child: const Text('Open settings'),
        ),
      ],
    );
  }
}
