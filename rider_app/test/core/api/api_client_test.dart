import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/api_exceptions.dart';
import 'package:rider_app/config.dart';

void main() {
  group('ApiClient', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;

    setUp(() {
      apiClient = ApiClient(baseUrl: ApiConfig.baseUrl);
      dioAdapter = DioAdapter(dio: apiClient.dio);
    });

    test('creates Dio instance with correct base URL', () {
      expect(apiClient.dio.options.baseUrl, ApiConfig.baseUrl);
      expect(apiClient.dio.options.connectTimeout,
          const Duration(seconds: 10));
      expect(apiClient.dio.options.receiveTimeout,
          const Duration(seconds: 10));
      expect(apiClient.dio.options.headers['Content-Type'], 'application/json');
    });

    test('setToken adds auth header to requests', () async {
      apiClient.setToken('test-token-123');

      dioAdapter.onGet(
        '/test',
        (server) => server.reply(200, {'ok': true}),
        headers: {'Authorization': 'Bearer test-token-123'},
      );

      final response = await apiClient.dio.get('/test');
      expect(response.statusCode, 200);
    });

    test('setToken(null) removes auth header', () async {
      apiClient.setToken('test-token');
      apiClient.setToken(null);

      dioAdapter.onGet(
        '/test',
        (server) => server.reply(200, {'ok': true}),
      );

      final response = await apiClient.dio.get('/test');
      expect(response.statusCode, 200);
    });

    test('error interceptor maps 401 to UnauthorizedException', () async {
      dioAdapter.onGet(
        '/test',
        (server) => server.reply(401, {'message': 'Invalid token'}),
      );

      try {
        await apiClient.dio.get('/test');
        fail('Expected exception');
      } on DioException catch (e) {
        expect(e.error, isA<UnauthorizedException>());
      }
    });

    test('error interceptor maps 404 to NotFoundException', () async {
      dioAdapter.onGet(
        '/test',
        (server) => server.reply(404, {'message': 'Not found'}),
      );

      try {
        await apiClient.dio.get('/test');
        fail('Expected exception');
      } on DioException catch (e) {
        expect(e.error, isA<NotFoundException>());
      }
    });

    test('error interceptor maps 500 to ServerException', () async {
      dioAdapter.onGet(
        '/test',
        (server) => server.reply(500, {'message': 'Server error'}),
      );

      try {
        await apiClient.dio.get('/test');
        fail('Expected exception');
      } on DioException catch (e) {
        expect(e.error, isA<ServerException>());
      }
    });

    test('401 triggers unauthorizedHandler refresh and retries with success', () async {
      var refreshed = 0;
      apiClient.unauthorizedHandler = () async {
        refreshed++;
        // The retried request must match a successful route, so register it
        // while refreshing (the adapter uses the last matching route).
        dioAdapter.onGet(
          '/test',
          (server) => server.reply(200, {'ok': true}),
        );
        return true;
      };

      dioAdapter.onGet(
        '/test',
        (server) => server.reply(401, {'message': 'Invalid token'}),
      );

      final response = await apiClient.dio.get('/test');

      expect(response.statusCode, 200);
      expect(refreshed, 1);
    });

    test('401 with unauthorizedHandler failing keeps the original error', () async {
      apiClient.unauthorizedHandler = () async => false;

      dioAdapter.onGet(
        '/test',
        (server) => server.reply(401, {'message': 'Invalid token'}),
      );

      try {
        await apiClient.dio.get('/test');
        fail('Expected exception');
      } on DioException catch (e) {
        expect(e.error, isA<UnauthorizedException>());
      }
    });

    test('401 on the refresh endpoint does not loop back into refresh', () async {
      dioAdapter.onGet(
        '/api/v1/auth/refresh',
        (server) => server.reply(401, {'message': 'Refresh expired'}),
      );

      try {
        await apiClient.dio.get('/api/v1/auth/refresh');
        fail('Expected exception');
      } on DioException catch (e) {
        expect(e.error, isA<UnauthorizedException>());
      }
    });

    test('error interceptor maps 400 to BadRequestException', () async {
      dioAdapter.onGet(
        '/test',
        (server) => server.reply(400, {'message': 'Bad input'}),
      );

      try {
        await apiClient.dio.get('/test');
        fail('Expected exception');
      } on DioException catch (e) {
        expect(e.error, isA<BadRequestException>());
      }
    });
  });
}
