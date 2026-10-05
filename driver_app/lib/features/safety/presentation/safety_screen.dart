import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/location/location_service.dart';
import '../data/safety_repository.dart';

/// US-12 safety/support surface: an acknowledgement-only SOS and a feedback
/// dialog.
///
/// The UI says plainly that SOS only reaches the support team and does **not**
/// dispatch emergency services: the backend handler is ack-only
/// (`internal/handler/platform.go:52-68`), and an unqualified "SOS" button
/// would invite a driver in danger to rely on it.
class SafetyScreen extends ConsumerWidget {
  const SafetyScreen({super.key});

  Future<void> _sendSos(BuildContext context, WidgetRef ref) async {
    final position = ref.read(lastPositionProvider);
    if (position == null) {
      _show(context, 'Location unavailable — cannot send SOS.');
      return;
    }
    try {
      await ref.read(safetyRepositoryProvider).sendSos(
            lat: position.lat,
            lng: position.lng,
          );
      if (!context.mounted) return;
      _show(context, 'SOS sent — our support team has been alerted.');
    } catch (_) {
      if (!context.mounted) return;
      _show(context, 'Could not send SOS. Please call emergency services.');
    }
  }

  Future<void> _openFeedback(BuildContext context, WidgetRef ref) async {
    // No `TextEditingController`: the dialog outlives `showDialog` during its
    // exit animation, so disposing one here would assert mid-frame.
    var message = '';
    final submitted = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send feedback'),
        content: TextField(
          key: const Key('feedback-input'),
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          onChanged: (value) => message = value,
          decoration: const InputDecoration(
            labelText: 'What went wrong?',
            hintText: 'Describe the issue',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('feedback-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('feedback-send'),
            onPressed: () => Navigator.of(dialogContext).pop(message.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (submitted == null || submitted.isEmpty) return;
    if (!context.mounted) return;
    await _sendFeedback(context, ref, submitted);
  }

  Future<void> _sendFeedback(
    BuildContext context,
    WidgetRef ref,
    String message,
  ) async {
    try {
      await ref.read(safetyRepositoryProvider).sendFeedback(
            type: 'app_issue',
            message: message,
          );
      if (!context.mounted) return;
      _show(context, 'Thanks — feedback sent.');
    } catch (_) {
      if (!context.mounted) return;
      _show(context, 'Could not send feedback. Please try again.');
    }
  }

  void _show(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety & support')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Icon(Icons.health_and_safety_outlined, size: 64),
          const SizedBox(height: 16),
          Text(
            'Emergency SOS',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Sends an alert with your last known position to our support team. '
            'This does not contact emergency services — if you are in danger, '
            'call your local emergency number.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('sos-button'),
            onPressed: () => _sendSos(context, ref),
            icon: const Icon(Icons.sos_outlined),
            label: const Text('Send SOS'),
          ),
          const SizedBox(height: 32),
          Text(
            'Feedback',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Tell us about a problem with the app.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('feedback-button'),
            onPressed: () => _openFeedback(context, ref),
            icon: const Icon(Icons.feedback_outlined),
            label: const Text('Send feedback'),
          ),
        ],
      ),
    );
  }
}
