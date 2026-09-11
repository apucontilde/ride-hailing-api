/// Driver profile as returned by `GET /api/v1/driver/me` (the `driver` object).
///
/// Field set follows `internal/model/user.go` `Driver` struct:
/// `user_id, first_name, last_name, photo_url, status, onboarding_status,
/// rating_summary, created_at, updated_at`.
class DriverProfile {
  final String userId;
  final String firstName;
  final String lastName;
  final String? photoUrl;
  final String status;
  final String onboardingStatus;
  final String ratingSummary;

  const DriverProfile({
    this.userId = '',
    this.firstName = '',
    this.lastName = '',
    this.photoUrl,
    this.status = 'offline',
    this.onboardingStatus = '',
    this.ratingSummary = '',
  });

  factory DriverProfile.fromJson(Map<String, dynamic> json) {
    return DriverProfile(
      userId: json['user_id'] as String? ?? '',
      firstName: json['first_name'] as String? ?? '',
      lastName: json['last_name'] as String? ?? '',
      photoUrl: json['photo_url'] as String?,
      status: json['status'] as String? ?? 'offline',
      onboardingStatus: json['onboarding_status'] as String? ?? '',
      ratingSummary: json['rating_summary'] as String? ?? '',
    );
  }

  String get fullName => '$firstName $lastName'.trim();

  bool get isOnline => status == 'online';
}