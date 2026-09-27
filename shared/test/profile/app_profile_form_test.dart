import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(AppProfileForm form) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: form)));

  /// Reads a field's live text the way the rider's profile suite does — by label,
  /// which is why the three labels are contract.
  String fieldText(WidgetTester tester, String label) => tester
      .widget<TextFormField>(find.widgetWithText(TextFormField, label))
      .controller!
      .text;

  Finder saveButton() => find.byKey(const Key('profile-save-button'));

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(saveButton()).onPressed != null;

  Future<void> type(WidgetTester tester, String label, String value) =>
      tester.enterText(find.widgetWithText(TextFormField, label), value);

  /// Types a name pair that passes `Validators.validateName`.
  Future<void> typeValidName(WidgetTester tester) async {
    await type(tester, 'First name', 'Ana');
    await type(tester, 'Last name', 'Rojas');
  }

  Future<void> noopSave({
    required String firstName,
    required String lastName,
    String? phone,
  }) async {}

  group('AppProfileForm field labels', () {
    testWidgets('are the exact strings the apps locate fields by', (tester) async {
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));

      // The rider's profile suite uses
      // `find.widgetWithText(TextFormField, <label>)` in four places, so renaming
      // one breaks tests that have nothing to do with this refactor.
      expect(find.widgetWithText(TextFormField, 'First name'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Last name'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Phone'), findsOneWidget);
      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.byType(Card), findsOneWidget);
      expect(saveButton(), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('the phone field keeps its Optional hint', (tester) async {
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));

      expect(find.text('Optional'), findsOneWidget);
    });
  });

  group('AppProfileForm seeds', () {
    testWidgets('land in their fields', (tester) async {
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            onSave: noopSave,
            firstName: 'Ana',
            lastName: 'Rojas',
            phone: '+5065559999',
          ),
        ),
      );

      expect(fieldText(tester, 'First name'), 'Ana');
      expect(fieldText(tester, 'Last name'), 'Rojas');
      expect(fieldText(tester, 'Phone'), '+5065559999');
    });

    testWidgets('a null phone leaves the field empty', (tester) async {
      // The driver seeds first/last only, so its phone field starts empty and a
      // first/last-only save must not start writing a phone it never wrote.
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            onSave: noopSave,
            firstName: 'Ava',
            lastName: 'Lopez',
            phone: null,
          ),
        ),
      );

      expect(fieldText(tester, 'First name'), 'Ava');
      expect(fieldText(tester, 'Last name'), 'Lopez');
      expect(fieldText(tester, 'Phone'), '');
    });

    testWidgets('a changed phone prop re-seeds the field', (tester) async {
      // The rider's post-save re-read: `PUT /rider/me` never echoes the `users`
      // row, so the app re-reads `GET /rider/me` and passes the fresh phone back
      // down. The rider's suite asserts '+5065559999' appears after a save.
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));
      expect(fieldText(tester, 'Phone'), '');

      await tester.pumpWidget(
        wrap(AppProfileForm(onSave: noopSave, phone: '+5065559999')),
      );
      expect(fieldText(tester, 'Phone'), '+5065559999');
    });

    testWidgets('an unrelated rebuild does not clobber what the user typed', (tester) async {
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));
      await type(tester, 'First name', 'Typed');

      // Same seeds, new errorText: a rebuild the caller did not intend as a
      // re-seed must leave the field alone.
      await tester.pumpWidget(
        wrap(AppProfileForm(onSave: noopSave, errorText: 'Server said no')),
      );

      expect(fieldText(tester, 'First name'), 'Typed');
    });
  });

  group('AppProfileForm validation', () {
    testWidgets('empty names show the shared Validators messages', (tester) async {
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.text('Name is required'), findsNWidgets(2));
    });

    testWidgets('a too-short name shows the shared length message', (tester) async {
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));
      await type(tester, 'First name', 'A');
      await type(tester, 'Last name', 'Rojas');

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.text('Name must be at least 2 characters'), findsOneWidget);
    });

    testWidgets('an empty phone is valid and blocks nothing', (tester) async {
      // Regression guard: `Validators.validatePhone` returns 'Phone number is
      // required' for empty input, so wiring it directly would make the phone
      // mandatory and the driver's only save path could never be sent.
      var saved = false;
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            onSave: ({required firstName, required lastName, phone}) async {
              saved = true;
            },
          ),
        ),
      );
      await typeValidName(tester);

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.text('Phone number is required'), findsNothing);
      expect(saved, isTrue);
    });

    testWidgets('a malformed phone shows the shared phone message', (tester) async {
      var saved = false;
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            onSave: ({required firstName, required lastName, phone}) async {
              saved = true;
            },
          ),
        ),
      );
      await typeValidName(tester);
      await type(tester, 'Phone', 'not-a-phone');

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid phone number'), findsOneWidget);
      expect(saved, isFalse);
    });
  });

  group('AppProfileForm onSave', () {
    testWidgets('receives the trimmed typed values', (tester) async {
      String? gotFirst;
      String? gotLast;
      String? gotPhone;
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            onSave: ({
              required String firstName,
              required String lastName,
              String? phone,
            }) async {
              gotFirst = firstName;
              gotLast = lastName;
              gotPhone = phone;
            },
          ),
        ),
      );

      await type(tester, 'First name', '  Ana  ');
      await type(tester, 'Last name', ' Rojas ');
      await type(tester, 'Phone', ' +5065559999 ');
      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      // Trimming here is what lets both apps' `_save()` become a thin wrapper:
      // they used to compute `.text.trim()` themselves.
      expect(gotFirst, 'Ana');
      expect(gotLast, 'Rojas');
      expect(gotPhone, '+5065559999');
    });

    testWidgets('a blank phone arrives as null, not an empty string', (tester) async {
      Object? gotPhone = 'unset';
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            firstName: 'Ava',
            lastName: 'Lopez',
            onSave: ({
              required String firstName,
              required String lastName,
              String? phone,
            }) async {
              gotPhone = phone;
            },
          ),
        ),
      );

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      // The driver's `_save()` used to compute `text.isEmpty ? null : text`; that
      // computation now lives here once.
      expect(gotPhone, isNull);
    });

    testWidgets('a whitespace-only phone also arrives as null', (tester) async {
      Object? gotPhone = 'unset';
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            firstName: 'Ava',
            lastName: 'Lopez',
            onSave: ({
              required String firstName,
              required String lastName,
              String? phone,
            }) async {
              gotPhone = phone;
            },
          ),
        ),
      );

      await type(tester, 'Phone', '   ');
      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(gotPhone, isNull);
    });

    testWidgets('is not called when validation fails', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            onSave: ({required firstName, required lastName, phone}) async {
              calls++;
            },
          ),
        ),
      );

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(calls, 0);
    });
  });

  group('AppProfileForm saving state', () {
    testWidgets('isSaving disables the button and swaps in a spinner', (tester) async {
      await tester.pumpWidget(
        wrap(AppProfileForm(onSave: noopSave, isSaving: true)),
      );

      expect(saveEnabled(tester), isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.save_outlined), findsNothing);
    });

    testWidgets('not saving shows the save icon and an enabled button', (tester) async {
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));

      expect(saveEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    });

    testWidgets('awaits onSave and stays disabled until it completes', (tester) async {
      final gate = Completer<void>();
      var started = false;
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            firstName: 'Ana',
            lastName: 'Rojas',
            onSave: ({
              required String firstName,
              required String lastName,
              String? phone,
            }) {
              started = true;
              return gate.future;
            },
          ),
        ),
      );

      await tester.tap(saveButton());
      await tester.pump();

      expect(started, isTrue);
      // The caller may have no provider flag of its own, so the form holds the
      // button down for the duration of the await itself.
      expect(saveEnabled(tester), isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(saveEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('AppProfileForm error text', () {
    testWidgets('renders under the profile-error key', (tester) async {
      await tester.pumpWidget(
        wrap(
          AppProfileForm(
            onSave: noopSave,
            errorText: 'Could not save your profile.',
          ),
        ),
      );

      expect(find.byKey(const Key('profile-error')), findsOneWidget);
      expect(find.text('Could not save your profile.'), findsOneWidget);
      final error = tester.widget<Text>(find.byKey(const Key('profile-error')));
      expect(error.style?.color, isNotNull);
    });

    testWidgets('renders nothing when there is no error', (tester) async {
      await tester.pumpWidget(wrap(AppProfileForm(onSave: noopSave)));

      expect(find.byKey(const Key('profile-error')), findsNothing);
    });
  });
}
