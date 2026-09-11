import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dio/dio.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/utils/validators.dart';
import 'widgets/auth_text_field.dart';

/// Completes the real password-recovery flow via `POST /auth/reset-password`
/// `{token, new_password}` — the destination of the recovery link.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tokenController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _tokenController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _info = null;
    });
    try {
      final apiClient = ref.read(apiClientProvider);
      await apiClient.dio.post(
        ApiEndpoints.resetPassword,
        data: {
          'token': _tokenController.text.trim(),
          'new_password': _passwordController.text,
        },
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _info = 'Password reset. You can now log in with your new password.';
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
      appBar: AppBar(title: const Text('Reset Password')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AuthTextField(
                controller: _tokenController,
                label: 'Reset token',
                hint: 'Paste the token from your recovery link',
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                validator: (value) =>
                    Validators.validateRequired(value, 'Reset token'),
              ),
              const SizedBox(height: 16),
              AuthTextField(
                controller: _passwordController,
                label: 'New password',
                hint: 'Enter a new password',
                obscureText: true,
                prefixIcon: const Icon(Icons.lock_outlined),
                validator: Validators.validatePassword,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_info != null) ...[
                const SizedBox(height: 12),
                Text(
                  _info!,
                  style: TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Reset password'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => context.go('/login'),
                child: const Text('Back to log in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}