import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// For widget tests on the real clock, with
/// LiveTestWidgetsFlutterBinding: real sockets and files never finish on
/// the fake clock of testWidgets.
///
/// Pumps until [done], and fails with what the screen shows.
Future<void> until(
  WidgetTester tester,
  bool Function() done,
  String what,
) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText());
  fail('no $what; the screen shows: ${texts.join(' | ')}');
}

/// Pumps until [finder] finds a widget on a route that finished opening: a
/// tap during the slide-in lands beside the moving widget.
Future<void> untilFound(WidgetTester tester, Finder finder) =>
    until(tester, () {
      final found = finder.evaluate();
      if (found.isEmpty) return false;
      return ModalRoute.of(found.first)?.animation?.isCompleted ?? true;
    }, finder.toString(describeSelf: true));

/// Pumps until [finder] finds nothing, also on a route that slides out.
Future<void> untilGone(WidgetTester tester, Finder finder) => until(
  tester,
  () => finder.evaluate().isEmpty,
  'end of ${finder.toString(describeSelf: true)}',
);

/// A field of the host form.
Finder hostField(String label) => find.widgetWithText(TextFormField, label);
