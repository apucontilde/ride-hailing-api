import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/push/device_token_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class RiderApp extends ConsumerWidget {
  const RiderApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
