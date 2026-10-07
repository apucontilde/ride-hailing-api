import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/features/rides/data/rated_rides_provider.dart';
import 'package:driver_app/features/rides/data/rides_repository.dart';

/// One row of `GET /driver/ratings`, exactly as `RatingItem` serialises it
/// (`internal/handler/responses.go:99-106`). `comment` is a plain string on the
/// wire, never null, and `rater_role` is pinned to `driver` by the handler.
Map<String, dynamic> ratingRow(String rideId, {int score = 5}) => {
      'id': 'rating-$rideId',
      'ride_id': rideId,
      'rater_role': 'driver',
      'score': score,
      'comment': '',
      'created_at': '2026-09-01T12:00:00Z',
    };

/// The pagination envelope of `GetRatings` (`internal/handler/ride.go:455`).
Map<String, dynamic> ratingsBody(
  List<Map<String, dynamic>> rows, {
  required int totalPages,
}) =>
    {
      'ratings': rows,
      'total': rows.length,
      'per_page': ratedRidesPageSize,
      'total_pages': totalPages,
    };

/// Records what the provider actually asked the server for.
class RequestLog {
  final List<String> requests = <String>[];
  final List<Map<String, dynamic>> queries = <Map<String, dynamic>>[];

  void attach(Dio dio) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add('${options.method} ${options.path}');
          queries.add(Map<String, dynamic>.from(options.queryParameters));
          handler.next(options);
        },
      ),
    );
  }
}

/// A `Dio` adapter that takes the request and never answers it. Stands in for
/// the real IO adapter, which arms a connect/receive timer per request — the
/// timers a torn-down widget tree would otherwise leave pending.
class HangingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    final completer = Completer<ResponseBody>();
    cancelFuture?.then((_) {
      cancelled = true;
      // A real adapter surfaces cancellation as a DioException; matching that
      // is what proves the provider survives an aborted load.
      if (!completer.isCompleted) {
        completer.completeError(
          DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            error: 'cancelled',
          ),
        );
      }
    });
    return completer.future;
  }

  @override
  void close({bool force = false}) {}
}

/// Watches the provider so its build runs; renders nothing.
class _WatchRatedRides extends ConsumerWidget {
  const _WatchRatedRides();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(ratedRidesProvider);
    return const SizedBox.shrink();
  }
}

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late RequestLog log;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
    log = RequestLog()..attach(apiClient.dio);
  });

  ProviderContainer containerWith([ApiClient? client]) => ProviderContainer(
        overrides: [
          ridesRepositoryProvider.overrideWith(
            (ref) => RidesRepository(apiClient: client ?? apiClient),
          ),
        ],
      );

  /// The resolved tri-state for one ride. Reads the future, so a truncated walk
  /// that must consult the server is awaited to completion.
  Future<RatingStatus> status(ProviderContainer container, String rideId) =>
      container.read(ratedRideStatusProvider(rideId).future);

  /// The status a widget would render *right now*: an unresolved (loading)
  /// future falls back to [RatingStatus.unknown], which is what the UI does.
  RatingStatus rendered(ProviderContainer container, String rideId) =>
      container.read(ratedRideStatusProvider(rideId)).valueOrNull ??
      RatingStatus.unknown;

  /// Answers `/driver/ratings` with `bodies[page - 1]` — one fixture per page,
  /// so a provider that stops at page 1 is visible in the resulting set.
  void serveRatings(List<Map<String, dynamic>> bodies) {
    dioAdapter.onGet(
      ApiEndpoints.driverRatings,
      (server) => server.replyCallback(200, (options) {
        final page =
            (options.queryParameters['page'] as num?)?.toInt() ?? bodies.length;
        return {...bodies[page - 1], 'page': page};
      }),
    );
  }

  /// Like [serveRatings], but the answer waits on [gate], which makes the
  /// in-flight window observable from a test.
  void gateRatings(Completer<void> gate, Map<String, dynamic> body) {
    dioAdapter.onGet(
      ApiEndpoints.driverRatings,
      (server) => server.replyCallbackAsync(200, (options) async {
        await gate.future;
        final page = (options.queryParameters['page'] as num?)?.toInt() ?? 1;
        return {...body, 'page': page};
      }),
    );
  }

  group('loading', () {
    test('build() GETs /driver/ratings and fills the set from the response',
        () async {
      serveRatings([
        ratingsBody([ratingRow('r1'), ratingRow('r2')], totalPages: 2),
        ratingsBody([ratingRow('r3')], totalPages: 2),
      ]);
      final container = containerWith();
      addTearDown(container.dispose);

      final loaded = await container.read(ratedRidesProvider.future);

      // The wire contract, pinned: one GET per page, the endpoint the app
      // actually calls, `per_page` inside the range the server accepts.
      expect(log.requests, [
        'GET ${ApiEndpoints.driverRatings}',
        'GET ${ApiEndpoints.driverRatings}',
      ]);
      expect(log.queries, [
        {'page': 1, 'per_page': ratedRidesPageSize},
        {'page': 2, 'per_page': ratedRidesPageSize},
      ]);
      expect(ApiEndpoints.driverRatings, '/api/v1/driver/ratings');
      // Every page is merged, not just the first.
      expect(loaded.rideIds, {'r1', 'r2', 'r3'});
      expect(loaded.statusOf('r1'), RatingStatus.rated);
      expect(loaded.statusOf('r3'), RatingStatus.rated);
      // Loaded-and-absent is the only state that may prompt.
      expect(loaded.statusOf('r9'), RatingStatus.unrated);
      expect(loaded.statusOf('r9').canPrompt, isTrue);
      // No ride id, nothing known.
      expect(loaded.statusOf(''), RatingStatus.unknown);

      expect(await status(container, 'r1'), RatingStatus.rated);
      expect(await status(container, 'r9'), RatingStatus.unrated);
    });

    test('a single-page response issues exactly one request', () async {
      serveRatings([
        ratingsBody([ratingRow('r1')], totalPages: 1),
      ]);
      final container = containerWith();
      addTearDown(container.dispose);

      await container.read(ratedRidesProvider.future);

      expect(log.queries, hasLength(1));
    });

    test('a row without a ride id is dropped, not counted as rated', () async {
      serveRatings([
        ratingsBody([
          ratingRow('r1'),
          {'id': 'x', 'ride_id': '', 'rater_role': 'driver', 'score': 4},
        ], totalPages: 1),
      ]);
      final container = containerWith();
      addTearDown(container.dispose);

      final loaded = await container.read(ratedRidesProvider.future);

      expect(loaded.rideIds, {'r1'});
    });

    test('while the request is in flight every ride is unknown', () async {
      final gate = Completer<void>();
      gateRatings(gate, ratingsBody([ratingRow('r1')], totalPages: 1));
      final container = containerWith();
      addTearDown(container.dispose);

      // Read without awaiting: the state is loading, and nothing may claim a
      // ride is unrated while it is.
      expect(container.read(ratedRidesProvider).isLoading, isTrue);
      expect(rendered(container, 'r1'), RatingStatus.unknown);
      expect(rendered(container, 'r1').canPrompt, isFalse);

      gate.complete();
      await container.read(ratedRidesProvider.future);

      expect(await status(container, 'r1'), RatingStatus.rated);
    });
  });

  group('failure', () {
    test('a failed load is an error state and never claims unrated', () async {
      dioAdapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.reply(500, {
          'error': {'code': 'INTERNAL', 'message': 'failed to load ratings'},
        }),
      );
      final container = containerWith();
      addTearDown(container.dispose);

      await expectLater(
        container.read(ratedRidesProvider.future),
        throwsA(isA<DioException>()),
      );

      expect(container.read(ratedRidesProvider).hasError, isTrue);
      // The whole point: a failed list is unknown, never "nothing rated".
      expect(await status(container, 'r1'), RatingStatus.unknown);
      expect((await status(container, 'r1')).canPrompt, isFalse);
    });

    test('the retry a UI affordance calls re-fetches the list', () async {
      // The server is down for the first load...
      dioAdapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.reply(500, {
          'error': {'code': 'INTERNAL', 'message': 'boom'},
        }),
      );
      final container = containerWith();
      addTearDown(container.dispose);

      await container
          .read(ratedRidesProvider.future)
          .then((_) {}, onError: (Object _) {});
      expect(container.read(ratedRidesProvider).hasError, isTrue);
      expect(await status(container, 'r1'), RatingStatus.unknown);

      // ...and back up when the driver hits Retry.
      serveRatings([
        ratingsBody([ratingRow('r1')], totalPages: 1),
      ]);
      await container.read(ratedRidesProvider.notifier).refresh();

      expect(log.queries, hasLength(2), reason: 'retry re-requested');
      expect(container.read(ratedRidesProvider).hasError, isFalse);
      expect(await status(container, 'r1'), RatingStatus.rated);
    });

    test('a refresh keeps the loaded set readable while it runs', () async {
      var body = ratingsBody([ratingRow('r1')], totalPages: 1);
      var gate = Completer<void>()..complete();
      dioAdapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.replyCallbackAsync(200, (options) async {
          await gate.future;
          final page = (options.queryParameters['page'] as num?)?.toInt() ?? 1;
          return {...body, 'page': page};
        }),
      );
      final container = containerWith();
      addTearDown(container.dispose);

      await container.read(ratedRidesProvider.future);
      expect(await status(container, 'r1'), RatingStatus.rated);
      expect(await status(container, 'r2'), RatingStatus.unrated);

      // Second load is held open, so the refreshing window is observable.
      gate = Completer<void>();
      body = ratingsBody([ratingRow('r1'), ratingRow('r2')], totalPages: 1);
      final pending = container.read(ratedRidesProvider.notifier).refresh();

      expect(container.read(ratedRidesProvider).isLoading, isTrue);
      expect(
        container.read(ratedRidesProvider).valueOrNull?.rideIds,
        {'r1'},
        reason: 'a refresh must not blank what is already known',
      );
      // The previous resolved answer stays readable while the refresh runs.
      expect(rendered(container, 'r1'), RatingStatus.rated);

      gate.complete();
      await pending;

      expect(await status(container, 'r2'), RatingStatus.rated);
    });
  });

  group('markRated', () {
    test('is optimistic, additive and idempotent once the list is loaded',
        () async {
      serveRatings([
        ratingsBody([ratingRow('r1')], totalPages: 1),
      ]);
      final container = containerWith();
      addTearDown(container.dispose);
      await container.read(ratedRidesProvider.future);

      final before = container.read(ratedRidesProvider);
      container.read(ratedRidesProvider.notifier).markRated('r2');

      final after = container.read(ratedRidesProvider);
      // Reacted immediately, without a refetch...
      expect(after.valueOrNull?.rideIds, {'r1', 'r2'});
      expect(await status(container, 'r2'), RatingStatus.rated);
      // ...and did not erase what was already loaded (the set it replaces used
      // to be rebuilt from scratch).
      expect(await status(container, 'r1'), RatingStatus.rated);
      expect(identical(before, after), isFalse);

      // Idempotent: marking the same ride again writes no new state at all.
      container.read(ratedRidesProvider.notifier).markRated('r2');
      expect(identical(container.read(ratedRidesProvider), after), isTrue);

      // Neither mark went to the network.
      expect(log.queries, hasLength(1));
    });

    test('does not turn a loading list into a loaded one', () async {
      final gate = Completer<void>();
      // A response requested before the POST landed: it does not list r9.
      gateRatings(gate, ratingsBody([ratingRow('r1')], totalPages: 1));
      final container = containerWith();
      addTearDown(container.dispose);

      container.read(ratedRidesProvider);
      container.read(ratedRidesProvider.notifier).markRated('r9');

      // Still loading — not a one-element "loaded" set, which would make every
      // other ride read as unrated.
      expect(container.read(ratedRidesProvider).isLoading, isTrue);
      expect(container.read(ratedRidesProvider).valueOrNull, isNull);
      expect(rendered(container, 'r9'), RatingStatus.unknown);

      gate.complete();
      await container.read(ratedRidesProvider.future);

      // The optimistic mark survives a response that predates it.
      expect(
        container.read(ratedRidesProvider).valueOrNull?.rideIds,
        {'r1', 'r9'},
      );
      expect(await status(container, 'r9'), RatingStatus.rated);
    });

    test('survives a refresh, which re-reads the server list', () async {
      serveRatings([
        ratingsBody([ratingRow('r1')], totalPages: 1),
      ]);
      final container = containerWith();
      addTearDown(container.dispose);
      await container.read(ratedRidesProvider.future);

      container.read(ratedRidesProvider.notifier).markRated('r9');
      await container.read(ratedRidesProvider.notifier).refresh();

      expect(log.queries, hasLength(2));
      expect(
        container.read(ratedRidesProvider).valueOrNull?.rideIds,
        {'r1', 'r9'},
        reason: 'a refetch that predates the POST must not lose the mark',
      );
    });

    test('an empty ride id is ignored', () async {
      serveRatings([
        ratingsBody([ratingRow('r1')], totalPages: 1),
      ]);
      final container = containerWith();
      addTearDown(container.dispose);
      await container.read(ratedRidesProvider.future);

      container.read(ratedRidesProvider.notifier).markRated('');

      expect(container.read(ratedRidesProvider).valueOrNull?.rideIds, {'r1'});
      expect(await status(container, ''), RatingStatus.unknown);
    });
  });

  group('the truncated walk resolves one ride with ride_id', () {
    const beyondCap = '11111111-1111-1111-1111-111111111111';

    /// The seed walk the server repeats for every page when the driver has more
    /// than the [ratedRidesMaxPages] ceiling allows: the walk stops at the
    /// bound and the set is marked truncated.
    Map<String, dynamic> truncatedSeedBody(int page) => {
          'ratings': [ratingRow('r1')],
          'total': 1001,
          'page': page,
          'per_page': ratedRidesPageSize,
          'total_pages': 21,
        };

    Map<String, dynamic> emptyFilterBody(String rideId) => {
          'ratings': <dynamic>[],
          'total': 0,
          'page': 1,
          'per_page': 20,
          'total_pages': 0,
        };

    /// Answers the seed walk with [truncatedSeedBody] and the `ride_id` filter
    /// (recognised by the query key) with [filterBody].
    void serveTruncatedSeedWithFilter(
      Map<String, dynamic> Function(String rideId) filterBody, {
      void Function(Map<String, dynamic> query)? onFilter,
    }) {
      dioAdapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.replyCallback(200, (options) {
          final params = Map<String, dynamic>.from(options.queryParameters);
          if (params.containsKey('ride_id')) {
            onFilter?.call(params);
            return filterBody(params['ride_id'] as String);
          }
          return truncatedSeedBody((params['page'] as num?)?.toInt() ?? 1);
        }),
      );
    }

    test('a rated ride beyond the page cap is still rated [the bug]', () async {
      final filterQueries = <Map<String, dynamic>>[];
      serveTruncatedSeedWithFilter(
        (rideId) => {
          'ratings': [ratingRow(rideId)],
          'total': 1,
          'page': 1,
          'per_page': 20,
          'total_pages': 1,
        },
        onFilter: filterQueries.add,
      );
      final container = containerWith();
      addTearDown(container.dispose);

      final loaded = await container.read(ratedRidesProvider.future);

      // The walk stopped at the ceiling short of what the server reported...
      expect(loaded.truncated, isTrue);
      // ...so absence from the loaded set is not evidence of "unrated"...
      expect(loaded.statusOf(beyondCap), RatingStatus.unknown);

      // ...and the per-ride filter gives the definitive answer.
      final resolved = await status(container, beyondCap);
      expect(resolved, RatingStatus.rated);
      expect(resolved.canPrompt, isFalse);
      // The filter asks for exactly this ride, nothing else.
      expect(filterQueries, [
        {'ride_id': beyondCap}
      ]);
    });

    test('an unrated ride beyond the cap stays unrated', () async {
      final filterQueries = <Map<String, dynamic>>[];
      serveTruncatedSeedWithFilter(
        emptyFilterBody,
        onFilter: filterQueries.add,
      );
      final container = containerWith();
      addTearDown(container.dispose);

      await container.read(ratedRidesProvider.future);

      final resolved = await status(container, beyondCap);
      expect(resolved, RatingStatus.unrated);
      expect(resolved.canPrompt, isTrue);
      expect(filterQueries.single, {'ride_id': beyondCap});
    });

    test('a ride the truncated window already lists needs no filter', () async {
      var filterCalls = 0;
      serveTruncatedSeedWithFilter((rideId) {
        filterCalls++;
        return emptyFilterBody(rideId);
      });
      final container = containerWith();
      addTearDown(container.dispose);

      await container.read(ratedRidesProvider.future);

      expect(await status(container, 'r1'), RatingStatus.rated);
      expect(filterCalls, 0,
          reason: 'a ride in the loaded window is already conclusive');
    });

    test('a complete walk answers unrated without any filter request', () async {
      serveRatings([
        ratingsBody([ratingRow('r1')], totalPages: 1),
      ]);
      final container = containerWith();
      addTearDown(container.dispose);

      await container.read(ratedRidesProvider.future);

      expect(await status(container, 'r9'), RatingStatus.unrated);
      expect(
        log.queries.any((q) => q.containsKey('ride_id')),
        isFalse,
        reason: 'a complete set is already a definitive answer',
      );
    });

    test('a 422 on the per-ride filter is unknown, never unrated', () async {
      // A dedicated client with the *default* matcher: the suite-wide
      // `UrlRequestMatcher` ignores query parameters, so it cannot tell the
      // seed walk from the `ride_id` filter. The default matcher can, which is
      // what lets a query-specific 422 handler answer only the filter.
      final client = ApiClient(baseUrl: 'http://localhost:8080');
      final adapter = DioAdapter(dio: client.dio);
      adapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.replyCallback(200, (options) {
          return truncatedSeedBody(
            (options.queryParameters['page'] as num?)?.toInt() ?? 1,
          );
        }),
      );
      adapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.reply(422, {
          'error': {'code': 'VALIDATION_ERROR', 'message': 'invalid ride_id'},
        }),
        queryParameters: {'ride_id': beyondCap},
      );
      final container = containerWith(client);
      addTearDown(container.dispose);

      await container.read(ratedRidesProvider.future);

      final resolved = await status(container, beyondCap);
      expect(resolved, RatingStatus.unknown);
      expect(resolved.canPrompt, isFalse);
    });

    test('a failed per-ride filter is unknown, never unrated', () async {
      final client = ApiClient(baseUrl: 'http://localhost:8080');
      final adapter = DioAdapter(dio: client.dio);
      adapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.replyCallback(200, (options) {
          return truncatedSeedBody(
            (options.queryParameters['page'] as num?)?.toInt() ?? 1,
          );
        }),
      );
      adapter.onGet(
        ApiEndpoints.driverRatings,
        (server) => server.reply(500, {
          'error': {'code': 'INTERNAL', 'message': 'failed to load ratings'},
        }),
        queryParameters: {'ride_id': beyondCap},
      );
      final container = containerWith(client);
      addTearDown(container.dispose);

      await container.read(ratedRidesProvider.future);

      final resolved = await status(container, beyondCap);
      expect(resolved, RatingStatus.unknown);
      expect(resolved.canPrompt, isFalse);
    });
  });

  group('teardown', () {
    /// A tree whose only transport is [adapter], pumped for one frame —
    /// the fetch is in flight and is never awaited.
    Future<void> pumpWatcher(WidgetTester tester, HangingAdapter adapter) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ridesRepositoryProvider.overrideWith(
              (ref) => RidesRepository(
                // Never a real base URL: the only transport is [adapter].
                apiClient: ApiClient(baseUrl: 'http://unused.invalid')
                  ..dio.httpClientAdapter = adapter,
              ),
            ),
          ],
          child: const MaterialApp(home: _WatchRatedRides()),
        ),
      );
      // A duration, not a bare `pump()`: Dio wraps every interceptor step in a
      // zero-duration `Timer`, which `pump()` (microtasks only) never fires.
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets('disposing cancels the in-flight request', (tester) async {
      final adapter = HangingAdapter();

      await pumpWatcher(tester, adapter);

      expect(adapter.requests, hasLength(1));
      expect(adapter.cancelled, isFalse);

      // Swap the tree out with the request open: it must be cancelled rather
      // than left holding Dio's per-request timers.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(adapter.cancelled, isTrue);
      // And the cancellation is not rethrown into a zone nobody listens to.
      expect(tester.takeException(), isNull);
    });
  });
}
