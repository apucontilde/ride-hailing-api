class ApiEndpoints {
  static const String prefix = '/api/v1';
  static const String login = '$prefix/auth/login';
  static const String register = '$prefix/auth/register';
  static const String forgotPassword = '$prefix/auth/forgot-password';
  static const String refreshToken = '$prefix/auth/refresh';
  static const String logout = '$prefix/auth/logout';
  static const String nearbyDrivers = '$prefix/geo/nearby-drivers';
  static const String riderLocation = '$prefix/geo/rider/location';
  static const String eta = '$prefix/geo/eta';
  static const String priceEstimate = '$prefix/estimates/price';
  static const String placesAutocomplete = '$prefix/places/autocomplete';
  static const String rides = '$prefix/rides';
  static const String currentRide = '$prefix/rides/current';
  static String rideById(String id) => '$prefix/rides/$id';
  static String cancelRide(String id) => '$prefix/rides/$id/cancel';
  static String changeDestination(String id) =>
      '$prefix/rides/$id/destination';
  static String rateRide(String id) => '$prefix/rides/$id/rate';
  static String tipRide(String id) => '$prefix/rides/$id/tip';
  static String receipt(String id) => '$prefix/rides/$id/receipt';
  static String driverLocation(String id) => '$prefix/drivers/$id/location';
  // GET, PUT and DELETE all address the same path, so one constant covers
  // all three (mirrors the driver's `driverMe`).
  static const String riderMe = '$prefix/rider/me';
  static const String riderMeStatus = '$prefix/rider/me/status';
  static const String paymentMethods = '$prefix/rider/payment-methods';
  // Paginated `{ratings, total, page, per_page, total_pages}` envelope of the
  // ride ids THIS rider has already rated — the seed for "don't re-prompt".
  static const String riderRatings = '$prefix/rider/ratings';
  static const String ridesHistory = '$prefix/rides/history';
  static const String navigationRoute = '$prefix/navigation/route';
  static const String sos = '$prefix/sos';

  // Device / push token registration (`POST /devices`, `DELETE /devices/:token`)
  static const String devices = '$prefix/devices';
  static String deviceUnregister(String token) =>
      '$prefix/devices/${Uri.encodeComponent(token)}';

  static const String ws = '/ws';
}
