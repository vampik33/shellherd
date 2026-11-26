---
paths:
  - "lib/herdr/**"
  - "lib/notify/**"
  - "lib/ui/**"
---

# herdr

- herdr sends no event for a rename or a cwd change, and its JSON API has no
  output stream. The exact pane screen streams over an SSH exec of
  `herdr terminal session observe` (lib/herdr/pane_stream.dart); the text
  view and the fallback poll `pane.read`. At the top of the text view,
  older lines come from deeper reads (`historySteps` in
  lib/herdr/pane_history.dart); herdr 0.9.5's `pane.read` gives at most
  1000 lines, whatever `lines` asks.
- The chat reads Claude Code's transcript over an SSH exec
  (`transcriptCommand` in lib/herdr/transcript/transcript_command.dart).
  herdr keeps only the session id its Claude hook reports, not the path;
  it replaces the id only for a SessionStart of `clear` or `resume`, and
  sends no event for it, so a new session shows at the next snapshot
  refresh (15 s). Claude Code
  writes the transcript with the first message, so the read waits for it;
  until then the pane shows its text. A read starts with the last 2 MiB;
  scrolling up loads the 2 MiB before (`transcriptRangeCommand`; more
  reads only to find the start of a longer line), until about 18 MiB more
  have come.
- herdr-core knows no session: `HcCache` looks it up by the terminal's
  foreground pid in Claude Code's `~/.claude/sessions/<pid>.json`
  (lib/herdr/transcript/claude_sessions.dart), again every 15 s for
  `/clear`. That file is internal to Claude Code; without it the pane
  shows its text.
- The composer's slash commands come from one SSH exec
  (`slashCommandsCommand` in lib/herdr/transcript/slash_commands.dart)
  that prints the frontmatter of Claude Code's command and skill files and
  the plugin and settings JSON; Dart decides which plugins count. Claude
  Code's own commands are a fixed list there, without the ones that open
  a picker in the terminal.
- Don't add a "start herdr" action: a server started over SSH lacks the
  desktop environment.
