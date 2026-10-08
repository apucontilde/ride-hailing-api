import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

class PaymentScreen extends ConsumerWidget {
  const PaymentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Body-only: `RiderShell` owns the `Scaffold` + `AppBar` + drawer.
    return const AppEmptyState(
      icon: Icons.credit_card,
      message: 'Payment methods coming soon',
    );
  }
}
