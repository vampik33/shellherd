/// Run by a test as its own process: adds 1 to the number under [key] in
/// the JSON file at the given path, [times] times, each through
/// [JsonFile.update], and writes a string of varying length beside it, so
/// that writers of different processes interleave.
library;

import 'dart:io';

import 'package:shellherd/ssh/json_file.dart';

Future<void> main(List<String> args) async {
  final store = JsonFile(File(args[0]));
  final times = int.parse(args[1]);
  final me = args[2];
  for (var i = 0; i < times; i++) {
    await store.update((data) {
      data['n'] = ((data['n'] as int?) ?? 0) + 1;
      data['last'] = me * (1 + i % 7);
    });
  }
}
