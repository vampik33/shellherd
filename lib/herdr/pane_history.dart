import 'transcript/claude_transcript.dart';

/// How many lines the text view asks for, one step at a time, when the user
/// scrolls to the top of what the poll read: herdr's `pane.read` gives at
/// most this many in all, herdr-core this many of history and the screen.
/// herdr 0.9.5 gives at most 1000, whatever is asked; herdr-core stops at
/// the end of its scrollback.
const historySteps = [2000, 5000, 10000];

/// How many of the lines compared to find [shown] in a deeper read.
const _anchorLines = 50;

/// How many lines of [deeper], a read of more of the pane's history, come
/// before the first line of [shown], an older read that the user looks at;
/// null when [deeper] does not hold its first lines.
///
/// Only the first lines of [shown] are compared, with their escape
/// sequences and trailing blanks dropped: the screen at its bottom changes,
/// the history above does not. New output since [shown] moves its lines up
/// in [deeper], never down, so the search starts where they would stand
/// without new output and goes up, to the nearest match.
int? olderLines(List<String> shown, List<String> deeper) {
  final anchor = shown.length < _anchorLines ? shown.length : _anchorLines;
  if (anchor == 0 || deeper.length < anchor) return null;
  final want = [for (final line in shown.take(anchor)) _key(line)];
  final keys = [for (final line in deeper) _key(line)];
  var at = deeper.length - shown.length;
  if (at > deeper.length - anchor) at = deeper.length - anchor;
  for (; at >= 0; at--) {
    var match = true;
    for (var i = 0; i < anchor && match; i++) {
      match = keys[at + i] == want[i];
    }
    if (match) return at;
  }
  return null;
}

String _key(String line) => stripAnsi(line).trimRight();
