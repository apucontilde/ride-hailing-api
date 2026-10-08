import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
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
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (state.success)
          _banner(
            key: const Key('sos-success'),
            color: AppColors.success,
            icon: Icons.check_circle,
            text: 'Emergency alert sent \u2014 support has been notified',
          ),
        if (state.error != null)
          _banner(
            key: const Key('sos-error'),
            color: AppColors.danger,
            icon: Icons.error_outline,
            text: state.error!,
          ),
        if (state.success || state.error != null)
          const SizedBox(height: AppSpacing.lg),
        const AppSectionHeader(title: 'Emergency'),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          key: const Key('sos-button'),
          label: 'Send SOS alert',
          variant: AppButtonVariant.danger,
          icon: Icons.sos,
          isLoading: state.isSending,
          onPressed: () => _onEmergencyPressed(context, ref),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Note: alert acknowledgment only \u2014 backend does not yet '
          'persist or dispatch SOS alerts',
          style: AppTextStyles.caption.copyWith(color: AppColors.muted),
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
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(text, style: AppTextStyles.body.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
