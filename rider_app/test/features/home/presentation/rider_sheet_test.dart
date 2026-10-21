import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/features/home/presentation/rider_sheet.dart';

void main() {
  Widget buildSheet({required int rows, double rowHeight = 20}) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: RiderDraggableSheet(
                footer: const SizedBox(
                  height: 56,
                  child: Center(child: Text('Footer')),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < rows; i++)
                      SizedBox(height: rowHeight, child: Text('Row $i')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double sheetSize(WidgetTester tester) => tester
      .widget<FractionallySizedBox>(
        find.descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(FractionallySizedBox),
        ),
      )
      .heightFactor!;

  testWidgets('the opening is a distinct snap below the full-screen max', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSheet(rows: 20));
    await tester.pumpAndSettle();

    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byType(DraggableScrollableSheet),
    );
    final opening = sheetSize(tester);
    expect(opening, lessThan(sheet.maxChildSize));
    expect(sheet.maxChildSize, 1.0);
    expect(sheet.snapSizes, isNotNull);
    expect(sheet.snapSizes!.single, closeTo(opening, 0.001));

    // Dragging the body up expands past the opening instead of being pinned
    // to a degenerate `[max]` snap list.
    await tester.drag(
      find.byKey(const ValueKey<String>('rider-sheet-scroll')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    expect(sheetSize(tester), greaterThan(opening + 0.01));
  });

  testWidgets('a full-screen sheet still scrolls its overflowing body', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSheet(rows: 60));
    await tester.pumpAndSettle();

    expect(sheetSize(tester), closeTo(1, 0.01));

    await tester.drag(
      find.byKey(const ValueKey<String>('rider-sheet-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey<String>('rider-sheet-scroll')),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
  });
}
