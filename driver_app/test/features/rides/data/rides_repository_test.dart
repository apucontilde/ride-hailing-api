import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/features/rides/data/rides_repository.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late RidesRepository repo;

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    repo = RidesRepository(apiClient: mockApiClient);
  });

  group('RidesRepository', () {
    test('fetchRide parses full Ride', () async {
      when(() => mockDio.get(any())).thenAnswer((_) async => Response(
        requestOptions: RequestOptions(path: '/api/v1/driver/rides/r1'),
        statusCode: 200,
        data: {
          'ride': {
            'id': 'r1',
            'rider_id': 'u1',
            'status': 'pending',
            'pickup_lat': 9.93,
            'pickup_lng': -84.08,
            'pickup_address': 'Central Park',
            'dropoff_lat': 9.95,
            'dropoff_lng': -84.10,
            'dropoff_address': 'Airport',
            'total_fare': 12.50,
          }
        },
      ));

      final ride = await repo.fetchRide('r1');
      expect(ride.id, 'r1');
      expect(ride.status, 'pending');
      expect(ride.totalFare, 12.50);
    });

    test('acceptRideHttp throws OfferExpiredException on 409', () async {
      when(() => mockDio.post(any())).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/api/v1/driver/rides/r1/accept'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v1/driver/rides/r1/accept'),
          statusCode: 409,
          data: {'message': 'Offer expired'},
        ),
      ));

      expect(
        () => repo.acceptRideHttp('r1'),
        throwsA(isA<OfferExpiredException>()),
      );
    });

    group('currentRide', () {
      test('parses the active ride for the launch restore', () async {
        when(() => mockDio.get(any())).thenAnswer((_) async => Response(
              requestOptions:
                  RequestOptions(path: '/api/v1/driver/rides/current'),
              statusCode: 200,
              data: {
                'ride': {
                  'id': 'r1',
                  'rider_id': 'u1',
                  'status': 'in_progress',
                  'pickup_lat': 9.93,
                  'dropoff_lat': 9.95,
                  'total_fare': 7.5,
                }
              },
            ));

        final ride = await repo.currentRide();

        verify(() => mockDio.get('/api/v1/driver/rides/current')).called(1);
        expect(ride, isNotNull);
        expect(ride!.id, 'r1');
        expect(ride.status, 'in_progress');
        expect(ride.totalFare, 7.5);
      });

      test('returns null when the driver has no active ride', () async {
        when(() => mockDio.get(any())).thenAnswer((_) async => Response(
              requestOptions:
                  RequestOptions(path: '/api/v1/driver/rides/current'),
              statusCode: 200,
              data: {'ride': null},
            ));

        expect(await repo.currentRide(), isNull);
      });
    });
  });
}
