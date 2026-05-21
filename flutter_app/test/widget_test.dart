import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:btcan_viewer/main.dart';

void main() {
  testWidgets('App renders disconnected home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const BtCanApp());
    await tester.pump();

    expect(find.text('BTCAN Viewer'), findsOneWidget);
    expect(find.text('Disconnected'), findsWidgets);
    expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);
    expect(find.text('Start Monitor'), findsOneWidget);
  });
}
