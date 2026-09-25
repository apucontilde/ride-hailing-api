import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../driver/model/driver_profile.dart';

/// Editable profile state backed by `GET/PUT /driver/me`.
class ProfileState {
  final DriverProfile? driver;
  final bool saving;
  final String? error;

  const ProfileState({this.driver, this.saving = false, this.error});

  ProfileState copyWith({
    DriverProfile? driver,
    bool? saving,
    String? error,
  }) {
    return ProfileState(
      driver: driver ?? this.driver,
      saving: saving ?? this.saving,
      error: error,
    );
  }
}

/// Reads the profile the auth bootstrap already cached from `GET /driver/me`
/// and persists `PUT /driver/me` edits, replacing both the local state and the
/// shared `driverProfileProvider` cache on success.
class ProfileNotifier extends StateNotifier<ProfileState> {
  final Ref _ref;

  ProfileNotifier(this._ref)
      : super(ProfileState(driver: _ref.read(driverProfileProvider)));

  /// Convenience label for `rating_summary` (a plain string on the backend,
  /// e.g. `4.8`).
  String get ratingSummaryLabel {
    final raw = state.driver?.ratingSummary ?? '';
    if (raw.isEmpty) return 'New driver';
    return '★ $raw';
  }

  /// Re-syncs with the profile cached by the authenticated session.
  void refresh() {
    final driver = _ref.read(driverProfileProvider);
    if (driver != null) {
      state = state.copyWith(driver: driver, error: null);
    }
  }

  /// Sends only the fields that were provided. Returns `false` (keeping the
  /// old profile) on failure and surfaces the message via [ProfileState.error].
  Future<bool> updateProfile({
    String? firstName,
    String? lastName,
    String? phone,
  }) async {
    state = state.copyWith(saving: true, error: null);
    try {
      final body = <String, dynamic>{
        if (firstName != null && firstName.trim().isNotEmpty)
          'first_name': firstName.trim(),
        if (lastName != null && lastName.trim().isNotEmpty)
          'last_name': lastName.trim(),
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      };
      final response = await _ref
          .read(apiClientProvider)
          .dio
          .put(ApiEndpoints.driverMe, data: body);
      final data = response.data as Map<String, dynamic>;
      final driverMap = data['driver'] as Map<String, dynamic>?;
      if (driverMap == null) {
        state = state.copyWith(
          saving: false,
          error: 'Unexpected server response. Please try again.',
        );
        return false;
      }
      final driver = DriverProfile.fromJson(driverMap);
      _ref.read(driverProfileProvider.notifier).state = driver;
      state = ProfileState(driver: driver);
      return true;
    } on DioException catch (e) {
      final message = e.error is ApiException
          ? (e.error as ApiException).message
          : (e.message ?? 'Could not save your profile. Please try again.');
      state = state.copyWith(saving: false, error: message);
      return false;
    } catch (_) {
      state = state.copyWith(
        saving: false,
        error: 'Could not save your profile. Please try again.',
      );
      return false;
    }
  }
}

final profileNotifierProvider =
    StateNotifierProvider<ProfileNotifier, ProfileState>((ref) {
  return ProfileNotifier(ref);
});