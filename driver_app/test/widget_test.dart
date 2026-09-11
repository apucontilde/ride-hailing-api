import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:driver_app/app.dart';

void main() {
  testWidgets('DriverApp builds and shows the splash gate', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: DriverApp()));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}