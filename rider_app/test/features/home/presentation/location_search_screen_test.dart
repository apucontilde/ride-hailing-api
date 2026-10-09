import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/features/home/data/home_provider.dart';
import 'package:rider_app/features/home/presentation/location_search_screen.dart';
import 'package:rider_app/core/auth/auth_provider.dart';

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late List<Map<String, dynamic>> requests;

  const debounce = Duration(milliseconds: 300);

  setUp(() {
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
        apiClientProvider.overrideWithValue(apiClient),
        placeSearchDebounceProvider.overrideWithValue(debounce),
      ],
      child: MaterialApp(home: LocationSearchScreen(lat: lat, lng: lng)),
    );
  }

  testWidgets('shows the search field with a start-typing empty state',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    // The autofocus'd field carries the destination hint.
    expect(find.text('Search destinations...'), findsOneWidget);
    // No query yet: no place tiles render.
    expect(find.byType(ListTile), findsNothing);
    // With a bias center supplied (Home always supplies one) the blocking
    // "enable location" state must never render.
    expect(find.text('Enable location to search nearby'), findsNothing);
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

  testWidgets('the standardized leading AppBackButton pops the screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(apiClient),
          placeSearchDebounceProvider.overrideWithValue(debounce),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const LocationSearchScreen(
                        lat: 9.93,
                        lng: -84.08,
                      ),
                    ),
                  ),
                  child: const Text('open search'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open search'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBackButton), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();

    expect(find.byType(LocationSearchScreen), findsNothing);
    expect(find.text('open search'), findsOneWidget);
  });
}
