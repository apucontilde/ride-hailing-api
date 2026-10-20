import 'package:flutter/foundation.dart';

/// True when the Home booking panel should expose its mouse-drag grab handle.
/// Web and desktop are pointer-first; mobile keeps the touch/scroll path.
bool shouldEnableSheetDragHandle({
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
  // Exhaustive over TargetPlatform (Dart 3): no trailing return needed.
}
