import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: const Center(
        child: Text(
          'Security settings coming soon',
          style: TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}