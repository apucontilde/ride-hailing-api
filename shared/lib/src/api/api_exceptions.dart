class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

  @override
  String toString() => 'ApiException($statusCode): $message';
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