/// Rider profile as returned by `GET /api/v1/rider/me` (the `rider` object).
///
/// Field set follows `internal/model/user.go` `Rider` struct:
/// `user_id, first_name, last_name, photo_url, status`. The `riders` columns are
/// `NOT NULL DEFAULT ''` (`migrations/004_create_profiles.up.sql`), so an unset
/// name or photo arrives as an empty string and is normalized to null here.
///
/// App-local on purpose — the driver app keeps its own profile model app-local
/// too, and `shared/` only carries the cross-app core (see AGENTS.md).
class RiderProfile {
  final String userId;
  final String? firstName;
  final String? lastName;
  final String? photoUrl;
  final String status;

  const RiderProfile({
    this.userId = '',
    this.firstName,
    this.lastName,
    this.photoUrl,
    this.status = 'idle',
  });

  factory RiderProfile.fromJson(Map<String, dynamic> json) {
    return RiderProfile(
      userId: json['user_id'] as String? ?? '',
      firstName: _textOrNull(json['first_name']),
      lastName: _textOrNull(json['last_name']),
      photoUrl: _textOrNull(json['photo_url']),
      status: json['status'] as String? ?? 'idle',
    );
  }

  static String? _textOrNull(Object? value) {
    if (value is! String) return null;
    return value.isEmpty ? null : value;
  }

  /// Best available display name; empty when the rider has not set one.
  String get fullName {
    return [firstName, lastName]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .join(' ');
  }

  bool get hasPhoto => photoUrl != null && photoUrl!.isNotEmpty;
}
