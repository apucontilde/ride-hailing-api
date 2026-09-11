import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  group('Validators', () {
    group('validateEmail', () {
      test('returns error for null value', () {
        expect(Validators.validateEmail(null), 'Email is required');
      });

      test('returns error for empty string', () {
        expect(Validators.validateEmail(''), 'Email is required');
        expect(Validators.validateEmail('   '), 'Email is required');
      });

      test('returns error for invalid email formats', () {
        expect(Validators.validateEmail('notanemail'),
            'Enter a valid email address');
        expect(Validators.validateEmail('@domain.com'),
            'Enter a valid email address');
        expect(Validators.validateEmail('user@'),
            'Enter a valid email address');
        expect(Validators.validateEmail('user@.com'),
            'Enter a valid email address');
      });

      test('returns null for valid email', () {
        expect(Validators.validateEmail('user@example.com'), isNull);
        expect(Validators.validateEmail('test.user+tag@domain.co'),
            isNull);
      });
    });

    group('validatePassword', () {
      test('returns error for null value', () {
        expect(Validators.validatePassword(null), 'Password is required');
      });

      test('returns error for empty string', () {
        expect(Validators.validatePassword(''), 'Password is required');
      });

      test('returns error for short password', () {
        expect(Validators.validatePassword('Ab1'),
            'Password must be at least 8 characters');
        expect(Validators.validatePassword('Abcdef1'),
            'Password must be at least 8 characters');
      });

      test('returns error for missing uppercase', () {
        expect(Validators.validatePassword('abcdefgh1'),
            'Password must contain an uppercase letter');
      });

      test('returns error for missing number', () {
        expect(Validators.validatePassword('Abcdefgh'),
            'Password must contain a number');
      });

      test('returns null for valid password', () {
        expect(Validators.validatePassword('MyPassword1'), isNull);
        expect(Validators.validatePassword('Str0ng!Pass'), isNull);
        expect(Validators.validatePassword('Abc12345XYZ'), isNull);
      });
    });

    group('validatePhone', () {
      test('returns error for null value', () {
        expect(Validators.validatePhone(null), 'Phone number is required');
      });

      test('returns error for empty string', () {
        expect(Validators.validatePhone(''), 'Phone number is required');
      });

      test('returns error for invalid phone', () {
        expect(Validators.validatePhone('abc'),
            'Enter a valid phone number');
        expect(Validators.validatePhone('12'),
            'Enter a valid phone number');
      });

      test('returns null for valid phone', () {
        expect(Validators.validatePhone('1234567890'), isNull);
        expect(Validators.validatePhone('+1234567890'), isNull);
        expect(Validators.validatePhone('+1 (555) 123-4567'), isNull);
      });
    });

    group('validateName', () {
      test('returns error for null value', () {
        expect(Validators.validateName(null), 'Name is required');
      });

      test('returns error for empty string', () {
        expect(Validators.validateName(''), 'Name is required');
        expect(Validators.validateName('   '), 'Name is required');
      });

      test('returns error for short name', () {
        expect(Validators.validateName('A'),
            'Name must be at least 2 characters');
      });

      test('returns null for valid name', () {
        expect(Validators.validateName('John'), isNull);
        expect(Validators.validateName('John Doe'), isNull);
      });
    });

    group('validateRequired', () {
      test('returns error for null value', () {
        expect(Validators.validateRequired(null, 'Field'),
            'Field is required');
      });

      test('returns error for empty value', () {
        expect(Validators.validateRequired('', 'Field'),
            'Field is required');
      });

      test('returns null for non-empty value', () {
        expect(Validators.validateRequired('value', 'Field'), isNull);
      });
    });
  });
}
