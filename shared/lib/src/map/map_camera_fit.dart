import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Fits [controller] to [points] with the shared camera-fit policy.
///
/// Returns `false` when there is nothing to fit (< 2 points) or the camera is
/// not attached yet; callers keep the fit step pending in that case.
bool fitMapCamera(
  MapController controller,
  List<LatLng> points, {
  EdgeInsets padding = const EdgeInsets.all(48),
  double maxZoom = 16,
}) {
  if (points.length < 2) return false;
  try {
    final cameraFit = CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      padding: padding,
      maxZoom: maxZoom,
    );
    if (controller.fitCamera(cameraFit)) return true;
    // `fitCamera` answers false when the camera is *already* at the fitted
    // position (a duplicate fit of the same bounds). That is still success:
    // the route is framed, so the locate cycle may advance.
    final target = cameraFit.fit(controller.camera);
    final current = controller.camera;
    return current.center == target.center && current.zoom == target.zoom;
  } catch (_) {
    // Camera not attached yet, or the fit was rejected; the caller retries.
    return false;
  }
}

/// Centers [controller] on [point] at [zoom].
///
/// Returns `false` when the camera is not attached or the move was rejected.
bool centerMapCamera(
  MapController controller,
  LatLng point, {
  double zoom = 16,
}) {
  try {
    return controller.move(point, zoom);
  } catch (_) {
    return false;
  }
}
