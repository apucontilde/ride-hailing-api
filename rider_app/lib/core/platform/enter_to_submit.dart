import 'package:flutter/foundation.dart';

/// True when pressing Enter in a single-line form field should submit the
/// form. Web and desktop are keyboard-first; mobile alone must not submit
/// from the Enter key, so it keeps the button as its submit affordance.
bool shouldSubmitOnEnter({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return true;
  switch (platform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}
