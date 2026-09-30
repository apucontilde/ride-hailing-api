import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/auth/auth_provider.dart';
import 'core/location/location_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class DriverApp extends ConsumerWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lifecycle: manage location stream based on auth/profile state.
    final authState = ref.watch(authProvider);
    final service = ref.read(locationServiceProvider);

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
