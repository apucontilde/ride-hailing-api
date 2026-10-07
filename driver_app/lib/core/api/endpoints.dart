/// Central registry of backend endpoints for the driver app.
///
/// Mirrors `rider_app/lib/core/api/endpoints.dart` and the driver contract in
/// `DRIVER_APP_PLAN.md` (§2). Every endpoint the app may call lives here so
/// screens/providers never hardcode paths.
class ApiEndpoints {
  static const String prefix = '/api/v1';

  // Auth (shared with rider app)
  static const String register = '$prefix/auth/register';
  static const String login = '$prefix/auth/login';
  static const String forgotPassword = '$prefix/auth/forgot-password';
  static const String resetPassword = '$prefix/auth/reset-password';
  static const String refreshToken = '$prefix/auth/refresh';
  static const String logout = '$prefix/auth/logout';

  // Driver onboarding & profile
  static const String driverRegister = '$prefix/driver/register';
  static const String driverMe = '$prefix/driver/me';
  static const String driverMeStatus = '$prefix/driver/me/status';
  static const String driverMeVehicle = '$prefix/driver/me/vehicle';
  static const String driverMeDocuments = '$prefix/driver/me/documents';
  static const String driverEarnings = '$prefix/driver/me/earnings';
  static const String driverRatings = '$prefix/driver/ratings';
  static const String driverEarningsWithdraw = '$prefix/driver/earnings/withdraw';

  // Driver rides
  static const String driverRidesCurrent = '$prefix/driver/rides/current';
  static const String driverRidesHistory = '$prefix/driver/rides/history';
  static const String driverRidesQueue = '$prefix/driver/rides/queue';
  static String driverRideById(String id) => '$prefix/driver/rides/$id';
  static String driverRideRider(String id) => '$prefix/driver/rides/$id/rider';
  static String driverRideAccept(String id) => '$prefix/driver/rides/$id/accept';
  static String driverRideDecline(String id) => '$prefix/driver/rides/$id/decline';
  static String driverRideStatus(String id) => '$prefix/driver/rides/$id/status';
  static String driverRideCancel(String id) => '$prefix/driver/rides/$id/cancel';
  static String driverRideRate(String id) => '$prefix/driver/rides/$id/rate';
  static String driverRideNotifyArrival(String id) => '$prefix/driver/rides/$id/notify-arrival';

  // Geo & navigation
  static const String driverLocation = '$prefix/geo/driver/location';
  static const String driverLocationBatch = '$prefix/geo/driver/location/batch';
  static const String navigationRoute = '$prefix/navigation/route';

  // Safety & support (ack-only backend)
  static const String sos = '$prefix/sos';
  static const String feedback = '$prefix/feedback';

  // Device / push token registration (`POST /devices`, `DELETE /devices/:token`)
  static const String devices = '$prefix/devices';
  static String deviceUnregister(String token) =>
      '$prefix/devices/${Uri.encodeComponent(token)}';

  static const String ws = '/ws';
}