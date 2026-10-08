import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/config.dart';

/// The shared [ApiClient] error-mapping suite lives in `rider_app` (both apps
/// re-export the same class), so this file keeps only the driver-owned surface:
/// the auth-header contract `setToken` installs on every request.
void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;

  /// Registers a request interceptor that records, through [captured], the
  /// headers the request actually leaves with — *after* the client's own auth
  /// interceptor has run.
  void captureRequestHeaders(
    ApiClient client,
    void Function(Map<String, dynamic>) captured,
  ) {
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured(Map<String, dynamic>.from(options.headers));
          handler.next(options);
        },
      ),
    );
  }

  setUp(() {
    apiClient = ApiClient(baseUrl: ApiConfig.baseUrl);
    dioAdapter = DioAdapter(dio: apiClient.dio);
  });

  group('ApiClient auth header', () {
    test('setToken adds the bearer header to requests', () async {
      apiClient.setToken('test-token-123');
      Map<String, dynamic>? sent;
      captureRequestHeaders(apiClient, (headers) => sent = headers);

      dioAdapter.onGet('/test', (server) => server.reply(200, {'ok': true}));

      final response = await apiClient.dio.get('/test');
      expect(response.statusCode, 200);
      expect(sent?['Authorization'], 'Bearer test-token-123');
    });

    test('setToken(null) removes the auth header from later requests', () async {
      apiClient.setToken('test-token');
      apiClient.setToken(null);
      Map<String, dynamic>? sent;
      captureRequestHeaders(apiClient, (headers) => sent = headers);

      dioAdapter.onGet('/test', (server) => server.reply(200, {'ok': true}));

      final response = await apiClient.dio.get('/test');
      expect(response.statusCode, 200);
      // The mock route alone would answer a leaked bearer happily, so assert on
      // the captured request: this fails if the header is still present.
      expect(sent, isNotNull);
      expect(sent!.containsKey('Authorization'), isFalse);
    });
  });
}