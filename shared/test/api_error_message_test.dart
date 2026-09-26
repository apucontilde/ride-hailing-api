import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  // What `ApiClient`'s error interceptor actually produces: the backend's
  // `error.message` mapped to an exception, carried in `DioException.error`
  // (the field is final, so it is re-thrown wrapped rather than mutated).
  DioException asInterceptorThrows(int statusCode, String backendMessage) {
    final response = Response<dynamic>(
      requestOptions: RequestOptions(path: '/auth/register'),
      statusCode: statusCode,
      data: {
        'error': {'code': 'CONFLICT', 'message': backendMessage},
      },
    );
    final mapped = mapStatusCodeToException(statusCode, backendMessage);
    return DioException(
      requestOptions: RequestOptions(path: '/auth/register'),
      response: response,
      type: DioExceptionType.badResponse,
      error: mapped,
      // Dio's own field, which is the thing that must never reach the UI.
      message: 'This exception was thrown because the response has a status '
          'code of $statusCode but the status code included in the response '
          'is not a valid status code. ...',
    );
  }

  group('apiErrorMessage', () {
    test('returns the backend message for a mapped DioException', () {
      final error = asInterceptorThrows(409, 'email already registered');
      expect(apiErrorMessage(error, 'Registration failed.'),
          'email already registered');
    });

    test('prefers the backend message over Dio’s verbose description', () {
      // Regression: the register screen rendered `DioException.message`
      // verbatim, so a duplicate email produced a multi-paragraph English
      // wall ending in an MDN link instead of "email already registered".
      final error = asInterceptorThrows(409, 'email already registered');
      final message = apiErrorMessage(error, 'Registration failed.');
      expect(message, isNot(contains('This exception was thrown')));
      expect(message, isNot(contains('developer.mozilla.org')));
      expect(message.length, lessThan(80));
    });

    test('passes through a bare ApiException', () {
      expect(
        apiErrorMessage(ConflictException('phone already in use'), 'fallback'),
        'phone already in use',
      );
    });

    test('falls back when there is no server message', () {
      // Timeout / dropped connection: nothing to extract, so the caller's
      // friendly default is used rather than a leaked transport string.
      final timeout = DioException(
        requestOptions: RequestOptions(path: '/auth/login'),
        type: DioExceptionType.connectionTimeout,
        message: 'DioException [connection timeout]: ...',
      );
      expect(apiErrorMessage(timeout, 'Login failed.'), 'Login failed.');
    });

    test('falls back for an unrelated error type', () {
      expect(apiErrorMessage(ArgumentError('nope'), 'Something failed.'),
          'Something failed.');
    });

    test('never returns an empty message', () {
      final empty = DioException(
        requestOptions: RequestOptions(path: '/auth/login'),
        error: ApiException(''),
      );
      expect(apiErrorMessage(empty, 'Login failed.'), isNotEmpty);
    });
  });
}
