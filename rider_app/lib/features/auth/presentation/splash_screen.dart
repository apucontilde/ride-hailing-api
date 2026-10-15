import 'package:flutter/material.dart';

/// The transient startup route: a spinner shown while the app-level session
/// bootstrap (`core/app_bootstrap.dart`) authenticates and restores any
/// in-progress ride. The router redirect is gated on the bootstrap and moves on
/// to the resolved route; this widget owns no navigation of its own, so a web
/// reload at any route is handled by the bootstrap rather than relying on this
/// screen ever mounting.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
