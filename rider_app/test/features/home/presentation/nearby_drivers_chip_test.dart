import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/presentation/nearby_drivers_chip.dart';

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
  });

  Future<void> pumpChip(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
        child: const MaterialApp(
          home: Scaffold(
            body: NearbyDriversChip(center: LatLng(9.93, -84.08)),
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('shows the nearby driver count', (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.nearbyDrivers,
      (server) => server.reply(200, {
        'drivers': [
          {'driver_id': 'd1', 'lat': 9.93, 'lng': -84.08},
          {'driver_id': 'd2', 'lat': 9.94, 'lng': -84.09},
        ],
      }),
    );

    await pumpChip(tester);

    expect(find.text('2 drivers nearby'), findsOneWidget);
  });

  testWidgets('uses the singular label for one driver', (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.nearbyDrivers,
      (server) => server.reply(200, {
        'drivers': [
          {'driver_id': 'd1', 'lat': 9.93, 'lng': -84.08},
        ],
      }),
    );

    await pumpChip(tester);

    expect(find.text('1 driver nearby'), findsOneWidget);
  });

  testWidgets('stays hidden on error', (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.nearbyDrivers,
      (server) => server.reply(500, {'message': 'boom'}),
    );

    await pumpChip(tester);

    expect(find.byType(Chip), findsNothing);
    expect(find.textContaining('nearby'), findsNothing);
  });

  testWidgets('stays hidden when no drivers are returned', (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.nearbyDrivers,
      (server) => server.reply(200, {'drivers': <dynamic>[]}),
    );

    await pumpChip(tester);

    expect(find.byType(Chip), findsNothing);
  });
}
