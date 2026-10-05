import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/features/home/data/home_provider.dart';
import 'package:rider_app/features/home/presentation/location_search_screen.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

void main() {
  late MockAuthStorage mockStorage;
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late List<Map<String, dynamic>> requests;

  const debounce = Duration(milliseconds: 300);

  setUp(() {
    mockStorage = MockAuthStorage();
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
    requests = <Map<String, dynamic>>[];
    apiClient.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(Map<String, dynamic>.from(options.queryParameters));
          handler.next(options);
        },
      ),
    );
    dioAdapter.onGet(
      '/api/v1/places/autocomplete',
      (server) => server.reply(200, {'places': <dynamic>[]}),
    );
  });

  Widget createTestWidget({double? lat = 9.93, double? lng = -84.08}) {
    return ProviderScope(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(apiClient),
        placeSearchDebounceProvider.overrideWithValue(debounce),
      ],
      child: MaterialApp(home: LocationSearchScreen(lat: lat, lng: lng)),
    );
  }

  testWidgets('shows search field', (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('debounces a keystroke stream into one request',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'c');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'ca');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'caf');
    await tester.pump(const Duration(milliseconds: 100));

    expect(requests, isEmpty);

    await tester.pump(debounce);
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single['q'], 'caf');
    expect(requests.single['radius'], 30000.0);
  });

  testWidgets('without coordinates no search request is made',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget(lat: null, lng: null));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'cafe');
    await tester.pump(debounce);
    await tester.pumpAndSettle();

    expect(requests, isEmpty);
  });
}
