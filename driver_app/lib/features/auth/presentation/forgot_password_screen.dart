import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';

/// Wired to the real `POST /auth/forgot-password` endpoint (US-1). On success
/// the recovery link flow continues on the reset-password screen.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _isLoading = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLoading) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _info = null;
    });
    try {
      final apiClient = ref.read(apiClientProvider);
      await apiClient.dio.post(
        ApiEndpoints.forgotPassword,
        data: {'email': _emailController.text.trim()},
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _info = 'Recovery link sent. Open it and enter the token + new password below.';
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final api = e.error;
      setState(() {
        _isLoading = false;
        _error = api is ApiException ? api.message : 'Something went wrong. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: AppBackButton(onPressed: () => context.go('/login')),
        title: const Text('Forgot Password'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _emailController,
                label: 'Email',
                hint: 'Enter your account email',
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                prefixIcon: const Icon(Icons.email_outlined),
                validator: Validators.validateEmail,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: AppTextStyles.body.copyWith(color: AppColors.danger),
                ),
              ],
              if (_info != null) ...[
                const SizedBox(height: 12),
                Text(
                  _info!,
                  style: AppTextStyles.body.copyWith(color: AppColors.primary),
                ),
              ],
              const SizedBox(height: 24),
              AppButton(
                label: 'Send recovery link',
                onPressed: _submit,
                isLoading: _isLoading,
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => context.go('/reset-password'),
                child: const Text('Have a reset token? Reset password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}