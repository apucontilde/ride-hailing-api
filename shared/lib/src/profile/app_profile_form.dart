import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/validators.dart';

/// The first-name / last-name / phone edit form both profile screens ship.
///
/// Owns its `Form`, its `GlobalKey<FormState>` and its three controllers, so an
/// app wiring it up passes seeds in and reads typed values out of [onSave] —
/// it no longer reaches into controllers. That is why [onSave] takes named
/// arguments instead of being a `VoidCallback`.
///
/// Three details here are load-bearing and were previously duplicated per app:
///
/// * **An empty phone is valid.** `Validators.validatePhone` returns
///   `'Phone number is required'` for empty input, so wiring it straight up would
///   make the phone mandatory and the driver's first/last-only save — its *only*
///   save path, since it never seeds the phone — could never be sent. The
///   empty-is-valid wrapper both apps hand-roll is kept.
/// * **A blank phone arrives as `null`**, not `''`, which is what both apps'
///   `_save()` used to compute with `text.isEmpty ? null : text`.
/// * **Field labels are exactly `'First name'`, `'Last name'`, `'Phone'`** — the
///   rider's profile suite locates the fields with
///   `find.widgetWithText(TextFormField, <label>)`, so renaming one breaks four
///   assertions.
///
/// The `'Edit profile'` heading and the surrounding `Card` are part of this
/// widget: both apps render that identical structure today, and leaving it
/// app-side would be the one piece of the form the two could still drift on.
class AppProfileForm extends StatefulWidget {
  const AppProfileForm({
    super.key,
    required this.onSave,
    this.firstName,
    this.lastName,
    this.phone,
    this.isSaving = false,
    this.errorText,
  });

  /// Called after the fields validate. `phone` is `null` when the field is blank.
  ///
  /// `Future`-returning because both apps' `_save()` awaits `updateProfile(...)`,
  /// and the button's spinner has nothing to await otherwise.
  final Future<void> Function({
    required String firstName,
    required String lastName,
    String? phone,
  }) onSave;

  /// Seed for the first-name field.
  final String? firstName;

  /// Seed for the last-name field.
  final String? lastName;

  /// Seed for the phone field. The driver passes `null` on purpose: its
  /// `initState` seeds first/last only, so its phone field starts empty and a
  /// first/last-only save must not start writing a phone the app never wrote.
  final String? phone;

  /// Caller-owned busy flag — both apps pass their notifier's `saving`, so the
  /// button disables and spins for a save the *provider* is tracking.
  final bool isSaving;

  /// Server-side failure message, rendered under the fields with
  /// `Key('profile-error')`.
  final String? errorText;

  @override
  State<AppProfileForm> createState() => _AppProfileFormState();
}

class _AppProfileFormState extends State<AppProfileForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _phoneController;

  /// Busy because *this* widget started the save. Separate from
  /// [AppProfileForm.isSaving] so the button stays disabled for the whole await
  /// even when the caller has no provider flag of its own.
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.firstName ?? '');
    _lastNameController = TextEditingController(text: widget.lastName ?? '');
    _phoneController = TextEditingController(text: widget.phone ?? '');
  }

  @override
  void didUpdateWidget(covariant AppProfileForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-apply a seed only when the caller's value actually changed, so typing is
    // never clobbered by an unrelated rebuild. This is how the rider's post-save
    // phone re-read lands back in the field: `PUT /rider/me` never echoes the
    // `users` row, so the app re-reads `GET /rider/me` and passes the fresh
    // phone back down.
    if (widget.firstName != oldWidget.firstName) {
      _firstNameController.text = widget.firstName ?? '';
    }
    if (widget.lastName != oldWidget.lastName) {
      _lastNameController.text = widget.lastName ?? '';
    }
    if (widget.phone != oldWidget.phone) {
      _phoneController.text = widget.phone ?? '';
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  bool get _saving => _submitting || widget.isSaving;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final phone = _phoneController.text.trim();
      await widget.onSave(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        phone: phone.isEmpty ? null : phone,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.errorText;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit profile', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _firstNameController,
                decoration: const InputDecoration(
                  labelText: 'First name',
                  border: OutlineInputBorder(),
                ),
                validator: Validators.validateName,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _lastNameController,
                decoration: const InputDecoration(
                  labelText: 'Last name',
                  border: OutlineInputBorder(),
                ),
                validator: Validators.validateName,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  hintText: 'Optional',
                  border: OutlineInputBorder(),
                ),
                // Empty is valid: see the class doc.
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return null;
                  return Validators.validatePhone(value);
                },
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  error,
                  key: const Key('profile-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                key: const Key('profile-save-button'),
                onPressed: _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
