import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PaymentScreen extends ConsumerWidget {
  const PaymentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Body-only: `RiderShell` owns the `Scaffold` + `AppBar` + drawer.
    return const Center(
      child: Text(
        'Payment methods coming soon',
        style: TextStyle(color: Colors.grey),
      ),
    );
  }
}
