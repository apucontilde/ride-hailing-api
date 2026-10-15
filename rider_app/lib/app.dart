import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/app_bootstrap.dart';
import 'core/push/device_token_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class RiderApp extends ConsumerStatefulWidget {
  const RiderApp({super.key});

  @override
  ConsumerState<RiderApp> createState() => _RiderAppState();
}

class _RiderAppState extends ConsumerState<RiderApp> {
  @override
  void initState() {
    super.initState();
    // Authenticate + restore the in-progress ride exactly once, before the
    // router reads the session. The splash route shows the spinner while this
    // is in flight; the router redirect is gated on it (`app_bootstrap.dart`).
    final bootstrap = ref.read(sessionBootstrapProvider);
    Future<void>.microtask(bootstrap.run);
  }

  @override
  Widget build(BuildContext context) {
    // Materialize the push device-token service so it observes the session for
    // the app's lifetime. Its registration is best-effort and independent of the
    // ride flows below.
    ref.read(deviceTokenServiceProvider);

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Rider App',
      theme: AppTheme.light,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
