/// Elevation tokens for the shared surfaces.
///
/// The values reproduce what the screens already render: a `Card` sits at
/// Material's default, the trip-route banner was an explicit `elevation: 3`,
/// and sheets carry their lift through the shared [AppBottomSheet] shadow.
class AppElevation {
  AppElevation._();

  /// Default card lift.
  static const double card = 1;

  /// Bottom-sheet lift.
  static const double sheet = 8;

  /// Floating status/banner lift.
  static const double banner = 3;
}
