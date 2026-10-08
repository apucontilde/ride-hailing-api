import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('primary renders an ElevatedButton (the test-locator contract)',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(AppButton(label: 'Go', onPressed: () => taps++)),
    );

    expect(find.widgetWithText(ElevatedButton, 'Go'), findsOneWidget);
    await tester.tap(find.text('Go'));
    expect(taps, 1);
  });

  testWidgets('secondary renders an OutlinedButton', (tester) async {
    await tester.pumpWidget(
      wrap(AppButton(
        label: 'Later',
        variant: AppButtonVariant.secondary,
        onPressed: () {},
      )),
    );

    expect(find.widgetWithText(OutlinedButton, 'Later'), findsOneWidget);
  });

  testWidgets('danger renders a red ElevatedButton', (tester) async {
    await tester.pumpWidget(
      wrap(AppButton(
        label: 'Delete',
        variant: AppButtonVariant.danger,
        onPressed: () {},
      )),
    );

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Delete'),
    );
    final background =
        button.style?.backgroundColor?.resolve(<WidgetState>{});
    final foreground =
        button.style?.foregroundColor?.resolve(<WidgetState>{});
    expect(background, Colors.red);
    expect(foreground, Colors.white);
  });

  testWidgets('text renders a TextButton', (tester) async {
    await tester.pumpWidget(
      wrap(AppButton(
        label: 'Skip',
        variant: AppButtonVariant.text,
        onPressed: () {},
      )),
    );

    expect(find.widgetWithText(TextButton, 'Skip'), findsOneWidget);
  });

  testWidgets('a null onPressed disables the button', (tester) async {
    await tester.pumpWidget(wrap(const AppButton(label: 'Off')));

    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('isLoading swaps the label for a spinner and disables taps',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      wrap(AppButton(label: 'Saving', isLoading: true, onPressed: () => taps++)),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Saving'), findsNothing);
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);
    // The disabled state is a real no-op, not just a null field.
    await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
    expect(taps, 0);
  });

  testWidgets('icon renders before the label and expand stretches full width',
      (tester) async {
    await tester.pumpWidget(
      wrap(AppButton(
        label: 'Add',
        icon: Icons.add,
        expand: true,
        onPressed: () {},
      )),
    );

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    final sized = tester.getSize(find.byType(ElevatedButton));
    expect(sized.width, tester.view.physicalSize.width / tester.view.devicePixelRatio);
  });
}
