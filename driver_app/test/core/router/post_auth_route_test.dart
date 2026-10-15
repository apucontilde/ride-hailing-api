import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/router/post_auth_route.dart';

void main() {
  const anon = AuthState();
  const driver = AuthState(
    status: AuthStatus.authenticated,
    user: AuthUser(role: 'driver'),
  );
  const rider = AuthState(
    status: AuthStatus.authenticated,
    user: AuthUser(role: 'rider'),
  );

  bool noTrip() => false;

  String? resolve({
    required bool complete,
    required AuthState auth,
    required String location,
    bool Function()? consume,
  }) =>
      resolveRedirect(
        bootstrapComplete: complete,
        consumeTripRestore: consume ?? noTrip,
        auth: auth,
        location: location,
      );

  group('bootstrap gate', () {
    test('an unresolved deep link is held on /splash, never bounced to /login',
        () {
      expect(
        resolve(complete: false, auth: anon, location: '/trip'),
        '/splash',
      );
      expect(
        resolve(complete: false, auth: anon, location: '/home'),
        '/splash',
      );
      expect(
        resolve(complete: false, auth: anon, location: '/splash'),
        isNull,
      );
    });
  });

  group('resolved auth rules', () {
    test('an anonymous session lands on /login', () {
      expect(resolve(complete: true, auth: anon, location: '/trip'), '/login');
      expect(resolve(complete: true, auth: anon, location: '/login'), isNull);
    });

    test('a driver at splash/auth/onboarding goes home', () {
      expect(resolve(complete: true, auth: driver, location: '/splash'), '/home');
      expect(resolve(complete: true, auth: driver, location: '/login'), '/home');
      expect(
        resolve(complete: true, auth: driver, location: '/onboarding'),
        '/home',
      );
    });

    test('a driver already on a protected route is left there', () {
      expect(resolve(complete: true, auth: driver, location: '/trip'), isNull);
      expect(resolve(complete: true, auth: driver, location: '/profile'), isNull);
    });

    test('a rider-role session is forced to onboarding', () {
      expect(
        resolve(complete: true, auth: rider, location: '/home'),
        '/onboarding',
      );
      expect(
        resolve(complete: true, auth: rider, location: '/login'),
        '/onboarding',
      );
      expect(
        resolve(complete: true, auth: rider, location: '/onboarding'),
        isNull,
      );
    });
  });

  group('one-shot live-trip restore', () {
    test('a restored trip wins once, then stops trapping', () {
      var pending = true;
      bool consume() {
        final value = pending;
        pending = false;
        return value;
      }

      expect(
        resolve(
          complete: true,
          auth: driver,
          location: '/home',
          consume: consume,
        ),
        '/trip',
      );
      // Consumed: a later pop to /home must not bounce back into /trip.
      expect(
        resolve(
          complete: true,
          auth: driver,
          location: '/home',
          consume: consume,
        ),
        isNull,
      );
    });

    test('a reload already parked on /trip consumes without re-routing', () {
      var pending = true;
      bool consume() {
        final value = pending;
        pending = false;
        return value;
      }

      expect(
        resolve(
          complete: true,
          auth: driver,
          location: '/trip',
          consume: consume,
        ),
        isNull,
      );
      // The flag was consumed, so leaving /trip is not trapped.
      expect(
        resolve(
          complete: true,
          auth: driver,
          location: '/home',
          consume: consume,
        ),
        isNull,
      );
    });
  });
}
