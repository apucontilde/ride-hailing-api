import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Form(child: child)));

  testWidgets('renders a TextFormField with label, hint and icons',
      (tester) async {
    await tester.pumpWidget(
      wrap(AppTextField(
        controller: TextEditingController(),
        label: 'Email',
        hint: 'Enter your email',
        prefixIcon: const Icon(Icons.email_outlined),
        suffixIcon: const Icon(Icons.clear),
      )),
    );

    expect(find.byType(TextFormField), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.labelText, 'Email');
    expect(field.decoration?.hintText, 'Enter your email');
    expect(field.decoration?.prefixIcon, isA<Icon>());
    expect(field.decoration?.suffixIcon, isA<Icon>());
    expect(find.byIcon(Icons.email_outlined), findsOneWidget);
    expect(find.byIcon(Icons.clear), findsOneWidget);
  });

  testWidgets('forwards the keyboard/obscure/action/autofill parameters',
      (tester) async {
    var submitted = '';
    await tester.pumpWidget(
      wrap(AppTextField(
        controller: TextEditingController(),
        label: 'Password',
        obscureText: true,
        keyboardType: TextInputType.visiblePassword,
        autofillHints: const [AutofillHints.password],
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (value) => submitted = value,
      )),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.keyboardType, TextInputType.visiblePassword);
    expect(field.textInputAction, TextInputAction.done);
    expect(field.autofillHints, const [AutofillHints.password]);
    expect(field.onSubmitted, isNotNull);
    field.onSubmitted!('secret');
    expect(submitted, 'secret');
  });

  testWidgets('runs the validator', (tester) async {
    final formKey = GlobalKey<FormState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            key: formKey,
            child: AppTextField(
              controller: TextEditingController(),
              label: 'Email',
              validator: (value) =>
                  (value == null || value.isEmpty) ? 'Required' : null,
            ),
          ),
        ),
      ),
    );

    formKey.currentState!.validate();
    await tester.pump();
    expect(find.text('Required'), findsOneWidget);
  });
}
