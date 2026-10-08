import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('AppStatusChip renders its label and optional icon', (tester) async {
    await tester.pumpWidget(
      wrap(const AppStatusChip(label: 'On Trip', icon: Icons.directions_car)),
    );

    expect(find.text('On Trip'), findsOneWidget);
    expect(find.byIcon(Icons.directions_car), findsOneWidget);
  });

  testWidgets('AppStatusChip applies the role colour to its label', (tester) async {
    await tester.pumpWidget(
      wrap(const AppStatusChip(
        label: 'Available',
        color: AppColors.success,
      )),
    );

    final chip = tester.widget<Chip>(find.byType(Chip));
    expect((chip.label as Text).data, 'Available');
    // The role colour must actually reach the label style, resolved from the
    // literal Material green rather than read back off the widget's own getter.
    expect(chip.labelStyle?.color, Colors.green);
    // The default tint is the shared info tint literal.
    expect(chip.backgroundColor, const Color(0xFFE3F2FD));
  });

  testWidgets('AppBadge renders a sized, coloured dot and label', (tester) async {
    await tester.pumpWidget(wrap(const AppBadge(label: 'Online')));

    expect(find.text('Online'), findsOneWidget);
    final dot = tester.widget<Container>(find.byType(Container));
    final decoration = dot.decoration! as BoxDecoration;
    expect(decoration.color, Colors.green);
    expect(decoration.shape, BoxShape.circle);
    expect(tester.getSize(find.byType(Container)), const Size(10, 10));
  });
}
