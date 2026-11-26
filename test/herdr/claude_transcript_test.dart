import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/transcript/chat_items.dart';
import 'package:shellherd/herdr/transcript/claude_transcript.dart';
import 'package:shellherd/herdr/transcript/transcript_stream.dart';

import '../support/fake_transcripts.dart';

List<ChatItem> parse(Iterable<String> lines) {
  final t = ClaudeTranscript();
  lines.forEach(t.add);
  return t.items;
}

void main() {
  group('ClaudeTranscript', () {
    test('a prompt, then a reply split over records of one message', () {
      expect(
        parse([
          claudeUser('fix the bug', uuid: 'u1'),
          claudeAssistant([
            {'type': 'thinking', 'thinking': ' look first ', 'signature': 's'},
          ], uuid: 'a1'),
          claudeAssistant([claudeText('Found it.')], uuid: 'a2'),
          claudeAssistant([
            claudeToolUse('t1', 'Read', {'file_path': '/src/a.dart'}),
          ], uuid: 'a3'),
        ]),
        [
          const ChatPrompt('fix the bug'),
          const ChatThinking('look first'),
          const ChatReply('Found it.'),
          ChatTool(
            id: 't1',
            name: 'Read',
            summary: '/src/a.dart',
            input: const JsonEncoder.withIndent('  ')
                .convert({'file_path': '/src/a.dart'}),
          ),
        ],
      );
    });

    test('a tool result joins its call, with its error flag', () {
      final items = parse([
        claudeAssistant([
          claudeToolUse('t1', 'Bash', {'command': 'ls', 'description': 'List'}),
          claudeToolUse('t2', 'Bash', {'command': 'false'}),
        ]),
        claudeUser([claudeToolResult('t1', 'a\nb')]),
        claudeUser([
          claudeToolResult('t2', [
            {'type': 'text', 'text': 'failed'},
            {'type': 'image', 'source': <String, Object?>{}},
          ], isError: true),
        ]),
      ]);
      expect(items, [
        const ChatTool(
          id: 't1',
          name: 'Bash',
          summary: 'List',
          input: 'ls',
          result: ToolResult('a\nb', isError: false),
        ),
        const ChatTool(
          id: 't2',
          name: 'Bash',
          summary: 'false',
          input: 'false',
          result: ToolResult('failed\n[image]', isError: true),
        ),
      ]);
    });

    test('a result whose call was not read is dropped', () {
      expect(
        parse([
          claudeUser([claudeToolResult('gone', 'x')]),
        ]),
        isEmpty,
      );
    });

    test('a call stays without a result while the tool runs', () {
      final items = parse([
        claudeAssistant([
          claudeToolUse('t1', 'Bash', {'command': 'rm x'}),
        ]),
      ]);
      expect((items.single as ChatTool).result, isNull);
    });

    test('a record seen again, a repeated call, a subagent and meta text '
        'are dropped', () {
      expect(
        parse([
          claudeUser('once', uuid: 'u1'),
          claudeUser('once', uuid: 'u1'),
          claudeAssistant([
            claudeToolUse('t1', 'Bash', {'command': 'a'}),
          ]),
          claudeAssistant([
            claudeToolUse('t1', 'Bash', {'command': 'a'}),
          ]),
          claudeUser('sub', extra: {'isSidechain': true}),
          claudeAssistant([claudeText('sub')], extra: {'isSidechain': true}),
          claudeUser([claudeText('skill text')], extra: {'isMeta': true}),
        ]).length,
        2,
      );
    });

    test('lines that are no record are dropped', () {
      expect(
        parse([
          '',
          'shell startup text',
          '{"type": "user", "message": {"role": "us',
          'er", "content": "cut"}}',
          '[1, 2]',
          '"text"',
          '{"type": "queue-operation", "operation": "enqueue"}',
          '{"type": "system", "subtype": "turn_duration"}',
          '{"type": "attachment", "uuid": "x"}',
          '{"type": "user", "message": "not an object"}',
          '{"type": "user", "message": {"content": 42}}',
          '{"type": "assistant", "message": {"content": "not a list"}}',
          claudeAssistant([
            {'type': 'new_block_type', 'text': 'x'},
            claudeText('   '),
            {'type': 'tool_use', 'id': 7, 'name': 'Bash'},
          ]),
        ]),
        isEmpty,
      );
    });

    test('slash commands, their output and ! commands', () {
      expect(
        parse([
          claudeUser(
            '<command-message>review</command-message>\n'
            '<command-name>/review</command-name>\n'
            '<command-args>42</command-args>',
          ),
          claudeUser('<command-name>/clear</command-name>'),
          claudeUser(
            '<local-command-caveat>Caveat: do not answer</local-command-caveat>',
          ),
          claudeUser(
            '<local-command-stdout>\x1b[1mCost\x1b[22m: \$1</local-command-stdout>',
          ),
          claudeUser('<local-command-stdout></local-command-stdout>'),
          claudeUser('<bash-input>git status</bash-input>'),
          claudeUser(
            '<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>',
          ),
          claudeUser(
            '<bash-stdout></bash-stdout><bash-stderr>oops</bash-stderr>',
          ),
        ]),
        const [
          ChatPrompt('/review 42'),
          ChatPrompt('/clear'),
          ChatNote('Cost: \$1'),
          ChatPrompt('! git status'),
          ChatNote('clean'),
          ChatNote('oops'),
        ],
      );
    });

    test('a prompt that only mentions one of the tags is a prompt', () {
      const typed = [
        'why is <bash-input>ls</bash-input> in the transcript?',
        'drop <local-command-caveat>this</local-command-caveat>',
        'what does <command-name>/clear</command-name> do?',
        'and <bash-stdout>out</bash-stdout>?',
      ];
      expect(parse(typed.map(claudeUser)), [
        for (final text in typed) ChatPrompt(text),
      ]);
    });

    test('interrupts, API errors, summaries and images', () {
      expect(
        parse([
          claudeUser('[Request interrupted by user]'),
          claudeUser([
            claudeText('[Request interrupted by user for tool use]'),
          ]),
          claudeAssistant(
            [claudeText('API Error: 529 overloaded')],
            extra: {'isApiErrorMessage': true},
          ),
          claudeUser('long summary', extra: {'isCompactSummary': true}),
          claudeUser([
            claudeText('what is this?'),
            {'type': 'image', 'source': <String, Object?>{}},
          ]),
          claudeAssistant([
            {'type': 'redacted_thinking', 'data': 'x'},
          ]),
        ]),
        const [
          ChatNote('Interrupted'),
          ChatNote('Interrupted'),
          ChatNote('API Error: 529 overloaded'),
          ChatNote('Earlier conversation was summarized.'),
          ChatPrompt('what is this?\n[image]'),
          ChatThinking(''),
        ],
      );
    });

    test('a long result and a long input are cut', () {
      final long = 'x' * (toolTextCap + 10);
      final tool =
          parse([
                claudeAssistant([
                  claudeToolUse('t1', 'Bash', {'command': long}),
                ]),
                claudeUser([claudeToolResult('t1', long)]),
              ]).single
              as ChatTool;
      for (final text in [tool.input, tool.result!.text]) {
        expect(text, startsWith('x' * toolTextCap));
        expect(text, endsWith('… (10 more characters)'));
      }
    });

    test('a result loses its terminal escapes', () {
      final tool =
          parse([
                claudeAssistant([
                  claudeToolUse('t1', 'Bash', {'command': 'ls'}),
                ]),
                claudeUser([claudeToolResult('t1', '\x1b[31mred\x1b[0m')]),
              ]).single
              as ChatTool;
      expect(tool.result!.text, 'red');
    });
  });

  group('toolSummary', () {
    test('names what each tool works on', () {
      expect(toolSummary('Bash', {'command': 'ls -la'}), 'ls -la');
      expect(
        toolSummary('Bash', {'command': 'ls', 'description': 'List files'}),
        'List files',
      );
      expect(toolSummary('Edit', {'file_path': '/a.dart'}), '/a.dart');
      expect(toolSummary('Grep', {'pattern': 'foo', 'path': '/x'}), 'foo');
      expect(toolSummary('WebFetch', {'url': 'https://x.y'}), 'https://x.y');
      expect(
        toolSummary('Task', {'description': 'Explore', 'prompt': 'p'}),
        'Explore',
      );
      expect(
        toolSummary('AskUserQuestion', {
          'questions': [
            {'question': 'Which one?', 'options': <Object?>[]},
          ],
        }),
        'Which one?',
      );
    });

    test('falls back to the first text input, on one line', () {
      expect(
        toolSummary('mcp__x__y', {'n': 3, 'q': ' first\nsecond'}),
        'first',
      );
      expect(toolSummary('Bash', {'command': 'a\nb'}), 'a');
      expect(toolSummary('Read', {'file_path': '  '}), '');
      expect(toolSummary('X', const {}), '');
    });
  });

  group('the sanitized real transcript', () {
    final lines = File('test/herdr/fixtures/claude_transcript.jsonl')
        .readAsLinesSync();
    final items = parse(lines);

    test('keeps every prompt, reply and tool call, and joins the results', () {
      var prompts = 0, replies = 0, calls = 0, results = 0;
      for (final line in lines) {
        final j = jsonDecode(line) as Map<String, Object?>;
        if (j['isSidechain'] == true || j['isMeta'] == true) continue;
        final content = (j['message'] as Map?)?['content'];
        if (j['type'] == 'user' && content is String) prompts++;
        if (content is! List) continue;
        for (final b in content.cast<Map<String, Object?>>()) {
          if (b['type'] == 'tool_use') calls++;
          if (b['type'] == 'tool_result') results++;
          if (b['type'] == 'text' && j['type'] == 'assistant') replies++;
          if (b['type'] == 'text' && j['type'] == 'user') prompts++;
        }
      }
      expect(calls, greaterThan(10), reason: 'the fixture has tool calls');
      final tools = items.whereType<ChatTool>().toList();
      expect(tools, hasLength(calls));
      expect(tools.where((t) => t.result != null), hasLength(results));
      expect(items.whereType<ChatReply>(), hasLength(replies));
      expect(
        items.whereType<ChatPrompt>().length +
            items.whereType<ChatNote>().length,
        lessThanOrEqualTo(prompts),
      );
      expect(items.first, isA<ChatPrompt>());
    });

    test('reading any line again changes nothing', () {
      // As after a reconnect, which reads the end of the file again.
      for (var seed = 0; seed < 200; seed++) {
        final random = Random(seed);
        final replayed = <String>[];
        for (final (i, line) in lines.indexed) {
          replayed.add(line);
          if (random.nextInt(4) == 0) {
            replayed.add(lines[random.nextInt(i + 1)]);
          }
        }
        expect(parse(replayed), items, reason: 'seed $seed');
      }
    });
  });

  group('ByteLines', () {
    test('cut anywhere, even inside a character, gives the same lines; '
        'a line over the cap is dropped, its bytes counted', () {
      final text = [
        ...File('test/herdr/fixtures/claude_transcript.jsonl')
            .readAsLinesSync(),
        'ünïcødé — 日本語 🙂🙂',
        '',
        'last line',
      ].join('\n');
      final bytes = utf8.encode('$text\n');
      final naive = const LineSplitter().convert(text);
      const cap = 300;
      final kept = [
        for (final line in naive)
          if (utf8.encode(line).length <= cap) line,
      ];
      expect(kept.length, inInclusiveRange(1, naive.length - 1));
      for (final maxLine in [maxTranscriptLine, cap]) {
        final expected = maxLine == cap ? kept : naive;
        for (var seed = 0; seed < 500; seed++) {
          final random = Random(seed);
          final splitter = ByteLines(maxLine: maxLine);
          final lines = <String>[];
          var counted = 0;
          var at = 0;
          while (at < bytes.length) {
            final end = min(bytes.length, at + 1 + random.nextInt(64));
            for (final line in splitter.add(bytes.sublist(at, end))) {
              if (line.bytes case final kept?) lines.add(utf8.decode(kept));
              counted += line.size;
            }
            at = end;
          }
          final reason = 'cap $maxLine, seed $seed';
          expect(lines, expected, reason: reason);
          expect(counted, bytes.length, reason: reason);
          expect(splitter.pending, 0, reason: reason);
        }
      }
    });

    test('keeps a line without its newline until it ends', () {
      final splitter = ByteLines();
      List<String> add(String text) => [
        for (final line in splitter.add(utf8.encode(text)))
          utf8.decode(line.bytes!),
      ];
      expect(add('par'), isEmpty);
      expect(splitter.pending, 3);
      expect(add('tial\nnext'), ['partial']);
      expect(splitter.pending, 4);
      expect(add('\n\n'), ['next', '']);
      expect(splitter.pending, 0);
    });

    test('drops a line over the cap through its newline', () {
      final splitter = ByteLines(maxLine: 4);
      expect(splitter.add(utf8.encode('abc')), isEmpty);
      expect(splitter.add(utf8.encode('de')), isEmpty);
      expect(splitter.pending, 5);
      final lines = splitter.add(utf8.encode('fg\nabcd\n'));
      expect(
        [for (final l in lines) (l.bytes == null, l.size)],
        [(true, 8), (false, 5)],
      );
      expect(utf8.decode(lines.last.bytes!), 'abcd');
    });
  });

  group('ClaudeTranscript.prepend', () {
    /// A random transcript line: prompts, replies, tool calls and results
    /// whose ids repeat across the file, records seen twice, records it
    /// drops, and lines that are no record.
    String randomLine(Random r) {
      String? uuid() => r.nextInt(5) == 0 ? null : 'u${r.nextInt(40)}';
      String toolId() => 't${r.nextInt(12)}';
      return switch (r.nextInt(10)) {
        0 => claudeUser('prompt ${r.nextInt(100)}', uuid: uuid()),
        1 => claudeAssistant([
          claudeText('reply ${r.nextInt(100)}'),
        ], uuid: uuid()),
        2 || 3 => claudeAssistant([
          claudeToolUse(toolId(), 'Bash', {'command': 'c${r.nextInt(9)}'}),
        ], uuid: uuid()),
        4 || 5 => claudeUser([
          claudeToolResult(
            toolId(),
            'out ${r.nextInt(100)}',
            isError: r.nextBool(),
          ),
        ], uuid: uuid()),
        6 => claudeUser(
          'summary',
          uuid: uuid(),
          extra: {'isCompactSummary': true},
        ),
        7 => claudeUser('side', uuid: uuid(), extra: {'isSidechain': true}),
        8 => claudeAssistant([
          {'type': 'thinking', 'thinking': 'hm ${r.nextInt(9)}'},
          claudeToolUse(toolId(), 'Read', {'file_path': '/f'}),
        ], uuid: uuid()),
        _ => r.nextBool() ? '' : 'not json {',
      };
    }

    test('earlier lines put in front give what one read of all gives', () {
      for (var seed = 0; seed < 500; seed++) {
        final r = Random(seed);
        final lines = [for (var i = r.nextInt(60); i > 0; i--) randomLine(r)];
        // Read from a random line, then the lines before it in random
        // pieces, the nearest first, as the stream loads them.
        final cuts = {
          for (var i = r.nextInt(4); i > 0; i--) r.nextInt(lines.length + 1),
        }.toList()..sort();
        final bounds = [0, ...cuts, lines.length];
        final t = ClaudeTranscript();
        lines.skip(bounds[bounds.length - 2]).forEach(t.add);
        for (var i = bounds.length - 2; i > 0; i--) {
          final before = t.items.length;
          final front = t.prepend(lines.sublist(bounds[i - 1], bounds[i]));
          expect(front, inInclusiveRange(0, t.items.length), reason: '$seed');
          expect(
            t.items.length - front,
            lessThanOrEqualTo(before),
            reason: '$seed',
          );
        }
        expect(t.items, parse(lines), reason: 'seed $seed');
        // Lines added after the earlier ones go on as one read would.
        final more = [for (var i = 0; i < 5; i++) randomLine(r)];
        more.forEach(t.add);
        expect(t.items, parse([...lines, ...more]), reason: 'seed $seed');
      }
    });

    test('a result whose call comes in front gets its call', () {
      final t = ClaudeTranscript()
        ..add(claudeUser([claudeToolResult('t1', 'done')], uuid: 'u2'));
      expect(t.items, isEmpty);
      final front = t.prepend([
        claudeAssistant([
          claudeToolUse('t1', 'Bash', {'command': 'ls'}),
        ], uuid: 'u1'),
      ]);
      expect(front, 1);
      expect(t.items, [
        const ChatTool(
          id: 't1',
          name: 'Bash',
          summary: 'ls',
          input: 'ls',
          result: ToolResult('done', isError: false),
        ),
      ]);
    });

    test('a record seen in front drops its later copy', () {
      final t = ClaudeTranscript()..add(claudeUser('again', uuid: 'u1'));
      final front = t.prepend([claudeUser('first', uuid: 'u1')]);
      expect(front, 1);
      expect(t.items, [const ChatPrompt('first')]);
    });

    test('without kept records, nothing goes in front', () {
      final t = ClaudeTranscript()..add(claudeUser('hi', uuid: 'u1'));
      t.keepRecords = false;
      t.add(claudeUser('more', uuid: 'u2'));
      expect(() => t.prepend([claudeUser('early')]), throwsStateError);
      expect(t.items, [const ChatPrompt('hi'), const ChatPrompt('more')]);
    });

    test('lines that are no record change nothing', () {
      final t = ClaudeTranscript()..add(claudeUser('hi', uuid: 'u1'));
      expect(
        t.prepend([
          '',
          'junk',
          claudeUser('side', extra: {'isMeta': true}),
        ]),
        0,
      );
      expect(t.items, [const ChatPrompt('hi')]);
    });
  });

  test('transcriptStart reads only a header', () {
    const h = transcriptHeader;
    expect(transcriptStart('${h}123 0 77'), (size: 123, start: 0, inode: '77'));
    expect(
      transcriptStart('$h   123  5   77 '),
      (size: 123, start: 5, inode: '77'),
    );
    // No file yet; an inode the command could not take back.
    expect(transcriptStart('${h}0 0 -'), (size: 0, start: 0, inode: null));
    expect(transcriptStart('${h}9 0 1;x'), (size: 9, start: 0, inode: null));
    for (final line in [
      '${h}x 0 1',
      '${h}12 -1 1',
      '${h}12 0',
      '${h}12',
      '${h}12 0 1 2',
      '12 0 1',
    ]) {
      expect(transcriptStart(line), isNull, reason: line);
    }
    // A startup file that printed no newline.
    expect(
      transcriptStart('Welcome!${h}12 0 3'),
      (size: 12, start: 0, inode: '3'),
    );
  });
}
