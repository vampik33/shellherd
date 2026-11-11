import 'package:flutter_test/flutter_test.dart';

/// Waits for real time to pass until [condition] holds.
Future<void> until(
  bool Function() condition,
  String what, {
  Duration within = const Duration(seconds: 10),
}) => eventually(
  () async => condition(),
  what,
  within: within,
  every: const Duration(milliseconds: 2),
);

/// [until] for a check that has to ask, such as a request to a server.
Future<void> eventually(
  Future<bool> Function() check,
  String what, {
  Duration within = const Duration(seconds: 10),
  Duration every = const Duration(milliseconds: 50),
}) async {
  final deadline = DateTime.now().add(within);
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) fail('never happened: $what');
    await Future<void>.delayed(every);
  }
}
