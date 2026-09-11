class AuthUser {
  final String id;
  final String email;
  final String? phone;
  final String role;
  final String? status;

  const AuthUser({
    this.id = '',
    this.email = '',
    this.phone,
    this.role = 'rider',
    this.status,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      role: json['role'] as String? ?? 'rider',
      status: json['status'] as String?,
    );
  }

  /// Builds the user from just a role — used on cold start when only the
  /// access token is known and the role is inferred from an API response.
  factory AuthUser.fromRole(String role) {
    return AuthUser(role: role);
  }

  bool get isDriver => role == 'driver';

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'phone': phone,
      'role': role,
      'status': status,
    };
  }
}