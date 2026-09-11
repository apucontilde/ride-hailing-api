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