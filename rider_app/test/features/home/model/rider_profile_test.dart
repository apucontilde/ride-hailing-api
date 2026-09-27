import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/features/home/model/rider_profile.dart';

void main() {
  group('RiderProfile', () {
    test('fromJson maps the rider sub-object', () {
      final profile = RiderProfile.fromJson({
        'user_id': 'user-1',
        'first_name': 'Ana',
        'last_name': 'Rojas',
        'photo_url': 'https://cdn.example.com/ana.png',
        'status': 'looking',
      });

      expect(profile.userId, 'user-1');
      expect(profile.firstName, 'Ana');
      expect(profile.lastName, 'Rojas');
      expect(profile.photoUrl, 'https://cdn.example.com/ana.png');
      expect(profile.status, 'looking');
      expect(profile.hasPhoto, isTrue);
    });

    test('normalizes the NOT NULL empty columns to null', () {
      // `riders.first_name`/`last_name`/`photo_url` are TEXT NOT NULL DEFAULT
      // '' (migrations/004_create_profiles.up.sql), so a fresh account answers
      // with empty strings, not nulls.
      final profile = RiderProfile.fromJson({
        'user_id': 'user-1',
        'first_name': '',
        'last_name': '',
        'photo_url': '',
      });

      expect(profile.firstName, isNull);
      expect(profile.lastName, isNull);
      expect(profile.photoUrl, isNull);
      expect(profile.hasPhoto, isFalse);
    });

    test('defaults to the idle status and empty fields', () {
      final profile = RiderProfile.fromJson({'user_id': 'user-1'});

      expect(profile.status, 'idle');
      expect(profile.fullName, isEmpty);
    });

    test('fullName keeps whichever half is set', () {
      expect(
        RiderProfile.fromJson({'first_name': 'Ana'}).fullName,
        'Ana',
      );
      expect(
        RiderProfile.fromJson({'last_name': 'Rojas'}).fullName,
        'Rojas',
      );
      expect(
        RiderProfile.fromJson({'first_name': 'Ana', 'last_name': 'Rojas'})
            .fullName,
        'Ana Rojas',
      );
    });

    test('fullName trims and does not double the separator', () {
      expect(
        RiderProfile.fromJson({'first_name': '  Ana ', 'last_name': ' Rojas '})
            .fullName,
        'Ana Rojas',
      );
    });
  });
}
