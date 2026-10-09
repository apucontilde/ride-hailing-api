import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../profile/providers/profile_notifier.dart';

/// US-D1 — driver onboarding. The registered account holds the `rider` role;
/// this screen promotes it to `driver` via `POST /driver/register`, persists the
/// collected name via `PUT /driver/me`, then routes to `/home`. Vehicle/documents
/// onboarding is real backend work and is feature-gated behind
/// `ApiConfig.vehicleFeatureEnabled`.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  bool _registering = false;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _registering = true);
    final ok = await ref.read(authProvider.notifier).registerAsDriver();
    if (!mounted) return;
    if (!ok) {
      setState(() => _registering = false);
      return;
    }
    // Persist the identity the form collected before the driver reaches /home.
    // Non-fatal: a failure leaves the profile edit form as the retry path, and
    // the driver still lands on /home either way.
    await ref.read(profileNotifierProvider.notifier).updateProfile(
          firstName: _firstNameController.text.trim(),
          lastName: _lastNameController.text.trim(),
        );
    if (!mounted) return;
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Become a Driver'),
        // `/onboarding` is force-redirected for authenticated non-drivers, so a
        // pop is a no-op. Signing out is the only meaningful "back": the router
        // then redirects to `/login`.
        leading: AppBackButton(
          onPressed: () => ref.read(authProvider.notifier).logout(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.directions_car, size: 64, color: AppColors.info),
              const SizedBox(height: 16),
              Text(
                'Drive with us',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Set your name below, accept the terms, and register to start receiving ride requests.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              AppTextField(
                controller: _firstNameController,
                label: 'First name',
                validator: Validators.validateName,
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _lastNameController,
                label: 'Last name',
                validator: Validators.validateName,
              ),
              if (authState.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  authState.error!,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.body.copyWith(color: AppColors.danger),
                ),
              ],
              const SizedBox(height: 24),
              AppButton(
                label: 'Register as a driver',
                onPressed: _register,
                isLoading: _registering,
              ),
              const SizedBox(height: 12),
              TextButton(
                // Signing out first is required: the router redirects an
                // authenticated non-driver straight back to `/onboarding`, so a
                // bare `go('/login')` was a silent no-op (driver bug #14).
                onPressed: () async {
                  await ref.read(authProvider.notifier).logout();
                  if (context.mounted) context.go('/login');
                },
                child: const Text('Use a different account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
