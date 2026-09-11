import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:driver_app/core/router/app_router.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/auth/auth_storage.dart';
import 'package:driver_app/core/api/api_client.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}

void main() {
  test('routerProvider creates a GoRouter', () {
    final container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(MockAuthStorage()),
        apiClientProvider.overrideWithValue(MockApiClient()),
      ],
    );
    addTearDown(() => container.dispose());

    final router = container.read(routerProvider);

    expect(router, isA<GoRouter>());
    expect(router.configuration, isNotNull);
  });
}