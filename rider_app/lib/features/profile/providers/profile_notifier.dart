import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../home/model/rider_profile.dart';

/// Editable profile state backed by `GET`/`PUT /rider/me`.
class ProfileState {
  final RiderProfile? profile;
  final bool saving;
  final String? error;

  const ProfileState({this.profile, this.saving = false, this.error});

  ProfileState copyWith({
    RiderProfile? profile,
    bool? saving,
    String? error,
  }) {
    return ProfileState(
      profile: profile ?? this.profile,
      saving: saving ?? this.saving,
      error: error,
    );
  }
}

/// Reads the profile the auth bootstrap already cached from `GET /rider/me`
/// and persists `PUT /rider/me` edits, replacing both the local state and the
/// shared `riderProfileProvider` cache on success.
///
/// Mirrors `driver_app/lib/features/profile/providers/profile_notifier.dart`,
/// with two differences forced by the rider handler's response shape.
class ProfileNotifier extends StateNotifier<ProfileState> {
  final Ref _ref;

  ProfileNotifier(this._ref)
      : super(ProfileState(profile: _ref.read(riderProfileProvider)));

  /// Re-syncs with the profile cached by the authenticated session.
  void refresh() {
    final profile = _ref.read(riderProfileProvider);
    if (profile != null) {
      state = state.copyWith(profile: profile, error: null);
    }
  }

  /// Persists the edits. Omitted fields fall back to the cached profile rather
  /// than being dropped from the body — `PUT /rider/me` assigns first name,
  /// last name and photo unconditionally (`internal/handler/rider.go:74-76`),
  /// so leaving one out wipes it server-side.
  ///
  /// Pass [photoUrl] to change the photo; omit it to keep the current one.
  /// Phone is the exception: it is written to the `users` row and is never
  /// echoed back, so a successful save re-reads `GET /rider/me` to make the
  /// stored phone authoritative.
  ///
  /// Returns `false` (keeping the old profile) on failure and surfaces the
  /// message via [ProfileState.error].
  Future<bool> updateProfile({
    String? firstName,
    String? lastName,
    String? phone,
    String? photoUrl,
  }) async {
    state = state.copyWith(saving: true, error: null);
    try {
      final current = state.profile;
      final body = <String, dynamic>{
        'first_name': _orCurrent(firstName, current?.firstName),
        'last_name': _orCurrent(lastName, current?.lastName),
        'photo_url': photoUrl ?? current?.photoUrl ?? '',
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      };
      final response = await _ref
          .read(apiClientProvider)
          .dio
          .put(ApiEndpoints.riderMe, data: body);
      final data = response.data as Map<String, dynamic>;
      final riderMap = data['rider'] as Map<String, dynamic>?;
      if (riderMap == null) {
        state = state.copyWith(
          saving: false,
          error: 'Unexpected server response. Please try again.',
        );
        return false;
      }
      var rider = RiderProfile.fromJson(riderMap);
      _ref.read(riderProfileProvider.notifier).state = rider;
      // `PUT /rider/me` answers `{rider}` only, so the `users` row (phone) is
      // not confirmed by it. Re-read the full profile; non-fatal.
      final fresh = await _ref.read(authProvider.notifier).refreshProfile();
      if (fresh != null) rider = fresh;
      state = ProfileState(profile: rider);
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

  String _orCurrent(String? submitted, String? current) =>
      (submitted != null && submitted.trim().isNotEmpty)
          ? submitted.trim()
          : current ?? '';
}

final profileNotifierProvider =
    StateNotifierProvider<ProfileNotifier, ProfileState>((ref) {
  return ProfileNotifier(ref);
});
