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
  view and the fallback poll `pane.read`.
- The chat reads Claude Code's transcript over an SSH exec
  (`transcriptCommand` in lib/herdr/transcript/transcript_command.dart). herdr keeps only the
  session id its Claude hook reports, not the path; it replaces the id only
  for a SessionStart of `clear` or `resume`, and sends no event for it,
  so a new session shows at the next snapshot refresh (15 s). Claude Code
  writes the transcript with the first message, so the read waits for it;
  until then the pane shows its text.
- Don't add a "start herdr" action: a server started over SSH lacks the
  desktop environment.
