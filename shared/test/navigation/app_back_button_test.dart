import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  group('AppBackButton', () {
    testWidgets('renders Icons.arrow_back and the Back tooltip by default', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: AppBackButton())),
        ),
      );

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        'Back',
      );
    });

    testWidgets('an explicit icon overrides the default glyph', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: AppBackButton(icon: Icons.close))),
        ),
      );

      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('an explicit onPressed wins over popping', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: AppBackButton(onPressed: () => pressed++),
                      ),
                    ),
                  ),
                  child: const Text('push'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();

      expect(pressed, 1);
      // The explicit handler ran instead of popping: the pushed page is still up.
      expect(find.byType(AppBackButton), findsOneWidget);
    });

    testWidgets('pops when the enclosing navigator can pop', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const Scaffold(body: AppBackButton()),
                    ),
                  ),
                  child: const Text('push'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBackButton), findsOneWidget);

      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();

      expect(find.byType(AppBackButton), findsNothing);
    });

    testWidgets('calls onFallback when the navigator cannot pop', (tester) async {
      var fallback = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: AppBackButton(onFallback: () => fallback++)),
          ),
        ),
      );

      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();

      expect(fallback, 1);
    });

    testWidgets('a null onFallback at the root is a safe no-op', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: AppBackButton())),
        ),
      );

      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();

      // Nothing to pop and no fallback: the button must not throw.
      expect(find.byType(AppBackButton), findsOneWidget);
    });
  });
}
