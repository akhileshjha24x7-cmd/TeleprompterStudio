import 'package:flutter_test/flutter_test.dart';
import 'package:teleprompter_studio/main.dart';

void main() {
  testWidgets('TeleprompterStudio app starts', (WidgetTester tester) async {
    await tester.pumpWidget(const TeleprompterStudioApp());
    expect(find.text('TeleprompterStudio'), findsOneWidget);
    expect(find.text('1. Paste your script'), findsOneWidget);
  });
}
