import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/core/platform/sheet_drag_handle.dart';

void main() {
  group('shouldEnableSheetDragHandle', () {
    test('web always enables, whatever the platform reports', () {
      for (final platform in TargetPlatform.values) {
        expect(
          shouldEnableSheetDragHandle(isWeb: true, platform: platform),
          isTrue,
          reason: 'web is pointer-first on $platform',
        );
      }
    });

    test('desktop enables', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(
          shouldEnableSheetDragHandle(isWeb: false, platform: platform),
          isTrue,
          reason: '$platform is pointer-first',
        );
      }
    });

    test('mobile stays inert', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          shouldEnableSheetDragHandle(isWeb: false, platform: platform),
          isFalse,
          reason: '$platform keeps the touch/scroll path',
        );
      }
    });
  });
}
