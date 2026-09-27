import 'package:flutter/material.dart';

/// The sign-out confirmation both apps used to hand-roll as a private
/// `_confirmSignOut`.
///
/// Copy is identical in the two apps today apart from one sentence, so the
/// sentence is a parameter and everything else is fixed. The dialog's shape and
/// button pair are asserted by the rider's existing settings suite
/// (`find.widgetWithText(TextButton, 'Cancel')`,
/// `find.widgetWithText(FilledButton, 'Sign out')`), so neither may change.
Future<bool> showAppSignOutDialog(
  BuildContext context, {
  String? message,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sign out?'),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  // A dismissed dialog (barrier tap, back button) is a "no".
  return confirmed ?? false;
}

/// Runs the whole sign-out flow: confirm, then [onSignOut], then
/// [onSignOutCompleted].
///
/// Session state stays app-owned on purpose. This function never touches a
/// provider, a router or a token — the app passes its own
/// `ref.read(authProvider.notifier).logout()` and its own `context.go('/login')`,
/// which is what keeps the driver invariant "`core/auth/auth_provider.dart` is
/// the single owner of session/token state" true.
///
/// [onSignOutCompleted] runs only after [onSignOut] completes, and not at all if
/// it throws: navigating to `/login` while the logout POST is still in flight is
/// how a half-cleared session survives into the next sign-in.
Future<void> performAppSignOut(
  BuildContext context, {
  String? message,
  required Future<void> Function() onSignOut,
  VoidCallback? onSignOutCompleted,
}) async {
  final confirmed = await showAppSignOutDialog(context, message: message);
  if (!confirmed || !context.mounted) return;
  await onSignOut();
  if (!context.mounted) return;
  onSignOutCompleted?.call();
}
