import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/router/post_auth_route.dart';
import 'package:rider_app/features/home/data/current_ride_provider.dart';

AuthState _auth({bool authenticated = true}) => AuthState(
      status: authenticated ? AuthStatus.authenticated : AuthStatus.unauthenticated,
    );

CurrentRideState _ride(String? status, {bool needsRestore = false}) =>
    CurrentRideState(status: status, needsRestore: needsRestore);

void main() {
  group('resolvePostAuthRoute', () {
    test('unauthenticated always resolves to /login', () {
      expect(
        resolvePostAuthRoute(_auth(authenticated: false), _ride('accepted')),
        '/login',
      );
    });

    test('pending restores to the matching screen', () {
      expect(
        resolvePostAuthRoute(_auth(), _ride('pending')),
        '/driver-matching',
      );
    });

    test('active statuses restore to the active ride', () {
      for (final status in ['accepted', 'driver_arrived', 'in_progress']) {
        expect(
          resolvePostAuthRoute(_auth(), _ride(status)),
          '/active-ride',
          reason: '$status must restore to the active trip',
        );
      }
    });

    test('no ride and terminal statuses go home', () {
      for (final status in [null, 'completed', 'cancelled', 'no_driver_available']) {
        expect(
          resolvePostAuthRoute(_auth(), _ride(status)),
          '/home',
          reason: '$status must not restore',
        );
      }
    });
  });

  group('resolveRedirect — bootstrap gate', () {
    test('while unresolved, any non-splash route is sent to /splash', () {
      expect(
        resolveRedirect(
          bootstrapComplete: false,
          auth: _auth(),
          ride: _ride('accepted', needsRestore: true),
          location: '/home',
        ),
        '/splash',
      );
    });

    test('while unresolved, /splash stays put', () {
      expect(
        resolveRedirect(
          bootstrapComplete: false,
          auth: _auth(authenticated: false),
          ride: _ride(null),
          location: '/splash',
        ),
        isNull,
      );
    });

    test('an unauthenticated reload is bounced to /login once resolved', () {
      expect(
        resolveRedirect(
          bootstrapComplete: true,
          auth: _auth(authenticated: false),
          ride: _ride(null),
          location: '/home',
        ),
        '/login',
      );
    });

    test('an authenticated reload at a non-splash route stays put', () {
      // The web-reload defect: a stored session at /home must not bounce.
      expect(
        resolveRedirect(
          bootstrapComplete: true,
          auth: _auth(),
          ride: _ride(null),
          location: '/home',
        ),
        isNull,
      );
    });

    test('an active ride wins over a deep-linked route on reload', () {
      expect(
        resolveRedirect(
          bootstrapComplete: true,
          auth: _auth(),
          ride: _ride('accepted', needsRestore: true),
          location: '/profile',
        ),
        '/active-ride',
      );
    });

    test('an active ride does not re-trigger on a trip route', () {
      for (final location in ['/active-ride', '/driver-matching']) {
        expect(
          resolveRedirect(
            bootstrapComplete: true,
            auth: _auth(),
            ride: _ride('accepted', needsRestore: true),
            location: location,
          ),
          isNull,
          reason: '$location is already the restore target',
        );
      }
    });

    test('an active ride does not hijack a flow route pushed mid-trip', () {
      // The destination search is pushed from the active trip; the restore
      // redirect must not bounce it back to /active-ride.
      expect(
        resolveRedirect(
          bootstrapComplete: true,
          auth: _auth(),
          ride: _ride('accepted', needsRestore: true),
          location: '/location-search',
        ),
        isNull,
      );
    });

    test('an authenticated rider on an auth route is sent to their route', () {
      expect(
        resolveRedirect(
          bootstrapComplete: true,
          auth: _auth(),
          ride: _ride('pending'),
          location: '/login',
        ),
        '/driver-matching',
      );
    });

    test('/splash resolves to the post-auth route once resolved', () {
      expect(
        resolveRedirect(
          bootstrapComplete: true,
          auth: _auth(),
          ride: _ride(null),
          location: '/splash',
        ),
        '/home',
      );
    });
  });
}
