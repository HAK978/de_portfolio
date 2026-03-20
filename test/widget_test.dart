import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:de_portfolio/main.dart';

void main() {
  testWidgets('App launches without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: CS2PortfolioApp()),
    );
    expect(find.text('CS2 Portfolio'), findsOneWidget);
  });
}
