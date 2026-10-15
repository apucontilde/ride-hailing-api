import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/features/auth/presentation/forgot_password_screen.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
  });

  Widget createApp() {
    return ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(mockApiClient)],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/forgot-password',
          routes: [
            GoRoute(
              path: '/forgot-password',
              builder: (context, state) => const ForgotPasswordScreen(),
            ),
            GoRoute(
              path: '/login',
              builder: (context, state) =>
                  const Scaffold(body: Text('Login')),
            ),
            GoRoute(
              path: '/reset-password',
              builder: (context, state) =>
                  const Scaffold(body: Text('Reset')),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('submits the recovery request on Enter',
      (WidgetTester tester) async {
    when(() => mockDio.post(
          ApiEndpoints.forgotPassword,
          data: any(named: 'data'),
        )).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.forgotPassword),
        statusCode: 200,
        data: const {},
      ),
    );

    await tester.pumpWidget(createApp());
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).textInputAction,
      TextInputAction.done,
    );

    await tester.enterText(find.byType(TextFormField), 'test@test.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    verify(() => mockDio.post(
          ApiEndpoints.forgotPassword,
          data: {'email': 'test@test.com'},
        )).called(1);
    expect(find.textContaining('Recovery link sent'), findsOneWidget);
  });
}
