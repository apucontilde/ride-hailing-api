import 'package:dio/dio.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// User-facing text for a failed API call, or [fallback] if there isn't one.
///
/// `ApiClient`'s error interceptor maps every non-2xx response to an
/// `ApiException` carrying the backend's own `error.message`, then re-throws it
/// as a `DioException` with that mapped exception in `DioException.error`
/// (the field is final, so it cannot be mutated in place).
///
/// Read the mapped exception, never `DioException.message`: Dio's own message
/// is a verbose multi-line description — "This exception was thrown because the
/// response has a status code of 409 but the status code included in the
/// response is not a valid status code…" — and rendering it put a wall of
/// English, punctuation and an MDN link in front of the user where "That email
/// is already registered" belongs.
///
/// [fallback] covers what the server cannot describe: a timeout, a dropped
/// connection, a malformed body, or a 200 with an empty `error.message` — an
/// empty string here would leave the error banner rendering nothing at all,
/// which reads as a button that silently does nothing.
String apiErrorMessage(Object error, String fallback) {
  final message = switch (error) {
    ApiException() => error.message,
    DioException(error: final Object? mapped) when mapped is ApiException =>
      mapped.message,
    _ => '',
  };
  return message.trim().isEmpty ? fallback : message;
}

class UnauthorizedException extends ApiException {
  UnauthorizedException([super.message = 'Unauthorized'])
      : super(statusCode: 401);
}

class NotFoundException extends ApiException {
  NotFoundException([super.message = 'Not found'])
      : super(statusCode: 404);
}

class ServerException extends ApiException {
  ServerException([super.message = 'Internal server error'])
      : super(statusCode: 500);
}

class BadRequestException extends ApiException {
  BadRequestException([super.message = 'Bad request'])
      : super(statusCode: 400);
}

class ForbiddenException extends ApiException {
  ForbiddenException([super.message = 'Forbidden'])
      : super(statusCode: 403);
}

class ConflictException extends ApiException {
  ConflictException([super.message = 'Conflict'])
      : super(statusCode: 409);
}

class ValidationException extends ApiException {
  ValidationException([super.message = 'Validation error'])
      : super(statusCode: 422);
}

class OfferExpiredException extends ConflictException {
  OfferExpiredException([super.message = 'Offer expired or ride taken']);
}

class RateLimitedException extends ApiException {
  RateLimitedException([super.message = 'Too many requests'])
      : super(statusCode: 429);
}

ApiException mapStatusCodeToException(int statusCode, String message) {
  return switch (statusCode) {
    400 => BadRequestException(message),
    401 => UnauthorizedException(message),
    403 => ForbiddenException(message),
    404 => NotFoundException(message),
    409 => ConflictException(message),
    422 => ValidationException(message),
    429 => RateLimitedException(message),
    500 => ServerException(message),
    _ => ApiException(message, statusCode: statusCode),
  };
}