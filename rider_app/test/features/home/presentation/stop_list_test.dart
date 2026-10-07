import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/features/home/model/place.dart';
import 'package:rider_app/features/home/presentation/stop_list.dart';

const stopA = Place(id: 'a', name: 'Alpha', address: 'A St', lat: 9.93, lng: -84.09);
const stopB = Place(id: 'b', name: 'Bravo', address: 'B St', lat: 9.94, lng: -84.10);
const stopC = Place(id: 'c', name: 'Charlie', address: 'C St', lat: 9.95, lng: -84.11);

void main() {
  group('applyStopReorder', () {
    test('a downward move uses the already-adjusted target index', () {
      final stops = [stopA, stopB, stopC];

      // `ReorderableListView.onReorderItem` reports the final insert index (it
      // has already decremented for the removed item), so moving the first stop
      // to the end is (0, 2) and must not be adjusted again.
      applyStopReorder(stops, 0, 2);

      expect(stops, [stopB, stopC, stopA]);
    });

    test('an upward move inserts at the reported index', () {
      final stops = [stopA, stopB, stopC];

      applyStopReorder(stops, 2, 0);

      expect(stops, [stopC, stopA, stopB]);
    });

    test('a no-op move leaves the order untouched', () {
      final stops = [stopA, stopB, stopC];

      applyStopReorder(stops, 1, 1);

      expect(stops, [stopA, stopB, stopC]);
    });

    test('out-of-range indices are ignored', () {
      final stops = [stopA, stopB];

      applyStopReorder(stops, -1, 0);
      applyStopReorder(stops, 5, 0);
      applyStopReorder(stops, 0, 5);

      expect(stops, [stopA, stopB]);
    });
  });

  group('StopList', () {
    testWidgets('renders one row per stop and labels it by name', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StopList(
              stops: const [stopA, stopB],
              onAdd: () {},
              onRemove: (_) {},
              onReorder: (_, _) {},
            ),
          ),
        ),
      );

      expect(find.byType(ListTile), findsNWidgets(2));
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('add-stop-button')),
          findsOneWidget);
    });

    testWidgets('falls back to the address when the stop has no name',
        (tester) async {
      const unnamed = Place(id: 'x', name: '', address: 'Nameless Rd', lat: 9.9, lng: -84.0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StopList(
              stops: const [unnamed],
              onAdd: () {},
              onRemove: (_) {},
              onReorder: (_, _) {},
            ),
          ),
        ),
      );

      expect(find.text('Nameless Rd'), findsOneWidget);
    });

    testWidgets('reports the tapped stop index to onRemove', (tester) async {
      int? removed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StopList(
              stops: const [stopA, stopB],
              onAdd: () {},
              onRemove: (index) => removed = index,
              onReorder: (_, _) {},
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close).last);

      expect(removed, 1);
    });

    testWidgets('invokes onAdd from the add-stop button', (tester) async {
      var added = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StopList(
              stops: const [stopA],
              onAdd: () => added = true,
              onRemove: (_) {},
              onReorder: (_, _) {},
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('add-stop-button')));

      expect(added, isTrue);
    });

    testWidgets('an empty list still offers the add-stop button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StopList(
              stops: const [],
              onAdd: () {},
              onRemove: (_) {},
              onReorder: (_, _) {},
            ),
          ),
        ),
      );

      expect(find.byType(ListTile), findsNothing);
      expect(find.byKey(const ValueKey<String>('add-stop-button')),
          findsOneWidget);
    });
  });
}
