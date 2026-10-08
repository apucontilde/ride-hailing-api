import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  group('AppColors', () {
    test('the accent is the single seed', () {
      expect(AppColors.primary, appSeedColor);
      expect(appSeedColor, const Color(0xFF1A73E8));
    });

    test('route roles resolve exactly to the asserted Material colors', () {
      // The rider home/active-trip widget tests assert these identity values,
      // so this is a contract, not a preference.
      expect(AppColors.routeReady, Colors.blue);
      expect(AppColors.routeEstimate, Colors.grey);
    });

    test('semantic roles and the in-use tints are present', () {
      expect(AppColors.success, Colors.green);
      expect(AppColors.danger, Colors.red);
      expect(AppColors.info, Colors.blue);
      expect(AppColors.surface, Colors.white);
      expect(AppColors.estimateBanner, const Color(0xFFFFF8E1));
      expect(AppColors.errorBanner, const Color(0xFFFFEBEE));
      expect(AppColors.infoTint, const Color(0xFFE3F2FD));
      expect(AppColors.dangerTint, const Color(0xFFFFEBEE));
      expect(AppColors.warningTint, const Color(0xFFFFF8E1));
    });
  });

  group('AppRadii', () {
    test('the existing radii are unchanged and the new tokens are defined', () {
      expect(AppRadii.sm, 8);
      expect(AppRadii.md, 12);
      expect(AppRadii.lg, 16);
      expect(AppRadii.sheet, 20);
      expect(AppRadii.dialog, 28);
      expect(AppRadii.pill, 999);
      expect(AppRadii.handle, 2);
    });
  });

  group('AppTextStyles', () {
    test('role tokens carry their size/weight and keep the sidebar heading', () {
      expect(AppTextStyles.title.fontSize, 18);
      expect(AppTextStyles.title.fontWeight, FontWeight.w600);
      expect(AppTextStyles.subtitle.fontSize, 16);
      expect(AppTextStyles.body.fontSize, 14);
      expect(AppTextStyles.label.fontSize, 13);
      expect(AppTextStyles.caption.fontSize, 12);
      expect(AppTextStyles.fare.fontWeight, FontWeight.w600);
      expect(AppTextStyles.sidebarSectionHeading.fontSize, 11);
    });
  });

  group('AppElevation and AppMotion', () {
    test('expose the shared lift and timing tokens', () {
      // Pinned to the literals each token was measured at, so a value drift is
      // caught; `isPositive`/`isA<Duration>` would pass for any value.
      expect(AppElevation.card, 1);
      expect(AppElevation.sheet, 8);
      expect(AppElevation.banner, 3);
      expect(AppMotion.fast, const Duration(milliseconds: 150));
      expect(AppMotion.medium, const Duration(milliseconds: 250));
      expect(AppMotion.slow, const Duration(milliseconds: 400));
      expect(AppMotion.standard, Curves.easeInOut);
    });
  });
}
