import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rider_app/app.dart';

void main() {
  testWidgets('App renders splash screen on startup',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: RiderApp()));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
