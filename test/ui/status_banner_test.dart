import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ui/link_status.dart';

void main() {
  /// [banner] above the rest of a phone screen, as the pane shows it.
  Future<void> pumpOver(WidgetTester tester, StatusBanner banner) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              banner,
              const Expanded(child: Center(child: Text('the pane'))),
              const SizedBox(height: 120, child: Text('the composer')),
            ],
          ),
        ),
      ),
    );
  }

  Finder detail(String text) => find.widgetWithText(SelectableText, text);

  testWidgets('a long detail scrolls and leaves the screen under it', (
    tester,
  ) async {
    final long = [for (var i = 1; i <= 200; i++) 'line $i'].join('\n');
    await pumpOver(
      tester,
      StatusBanner('herdr did not take the input.', detail: long),
    );
    expect(tester.takeException(), isNull, reason: 'no overflow');
    expect(
      tester.getSize(find.byType(StatusBanner)).height,
      lessThan(StatusBanner.maxDetailHeight + 60),
    );
    expect(find.text('the pane'), findsOneWidget);
    expect(find.text('the composer'), findsOneWidget);

    // The end of the detail is there to read.
    final scroll = find.ancestor(
      of: detail(long),
      matching: find.byType(SingleChildScrollView),
    );
    await tester.drag(scroll, const Offset(0, -10000));
    await tester.pump();
    final view = tester.getRect(scroll);
    final text = tester.getRect(detail(long));
    expect(text.bottom, moreOrLessEquals(view.bottom));
  });

  testWidgets('a short detail keeps its own height', (tester) async {
    await pumpOver(
      tester,
      const StatusBanner('Cannot read this pane.', detail: 'one line'),
    );
    final height = tester.getSize(detail('one line')).height;
    expect(height, lessThan(StatusBanner.maxDetailHeight / 2));
  });
}
