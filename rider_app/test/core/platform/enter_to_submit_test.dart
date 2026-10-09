import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/core/platform/enter_to_submit.dart';

void main() {
  group('shouldSubmitOnEnter', () {
    test('web always submits, whatever the platform reports', () {
      for (final platform in TargetPlatform.values) {
        expect(
          shouldSubmitOnEnter(isWeb: true, platform: platform),
          isTrue,
          reason: 'web wins on $platform',
        );
      }
    });

    test('desktop submits', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(
          shouldSubmitOnEnter(isWeb: false, platform: platform),
          isTrue,
          reason: '$platform is keyboard-first',
        );
      }
    });

    test('mobile does not submit', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          shouldSubmitOnEnter(isWeb: false, platform: platform),
          isFalse,
          reason: '$platform keeps the button as its submit affordance',
        );
      }
    });
  });
}
