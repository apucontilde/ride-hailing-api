import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  testWidgets('AppBottomSheet renders its child on a rounded shadowed surface',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppBottomSheet(child: Text('Sheet body'))),
      ),
    );

    expect(find.text('Sheet body'), findsOneWidget);
    final container = tester.widget<Container>(
      find.ancestor(
        of: find.text('Sheet body'),
        matching: find.byType(Container),
      ).first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color, AppColors.surface);
    expect(decoration.borderRadius, isNotNull);
    expect(decoration.boxShadow, isNotEmpty);
  });

  testWidgets('AppSheetHandle renders the capsule', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppSheetHandle())),
    );

    final container = tester.widget<Container>(find.byType(Container));
    expect(container.constraints?.maxWidth, 40);
    expect(container.constraints?.maxHeight, 4);
  });
}
