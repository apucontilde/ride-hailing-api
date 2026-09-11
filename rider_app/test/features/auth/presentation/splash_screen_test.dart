import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/app.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

void main() {
  testWidgets('shows loading indicator on splash screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: RiderApp()));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
