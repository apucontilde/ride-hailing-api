import 'package:flutter/material.dart';

/// Placeholder for the ride history entry point on the profile screen (plan 06
/// links here). The real list + earnings surface ships with `driver_app_plans/
/// 05_earnings_history_rating.md` (US-D10/D11), which replaces this file.
/// ⚠️ As of the 2026-09-25 audit this is the **only** history/earnings UI in the
/// app: `GET /driver/rides/history` is declared in `endpoints.dart` and never
/// invoked, so US-D11 is 🔴 in the running app.
class RidesHistoryScreen extends StatelessWidget {
  const RidesHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ride History')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Your ride history and earnings arrive with the earnings & history '
            'plan (driver_app_plans/05).',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}