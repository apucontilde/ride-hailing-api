class AuthUser {
  final String id;
  final String email;
  final String? phone;
  final String role;
  final String? status;

  /// Name and photo live on the `riders` row, not the `users` row, so they are
  /// only populated when the caller hands [AuthUser.fromJson] the sibling
  /// `rider` object from `GET /rider/me`. Every response without a `rider` key
  /// (login, register) leaves them null.
  final String? firstName;
  final String? lastName;
  final String? photoUrl;

  const AuthUser({
    this.id = '',
    this.email = '',
    this.phone,
    this.role = 'rider',
    this.status,
    this.firstName,
    this.lastName,
    this.photoUrl,
  });

  /// [json] is the `user` object. [rider], when supplied, is the sibling
  /// `rider` object of a `GET /rider/me` envelope.
  factory AuthUser.fromJson(
    Map<String, dynamic> json, {
    Map<String, dynamic>? rider,
  }) {
    return AuthUser(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      phone: _textOrNull(json['phone']),
      role: json['role'] as String? ?? 'rider',
      status: json['status'] as String?,
      firstName: _textOrNull(rider?['first_name']),
      lastName: _textOrNull(rider?['last_name']),
      photoUrl: _textOrNull(rider?['photo_url']),
    );
  }

  /// Builds the user from just a role — used on cold start when only the
  /// access token is known and the role is inferred from an API response.
  factory AuthUser.fromRole(String role) {
    return AuthUser(role: role);
  }

  /// The `users`/`riders` columns are `NOT NULL DEFAULT ''`, so an unset name
  /// or photo arrives as an empty string. Normalizing to null here keeps
  /// `fullName` and the `hasPhoto` checks free of `isEmpty` special cases.
  static String? _textOrNull(Object? value) {
    if (value is! String) return null;
    return value.isEmpty ? null : value;
  }

  bool get isDriver => role == 'driver';

  /// Best available display name; empty when the rider has not set one.
  String get fullName {
    return [firstName, lastName]
        .whereType<String>()
        .where((part) => part.trim().isNotEmpty)
        .map((part) => part.trim())
        .join(' ');
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'phone': phone,
      'role': role,
      'status': status,
      'first_name': firstName,
      'last_name': lastName,
      'photo_url': photoUrl,
    };
  }
}
