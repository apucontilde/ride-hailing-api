import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/auth/auth_provider.dart';
import 'core/location/location_service.dart';
import 'core/push/device_token_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class DriverApp extends ConsumerWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lifecycle: manage location stream based on auth/profile state.
    final authState = ref.watch(authProvider);
    final service = ref.read(locationServiceProvider);

    // Materialize the push device-token service so it observes the session and
    // availability for the app's lifetime. Its registration is best-effort and
    // independent of the location/websocket wiring below.
    ref.read(deviceTokenServiceProvider);

    if (authState.isAuthenticated) {
      // Crash-while-online recovery: re-arm stream without flipping switch.
      service.start();
    } else {
      // Not authenticated: stop everything on logout.
      service.stop();
    }

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Driver App',
      theme: AppTheme.light,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
