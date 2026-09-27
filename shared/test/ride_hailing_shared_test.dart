import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {

  group('AuthUser', () {
    test('fromJson maps role/status', () {
      final user = AuthUser.fromJson({
        'id': 'user-1',
        'email': 'driver@example.com',
        'role': 'driver',
        'status': 'online',
      });
      expect(user.isDriver, isTrue);
      expect(user.status, 'online');
    });

    test('fromRole builds a role-only user', () {
      expect(AuthUser.fromRole('rider').isDriver, isFalse);
      expect(AuthUser.fromRole('driver').isDriver, isTrue);
    });

    test('fromJson leaves name/photo null without a rider object', () {
      final user = AuthUser.fromJson({'id': 'user-1', 'email': 'r@x.com'});
      expect(user.firstName, isNull);
      expect(user.lastName, isNull);
      expect(user.photoUrl, isNull);
      expect(user.fullName, isEmpty);
    });

    test('fromJson folds in the rider object name and photo', () {
      final user = AuthUser.fromJson(
        {'id': 'user-1', 'email': 'r@x.com', 'phone': '+5065551234'},
        rider: {
          'user_id': 'user-1',
          'first_name': 'Ana',
          'last_name': 'Rojas',
          'photo_url': 'https://cdn/ana.png',
        },
      );
      expect(user.firstName, 'Ana');
      expect(user.lastName, 'Rojas');
      expect(user.photoUrl, 'https://cdn/ana.png');
      expect(user.phone, '+5065551234');
      expect(user.fullName, 'Ana Rojas');
    });

    test('fromJson normalizes the NOT NULL empty columns to null', () {
      // `riders.first_name`/`photo_url` are TEXT NOT NULL DEFAULT '', so an
      // untouched account answers with empty strings, not nulls.
      final user = AuthUser.fromJson(
        {'id': 'user-1', 'email': 'r@x.com', 'phone': ''},
        rider: {'first_name': '', 'last_name': '', 'photo_url': ''},
      );
      expect(user.firstName, isNull);
      expect(user.photoUrl, isNull);
      expect(user.phone, isNull);
      expect(user.fullName, isEmpty);
    });

    test('fullName keeps whichever half is set', () {
      expect(
        AuthUser.fromJson({}, rider: {'first_name': 'Ana'}).fullName,
        'Ana',
      );
      expect(
        AuthUser.fromJson({}, rider: {'last_name': 'Rojas'}).fullName,
        'Rojas',
      );
    });

    test('toJson round-trips the name and photo', () {
      final user = AuthUser.fromJson(
        {'id': 'user-1'},
        rider: {'first_name': 'Ana', 'photo_url': 'https://cdn/ana.png'},
      );
      final json = user.toJson();
      expect(json['first_name'], 'Ana');
      expect(json['photo_url'], 'https://cdn/ana.png');
    });
  });

  group('Ride', () {
    test('fromJson maps the full payload', () {
      final ride = Ride.fromJson({
        'id': 'ride-1',
        'rider_id': 'user-1',
        'status': 'in_progress',
        'pickup_lat': 9.9333,
        'pickup_lng': -84.0833,
        'dropoff_address': 'Airport Rd',
        'total_fare': '2500.0',
      });
      expect(ride.id, 'ride-1');
      expect(ride.status, 'in_progress');
      expect(ride.pickupLat, 9.9333);
      expect(ride.dropoffAddress, 'Airport Rd');
      expect(ride.totalFare, 2500.0);
    });
  });
}