import 'dart:async';

import 'package:rider_app/core/network/websocket_service.dart';

/// A [WebSocketService] whose event stream a test drives by hand.
///
/// Shared by the rider widget/provider suites that need to push `ride.updated`
/// and `driver.location` frames without a real socket. Not a `_test.dart` file,
/// so `flutter test` never runs it as a suite.
class FakeWebSocketService extends WebSocketService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;

  void emit(Map<String, dynamic> event) => _controller.add(event);

  void disposeController() => _controller.close();
}
