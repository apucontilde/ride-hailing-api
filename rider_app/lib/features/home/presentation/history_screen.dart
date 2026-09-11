import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ride History')),
      body: const Center(
        child: Text(
          'No rides yet',
          style: TextStyle(color: Colors.grey),
        ),
      ),
    );
  }
}