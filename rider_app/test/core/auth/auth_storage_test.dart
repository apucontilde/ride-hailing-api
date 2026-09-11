import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/core/auth/auth_storage.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockFlutterSecureStorage mockStorage;
  late AuthStorage authStorage;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    authStorage = AuthStorage(storage: mockStorage);
  });

  group('AuthStorage', () {
    test('saveAccessToken writes to secure storage', () async {
      when(() => mockStorage.write(
          key: any(named: 'key'), value: any(named: 'value')))
          .thenAnswer((_) async {});

      await authStorage.saveAccessToken('token-123');

      verify(() => mockStorage.write(
          key: 'access_token', value: 'token-123')).called(1);
    });

    test('saveRefreshToken writes to secure storage', () async {
      when(() => mockStorage.write(
          key: any(named: 'key'), value: any(named: 'value')))
          .thenAnswer((_) async {});

      await authStorage.saveRefreshToken('refresh-123');

      verify(() => mockStorage.write(
          key: 'refresh_token', value: 'refresh-123')).called(1);
    });

    test('getAccessToken reads from secure storage', () async {
      when(() => mockStorage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'stored-token');

      final token = await authStorage.getAccessToken();

      expect(token, 'stored-token');
      verify(() => mockStorage.read(key: 'access_token')).called(1);
    });

    test('getAccessToken returns null when no token stored', () async {
      when(() => mockStorage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

      final token = await authStorage.getAccessToken();

      expect(token, isNull);
    });

    test('getRefreshToken reads from secure storage', () async {
      when(() => mockStorage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'stored-refresh');

      final token = await authStorage.getRefreshToken();

      expect(token, 'stored-refresh');
      verify(() => mockStorage.read(key: 'refresh_token')).called(1);
    });

    test('clearTokens deletes both tokens', () async {
      when(() => mockStorage.delete(key: any(named: 'key')))
          .thenAnswer((_) async {});

      await authStorage.clearTokens();

      verify(() => mockStorage.delete(key: 'access_token')).called(1);
      verify(() => mockStorage.delete(key: 'refresh_token')).called(1);
    });

    test('saveTokens saves both access and refresh tokens', () async {
      when(() => mockStorage.write(
          key: any(named: 'key'), value: any(named: 'value')))
          .thenAnswer((_) async {});

      await authStorage.saveTokens(
        accessToken: 'access-123',
        refreshToken: 'refresh-456',
      );

      verify(() => mockStorage.write(
          key: 'access_token', value: 'access-123')).called(1);
      verify(() => mockStorage.write(
          key: 'refresh_token', value: 'refresh-456')).called(1);
    });
  });
}
