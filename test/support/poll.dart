import 'package:flutter_test/flutter_test.dart';

/// Waits for real time to pass until [condition] holds.
Future<void> until(
  bool Function() condition,
  String what, {
  Duration within = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(within);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('never happened: $what');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
