import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/app_bootstrap.dart';
import 'core/auth/auth_provider.dart';
import 'core/location/app_lifecycle_notifier.dart';
import 'core/location/location_service.dart';
import 'core/push/device_token_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class DriverApp extends ConsumerStatefulWidget {
  const DriverApp({super.key});

  @override
  ConsumerState<DriverApp> createState() => _DriverAppState();
}

class _DriverAppState extends ConsumerState<DriverApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // The background-tracking feature needs the foreground/background
    // transitions so a resumed driver can re-publish a fresh fix (bug #18).
    WidgetsBinding.instance.addObserver(this);
    // Authenticate + restore the in-progress ride exactly once, before the
    // router reads the session. The splash route shows the spinner while this
    // is in flight; the router redirect is gated on it (`core/app_bootstrap.dart`).
    final bootstrap = ref.read(sessionBootstrapProvider);
    Future<void>.microtask(bootstrap.run);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Recorded centrally; `locationServiceProvider` installs the `onResumed`
    // hook that re-publishes the last fix.
    ref.read(appLifecycleProvider.notifier).update(state);
  }

  @override
  Widget build(BuildContext context) {
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
