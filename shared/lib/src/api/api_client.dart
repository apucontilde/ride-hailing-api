import 'package:dio/dio.dart';
import 'api_exceptions.dart';

class ApiClient {
  late final Dio dio;
  String? _accessToken;
  Future<bool>? _refreshing;
  Future<bool> Function()? unauthorizedHandler;

  /// [baseUrl] is the app's backend base URL (each app wires its own
  /// `ApiConfig`), e.g. `http://localhost:8080`.
  ApiClient({required String baseUrl}) {
    dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    dio.interceptors.add(_createAuthInterceptor());
    dio.interceptors.add(_createErrorInterceptor());
  }

  void setToken(String? token) {
    _accessToken = token;
  }

  Interceptor _createAuthInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_accessToken != null) {
          options.headers['Authorization'] = 'Bearer $_accessToken';
        }
        handler.next(options);
      },
    );
  }

  Interceptor _createErrorInterceptor() {
    return InterceptorsWrapper(
      onError: (error, handler) async {
        final statusCode = error.response?.statusCode;
        final data = error.response?.data;
        final path = error.requestOptions.path;

        // AC-3: transparently refresh the access token on 401 and retry once.
        // Auth endpoints are excluded to avoid refresh loops. `/auth/logout`
        // belongs there too: a dead session answers 401, and refreshing it
        // only burns a round trip to fail and sign out a second time.
        final isAuthEndpoint = path.contains('/auth/login') ||
            path.contains('/auth/refresh') ||
            path.contains('/auth/logout');
        if (statusCode == 401 &&
            !isAuthEndpoint &&
            _refreshing == null &&
            unauthorizedHandler != null) {
          _refreshing = unauthorizedHandler!();
          try {
            final refreshed = await _refreshing;
            if (refreshed == true) {
              final op = error.requestOptions;
              op.headers['Authorization'] = 'Bearer $_accessToken';
              final response = await dio.fetch<dynamic>(op);
              handler.resolve(response);
              return;
            }
          } catch (_) {
            // Fall through to the original error.
          } finally {
            _refreshing = null;
          }
        }

        final mapped = mapStatusCodeToException(
          statusCode ?? 0,
          _messageFromData(statusCode, data, error.message),
        );
        // `DioException.error` is final, so surface the mapped ApiException by
        // replacing the exception instead of mutating it. App code catches
        // `on DioException` and reads `e.error is ApiException`.
        handler.next(
          DioException(
            requestOptions: error.requestOptions,
            response: error.response,
            type: error.type,
            error: mapped,
            message: error.message,
            stackTrace: error.stackTrace,
          ),
        );
      },
    );
  }

  String _messageFromData(int? statusCode, Object? data, String? fallback) {
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] != null) {
        return error['message'] as String;
      }
      if (data['message'] != null) return data['message'] as String;
    }
    if (data != null) return data.toString();
    return fallback ?? 'Unknown error';
  }
}