import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../config.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';

/// Reads `GET /driver/me/vehicle` — only consulted when the feature flag is on.
final vehicleDetailsProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final response = await ref
      .read(apiClientProvider)
      .dio
      .get(ApiEndpoints.driverMeVehicle);
  return (response.data as Map<String, dynamic>?) ?? const {};
});

/// The details/save gate of [VehicleScreen], injectable for tests.
///
/// Production resolves to `ApiConfig.vehicleFeatureEnabled`, which stays
/// `false` while `GET/PUT /driver/me/vehicle` and `GET/POST /driver/me/documents`
/// are backend stubs (`internal/router/router.go:219-222`), so the screen
/// renders the `_ComingSoon` disclosure and reads nothing. Tests override this
/// to exercise both branches. The nav entry (`buildDriverNavItems`) deliberately
/// does **not** read this: the drawer/profile-card row is unconditional so
/// `/vehicle` is no longer deep-link-only (driver bug #6); the flag only picks
/// the screen's body.
final vehicleFeatureEnabledProvider = Provider<bool>(
  (ref) => ApiConfig.vehicleFeatureEnabled,
);

/// US-D3 vehicle & documents surface. Reachable unconditionally from the drawer
/// and the profile card; the **details/save half** is feature-gated by
/// [vehicleFeatureEnabledProvider] because the backend endpoints
/// (`GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents`) are STUBs
/// (`internal/handler/platform.go` returns `{"status":"stub",...}`), so while
/// the flag is `false` this screen shows a "coming soon" empty state instead of
/// pretending to save. The admin team handles verification.
class VehicleScreen extends ConsumerWidget {
  const VehicleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(vehicleFeatureEnabledProvider);
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
            Icon(
              Icons.construction,
              size: 64,
              color: AppColors.mutedFaint,
            ),
            SizedBox(height: 16),
            Text('Coming soon', style: AppTextStyles.title),
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
          AppCard(
            child: Column(
              children: [
                AppListTile(
                  leading: const Icon(Icons.directions_car_outlined),
                  title: const Text('Status'),
                  subtitle: Text('${data['status'] ?? 'unknown'}'),
                ),
                const Divider(height: 1),
                AppListTile(
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
      error: (e, _) => const AppErrorState(
        message: 'Could not load vehicle details. Please try again.',
      ),
    );
  }
}
