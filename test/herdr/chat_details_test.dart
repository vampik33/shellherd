import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/ui/chat_details.dart';
import 'package:shellherd/ssh/json_file.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('chat-details');
    file = File('${dir.path}/settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('hidden at first, without a saved choice', () async {
    final details = ChatDetails(JsonFile(file));
    await details.load();
    expect(details.value, isFalse);
  });

  test('a choice is saved for the next start, beside other settings', () async {
    file.writeAsStringSync('{"other": 1}');
    await ChatDetails(JsonFile(file)).choose(true);
    final next = ChatDetails(JsonFile(file));
    await next.load();
    expect(next.value, isTrue);
    final saved = JsonFile(file).read();
    expect(await saved, {'other': 1, ChatDetails.key: true});
  });

  test('a broken file or value keeps it hidden', () async {
    file.writeAsStringSync('not json');
    final broken = ChatDetails(JsonFile(file));
    await broken.load();
    expect(broken.value, isFalse);
    file.writeAsStringSync('{"${ChatDetails.key}": "yes"}');
    final wrong = ChatDetails(JsonFile(file));
    await wrong.load();
    expect(wrong.value, isFalse);
  });

  test('a choice made before the load ends stays', () async {
    file.writeAsStringSync('{"${ChatDetails.key}": true}');
    final details = ChatDetails(JsonFile(file));
    final load = details.load();
    await details.choose(false);
    await load;
    expect(details.value, isFalse);
  });

  test('a failed save keeps the choice for this run', () async {
    // A directory where the file should be: the write fails.
    Directory('${dir.path}/settings.json').createSync();
    final details = ChatDetails(JsonFile(file));
    await details.choose(true);
    expect(details.value, isTrue);
  });
}
