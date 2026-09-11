import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';
import '../api/endpoints.dart';

export 'package:ride_hailing_shared/ride_hailing_shared.dart'
    show WebSocketService;

final webSocketServiceProvider = Provider<WebSocketService>((ref) {
  return WebSocketService(baseUrl: ApiConfig.baseUrl, wsPath: ApiEndpoints.ws);
});