import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/core/api/api_exceptions.dart';

void main() {
  group('ApiException', () {
    test('creates with message and statusCode', () {
      final exception = ApiException('Not found', statusCode: 404);
      expect(exception.message, 'Not found');
      expect(exception.statusCode, 404);
      expect(exception.toString(), contains('404'));
      expect(exception.toString(), contains('Not found'));
    });

    test('creates with message only', () {
      final exception = ApiException('Generic error');
      expect(exception.message, 'Generic error');
      expect(exception.statusCode, isNull);
    });
  });

  group('UnauthorizedException', () {
    test('has statusCode 401 and default message', () {
      final exception = UnauthorizedException();
      expect(exception.statusCode, 401);
      expect(exception.message, 'Unauthorized');
    });

    test('accepts custom message', () {
      final exception = UnauthorizedException('Invalid token');
      expect(exception.message, 'Invalid token');
    });
  });

  group('NotFoundException', () {
    test('has statusCode 404', () {
      final exception = NotFoundException();
      expect(exception.statusCode, 404);
    });
  });

  group('ServerException', () {
    test('has statusCode 500', () {
      final exception = ServerException();
      expect(exception.statusCode, 500);
    });
  });

  group('BadRequestException', () {
    test('has statusCode 400', () {
      final exception = BadRequestException();
      expect(exception.statusCode, 400);
    });
  });

  group('ForbiddenException', () {
    test('has statusCode 403', () {
      final exception = ForbiddenException();
      expect(exception.statusCode, 403);
    });
  });

  group('mapStatusCodeToException', () {
    test('returns BadRequestException for 400', () {
      final result = mapStatusCodeToException(400, 'Bad input');
      expect(result, isA<BadRequestException>());
      expect(result.message, 'Bad input');
    });

    test('returns UnauthorizedException for 401', () {
      final result = mapStatusCodeToException(401, 'Invalid credentials');
      expect(result, isA<UnauthorizedException>());
    });

    test('returns ForbiddenException for 403', () {
      final result = mapStatusCodeToException(403, 'No access');
      expect(result, isA<ForbiddenException>());
    });

    test('returns NotFoundException for 404', () {
      final result = mapStatusCodeToException(404, 'Missing');
      expect(result, isA<NotFoundException>());
    });

    test('returns ServerException for 500', () {
      final result = mapStatusCodeToException(500, 'Server error');
      expect(result, isA<ServerException>());
    });

    test('returns generic ApiException for unknown status codes', () {
      final result = mapStatusCodeToException(418, "I'm a teapot");
      expect(result, isA<ApiException>());
      expect(result.statusCode, 418);
    });
  });
}
