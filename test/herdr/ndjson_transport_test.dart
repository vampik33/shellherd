import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/ndjson_transport.dart';

Stream<List<int>> chunks(List<List<int>> parts) => Stream.fromIterable(parts);

void main() {
  test('encodes one message as one newline-terminated line', () {
    final bytes = encodeNdjson({'id': 'a', 'method': 'ping', 'params': {}});
    final text = utf8.decode(bytes);
    expect(text, '{"id":"a","method":"ping","params":{}}\n');
    expect('\n'.allMatches(text), hasLength(1));
  });

  test('a newline inside a string stays escaped on one line', () {
    final text = utf8.decode(encodeNdjson({'text': 'a\nb'}));
    expect('\n'.allMatches(text), hasLength(1));
  });

  test('joins a line split across chunks and splits two lines in one chunk', () async {
    final out = await decodeNdjson(
      chunks([
        utf8.encode('{"a":'),
        utf8.encode('1}\n{"b":2}\n{"c"'),
        utf8.encode(':3}\n'),
      ]),
    ).toList();
    expect(out, [
      {'a': 1},
      {'b': 2},
      {'c': 3},
    ]);
  });

  test('decodes a multi-byte UTF-8 character split between chunks', () async {
    final bytes = utf8.encode('{"t":"агент ✻"}\n');
    final cut = bytes.indexOf(0xD0) + 1; // inside the first Cyrillic letter
    final out = await decodeNdjson(
      chunks([bytes.sublist(0, cut), bytes.sublist(cut)]),
    ).toList();
    expect(out.single['t'], 'агент ✻');
  });

  test('accepts CRLF and skips blank lines', () async {
    final out = await decodeNdjson(
      chunks([utf8.encode('{"a":1}\r\n\n  \n{"b":2}\n')]),
    ).toList();
    expect(out, [
      {'a': 1},
      {'b': 2},
    ]);
  });

  test('a last line with no newline is dropped, not an error', () async {
    final out = await decodeNdjson(
      chunks([utf8.encode('{"a":1}\n{"b":')]),
    ).toList();
    expect(out, [
      {'a': 1},
    ]);
  });

  test('a character cut off at the end of the stream is no error', () async {
    final bytes = utf8.encode('{"a":1}\nж');
    final out = await decodeNdjson(
      chunks([bytes.sublist(0, bytes.length - 1)]),
    ).toList();
    expect(out, [
      {'a': 1},
    ]);
  });

  test('accepts a Stream<Uint8List> typed as Stream<List<int>>', () async {
    // Sockets and dartssh2 channels are Stream<Uint8List> at runtime.
    final Stream<List<int>> socketLike = Stream<Uint8List>.fromIterable([
      Uint8List.fromList(utf8.encode('{"ok":true}\n')),
    ]);
    expect(await decodeNdjson(socketLike).toList(), [
      {'ok': true},
    ]);
  });

  test('invalid JSON is a format error that names the line', () async {
    final s = decodeNdjson(chunks([utf8.encode('{"a":1}\nnot json\n')]));
    await expectLater(
      s,
      emitsInOrder([
        {'a': 1},
        emitsError(
          isA<NdjsonFormatException>().having((e) => e.line, 'line', 'not json'),
        ),
      ]),
    );
  });

  test('a JSON value that is not an object is a format error', () async {
    await expectLater(
      decodeNdjson(chunks([utf8.encode('[1,2]\n')])),
      emitsError(isA<NdjsonFormatException>()),
    );
  });

  test('invalid UTF-8 is a format error', () async {
    await expectLater(
      decodeNdjson(chunks([[0x7B, 0xFF, 0xFE, 0x7D, 0x0A]])),
      emitsError(isA<NdjsonFormatException>()),
    );
  });
}
