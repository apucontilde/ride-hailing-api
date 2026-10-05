import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/features/safety/data/safety_repository.dart';

/// F4: `api_client_test.dart` hand-built the feedback body, so it proved nothing
/// about what the app actually sends. These cases drive the REAL
/// [SafetyRepository] through a Dio mock adapter and pin the URL and the request
/// body of each call.
///
/// The `type: 'app_issue'` field is forward-compatible: the backend
/// `feedbackRequest` struct (`internal/handler/platform.go`) currently accepts
/// only `Message`/`RideID` and ignores `type`, but the app keeps sending it so
/// the wire contract is already correct when the backend starts reading it.
void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late List<String> paths;
  late List<Map<String, dynamic>> bodies;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
    paths = <String>[];
    bodies = <Map<String, dynamic>>[];
    apiClient.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          paths.add(options.path);
          final data = options.data;
          if (data is Map) {
            bodies.add(Map<String, dynamic>.from(data));
          }
          handler.next(options);
        },
      ),
    );
  });

  test('sendSos POSTs {lat, lng} to /api/v1/sos', () async {
    dioAdapter.onPost(
      ApiEndpoints.sos,
      (server) => server.reply(201, {'message': 'SOS alert received'}),
    );
    final repo = SafetyRepository(apiClient: apiClient);

    await repo.sendSos(lat: 9.9333, lng: -84.0833);

    expect(ApiEndpoints.sos, '/api/v1/sos');
    expect(paths.single, ApiEndpoints.sos);
    expect(bodies.single, {'lat': 9.9333, 'lng': -84.0833});
  });

  test('sendFeedback POSTs {type: app_issue, message} to /api/v1/feedback', () async {
    dioAdapter.onPost(
      ApiEndpoints.feedback,
      (server) => server.reply(201, {'message': 'feedback submitted'}),
    );
    final repo = SafetyRepository(apiClient: apiClient);

    await repo.sendFeedback(type: 'app_issue', message: 'App crashed');

    expect(ApiEndpoints.feedback, '/api/v1/feedback');
    expect(paths.single, ApiEndpoints.feedback);
    expect(bodies.single, {'type': 'app_issue', 'message': 'App crashed'});
  });
}
