/// Reads Claude Code's slash commands over a real SSH connection to a
/// throwaway sshd on 127.0.0.1, from a throwaway CLAUDE_CONFIG_DIR, never
/// the user's ~/.claude. Skipped when `sshd` is missing.
/// Run alone with: flutter test test/herdr/slash_commands_live_test.dart
@Tags(['sshd'])
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/transcript/slash_commands.dart';

import '../support/test_sshd.dart';

void main() {
  final skip = TestSshd.binary == null ? 'sshd is not installed' : null;

  late Directory root;
  late TestSshd sshd;
  late SSHClient ssh;
  TestSshd? startedSshd;
  SSHClient? openSsh;

  void put(String path, String content) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  setUpAll(() async {
    if (skip != null) return;
    root = await Directory.systemTemp.createTemp('shellherd-slash-');
    final config = '${root.path}/config';
    put('$config/commands/mine.md', '---\ndescription: Mine\n---\n');
    put('$config/skills/learn/SKILL.md', '---\ndescription: Learn\n---\n');
    put(
      '${root.path}/project/.claude/commands/proj.md',
      '---\nargument-hint: [x]\n---\n',
    );
    sshd = startedSshd = await TestSshd.start(
      env: {'CLAUDE_CONFIG_DIR': config},
    );
    ssh = openSsh = await sshd.connect();
  });
  tearDownAll(() async {
    openSsh?.close();
    await startedSshd?.stop();
    if (skip == null) await root.delete(recursive: true);
  });

  test('finds the user\'s and the project\'s commands', skip: skip, () async {
    final lookup = sshSlashCommandLookup(ssh);
    expect(await lookup('${root.path}/project'), const [
      SlashCommand('proj', argumentHint: '[x]'),
      SlashCommand('mine', description: 'Mine'),
      SlashCommand('learn', description: 'Learn'),
    ]);
    expect(await lookup(null), const [
      SlashCommand('mine', description: 'Mine'),
      SlashCommand('learn', description: 'Learn'),
    ]);
  });
}
