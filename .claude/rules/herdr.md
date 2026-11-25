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
- Don't add a "start herdr" action: a server started over SSH lacks the
  desktop environment.
