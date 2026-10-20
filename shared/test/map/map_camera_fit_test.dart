import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

class MockMapController extends Mock implements MapController {}

void main() {
  late MockMapController controller;

  setUpAll(() {
    registerFallbackValue(
      CameraFit.bounds(
        bounds: LatLngBounds(const LatLng(0, 0), const LatLng(1, 1)),
      ),
    );
  });

  setUp(() {
    controller = MockMapController();
  });

  group('fitMapCamera', () {
    test('returns false and never fits with fewer than 2 points', () {
      expect(fitMapCamera(controller, const <LatLng>[]), isFalse);
      expect(fitMapCamera(controller, const [LatLng(9.93, -84.08)]), isFalse);

      verifyNever(() => controller.fitCamera(any()));
    });

    test('fits the bounds with the supplied padding and maxZoom', () {
      when(() => controller.fitCamera(any())).thenReturn(true);
      const padding = EdgeInsets.fromLTRB(10, 20, 30, 40);
      const points = [LatLng(9.92, -84.08), LatLng(9.95, -84.12)];

      final fitted = fitMapCamera(
        controller,
        points,
        padding: padding,
        maxZoom: 14,
      );

      expect(fitted, isTrue);
      final fit = verify(
        () => controller.fitCamera(captureAny()),
      ).captured.single as FitBounds;
      expect(fit.bounds, LatLngBounds.fromPoints(points));
      expect(fit.padding, padding);
      expect(fit.maxZoom, 14);
    });

    test('returns false when the camera is not attached', () {
      when(() => controller.fitCamera(any()))
          .thenThrow(StateError('camera not attached'));

      expect(
        fitMapCamera(controller, const [LatLng(1, 2), LatLng(3, 4)]),
        isFalse,
      );
    });

    test('treats a duplicate fit already in place as success', () {
      const points = [LatLng(9.92, -84.08), LatLng(9.95, -84.12)];
      final start = MapCamera.initialCamera(
        MapOptions(
          initialCenter: const LatLng(9.93, -84.10),
          initialZoom: 12,
        ),
      ).withNonRotatedSize(const Point<double>(800, 600));
      final target = CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(48),
        maxZoom: 16,
      ).fit(start);
      final alreadyFitted = start.withPosition(
        center: target.center,
        zoom: target.zoom,
      );

      when(() => controller.fitCamera(any())).thenReturn(false);
      when(() => controller.camera).thenReturn(alreadyFitted);

      expect(fitMapCamera(controller, points), isTrue);
    });
  });

  group('centerMapCamera', () {
    const point = LatLng(9.93, -84.08);

    test('moves to the point at the default zoom', () {
      when(() => controller.move(point, 16)).thenReturn(true);

      expect(centerMapCamera(controller, point), isTrue);

      verify(() => controller.move(point, 16)).called(1);
    });

    test('honors a supplied zoom', () {
      when(() => controller.move(point, 15)).thenReturn(true);

      expect(centerMapCamera(controller, point, zoom: 15), isTrue);

      verify(() => controller.move(point, 15)).called(1);
    });

    test('returns false when the move is rejected or throws', () {
      when(() => controller.move(point, 16)).thenReturn(false);
      expect(centerMapCamera(controller, point), isFalse);

      reset(controller);
      when(() => controller.move(point, 16))
          .thenThrow(StateError('camera not attached'));
      expect(centerMapCamera(controller, point), isFalse);
    });
  });
}
