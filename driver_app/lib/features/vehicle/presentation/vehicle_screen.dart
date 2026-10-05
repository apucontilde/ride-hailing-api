import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';

/// Reads `GET /driver/me/vehicle` — only reachable when the feature flag is on.
final vehicleDetailsProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final response = await ref
      .read(apiClientProvider)
      .dio
      .get(ApiEndpoints.driverMeVehicle);
  return (response.data as Map<String, dynamic>?) ?? const {};
});

/// US-D3 vehicle & documents surface, feature-gated by
/// [ApiConfig.vehicleFeatureEnabled]. The backend endpoints
/// (`GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents`) are STUBs
/// (`internal/handler/platform.go` returns `{"status":"stub",...}`), so while
/// the flag is `false` this screen shows a "coming soon" empty state instead of
/// pretending to save. The admin team handles verification.
class VehicleScreen extends ConsumerWidget {
  const VehicleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ApiConfig.vehicleFeatureEnabled;
    // Body-only: `DriverShell` owns the Scaffold/AppBar for the section.
    return enabled ? const _VehicleDetails() : const _ComingSoon();
  }
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.construction, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('Coming soon', style: TextStyle(fontSize: 20)),
            SizedBox(height: 8),
            Text(
              'Vehicle & documents verification is handled by the admin team. '
              'This section unlocks once the backend is ready.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _VehicleDetails extends ConsumerWidget {
  const _VehicleDetails();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.watch(vehicleDetailsProvider);
    return vehicle.when(
      data: (data) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.directions_car_outlined),
                  title: const Text('Status'),
                  subtitle: Text('${data['status'] ?? 'unknown'}'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Detail'),
                  subtitle: Text('${data['message'] ?? 'No details'}'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'The vehicle & documents endpoint is a backend stub, so nothing '
            'can be saved here yet. Verification is handled by the admin team.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Could not load vehicle details. Please try again.'),
      ),
    );
  }
}
