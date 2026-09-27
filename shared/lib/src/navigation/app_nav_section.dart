/// The fixed set of sidebar groups, in the order both apps render them.
///
/// Fixed on purpose. If an app could invent a section the two sidebars would
/// drift apart again, which is the entire reason this package exists: today the
/// rider lists five items flat under its header and the driver lists three, so
/// "which group is this in" has no answer in either app.
enum AppNavSection {
  account('ACCOUNT'),
  activity('ACTIVITY'),
  safety('SAFETY'),
  app('APP');

  const AppNavSection(this.title);

  /// Heading text exactly as displayed, already uppercased.
  ///
  /// Stored uppercased rather than transformed at render time so an app that
  /// overrides a heading gets the string it asked for, not a shoutier one.
  final String title;
}
