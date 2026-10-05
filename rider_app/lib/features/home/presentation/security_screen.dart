import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/security_provider.dart';

class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  Future<void> _onEmergencyPressed(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send emergency alert?'),
        content: const Text('This sends an SOS with your last known location.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('sos-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Send alert'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(securityProvider.notifier).sendSos();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(securityProvider);
    // Body-only: `RiderShell` owns the `Scaffold` + `AppBar` + drawer.
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (state.success)
          _banner(
            key: const Key('sos-success'),
            color: Colors.green,
            icon: Icons.check_circle,
            text: 'Emergency alert sent \u2014 support has been notified',
          ),
        if (state.error != null)
          _banner(
            key: const Key('sos-error'),
            color: Colors.red,
            icon: Icons.error_outline,
            text: state.error!,
          ),
        if (state.success || state.error != null) const SizedBox(height: 16),
        const Text(
          'Emergency',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('sos-button'),
          onPressed: state.isSending
              ? null
              : () => _onEmergencyPressed(context, ref),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: state.isSending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.sos),
          label: const Text('Send SOS alert'),
        ),
        const SizedBox(height: 12),
        const Text(
          'Note: alert acknowledgment only \u2014 backend does not yet '
          'persist or dispatch SOS alerts',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      ],
    );
  }

  Widget _banner({
    required Key key,
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}
