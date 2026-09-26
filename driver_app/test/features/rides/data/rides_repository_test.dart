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

    group('history', () {
      /// The server answers 200 even for an out-of-range `per_page` (it clamps
      /// and rewrites the value), so the echoed metadata is what the app trusts.
      Response historyResponse(Map<String, dynamic> data) => Response(
            requestOptions: RequestOptions(path: '/api/v1/driver/rides/history'),
            statusCode: 200,
            data: data,
          );

      test('parses the rides and the pagination metadata', () async {
        when(() => mockDio.get(any(),
            queryParameters: any(named: 'queryParameters'))).thenAnswer(
          (_) async => historyResponse({
            'rides': [
              {
                'id': 'r2',
                'rider_id': 'u1',
                'status': 'completed',
                'total_fare': 9.5,
                'completed_at': '2026-09-20T14:03:00Z',
              },
              {'id': 'r1', 'status': 'cancelled', 'cancelled_by': 'rider'},
            ],
            'total': 41,
            'page': 2,
            'per_page': 20,
            'total_pages': 3,
          }),
        );

        final page = await repo.history(page: 2);

        expect(page.rides, hasLength(2));
        expect(page.rides.first.id, 'r2');
        expect(page.rides.first.status, 'completed');
        expect(page.rides.first.totalFare, 9.5);
        expect(page.rides.first.completedAt, '2026-09-20T14:03:00Z');
        expect(page.rides.last.cancelledBy, 'rider');
        expect(page.total, 41);
        expect(page.page, 2);
        expect(page.perPage, 20);
        expect(page.totalPages, 3);
      });

      test('sends 1-based page/per_page, not limit/offset', () async {
        when(() => mockDio.get(any(),
            queryParameters: any(named: 'queryParameters'))).thenAnswer(
          (_) async => historyResponse({'rides': const [], 'total': 0}),
        );

        await repo.history(page: 3, perPage: 50);

        verify(() => mockDio.get(
              '/api/v1/driver/rides/history',
              queryParameters: {'page': 3, 'per_page': 50},
            )).called(1);
      });

      test('defaults to the first page of 20', () async {
        when(() => mockDio.get(any(),
            queryParameters: any(named: 'queryParameters'))).thenAnswer(
          (_) async => historyResponse({'rides': const [], 'total': 0}),
        );

        await repo.history();

        final captured = verify(() => mockDio.get(captureAny(),
            queryParameters: captureAny(named: 'queryParameters'))).captured;
        expect(captured[0], '/api/v1/driver/rides/history');
        expect(captured[1], {'page': 1, 'per_page': 20});
      });

      test('survives a response with no rides or metadata', () async {
        when(() => mockDio.get(any(),
            queryParameters: any(named: 'queryParameters'))).thenAnswer(
          (_) async => historyResponse(const {}),
        );

        final page = await repo.history();

        expect(page.rides, isEmpty);
        expect(page.total, 0);
        expect(page.page, 1);
        expect(page.perPage, 20);
        expect(page.totalPages, 1);
      });
    });

    group('rateRide', () {
      setUp(() {
        when(() => mockDio.post(any(), data: any(named: 'data')))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(
                    path: '/api/v1/driver/rides/r1/rate',
                  ),
                  statusCode: 200,
                  data: {'message': 'rating submitted'},
                ));
      });

      test('posts the score and the comment', () async {
        await repo.rateRide(rideId: 'r1', score: 5, comment: 'Great rider');

        final captured = verify(() => mockDio.post(
              captureAny(),
              data: captureAny(named: 'data'),
            )).captured;
        expect(captured[0], '/api/v1/driver/rides/r1/rate');
        // `score`, not `rating`: the server binds `score` with
        // `binding:"required"`, so a `rating` key would 400.
        expect(captured[1], {'score': 5, 'comment': 'Great rider'});
      });

      test('omits a blank comment rather than sending an empty string',
          () async {
        await repo.rateRide(rideId: 'r1', score: 3, comment: '   ');

        final captured = verify(() => mockDio.post(
              any(),
              data: captureAny(named: 'data'),
            )).captured;
        expect(captured.single, {'score': 3});
      });

      test('omits the comment key entirely when none is given', () async {
        await repo.rateRide(rideId: 'r1', score: 1);

        final captured = verify(() => mockDio.post(
              any(),
              data: captureAny(named: 'data'),
            )).captured;
        expect(captured.single, {'score': 1});
      });

      test('refuses a score outside 1..5 without touching the network',
          () async {
        await expectLater(
          () => repo.rateRide(rideId: 'r1', score: 0),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          () => repo.rateRide(rideId: 'r1', score: 6),
          throwsA(isA<ArgumentError>()),
        );

        verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
      });
    });
  });
}
