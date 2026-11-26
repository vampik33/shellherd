import 'transcript/claude_transcript.dart';

/// How many lines the text view asks for, one step at a time, when the user
/// scrolls to the top of what the poll read: herdr's `pane.read` gives at
/// most this many in all, herdr-core this many of history and the screen.
/// herdr 0.9.5 gives at most 1000, whatever is asked; herdr-core stops at
/// the end of its scrollback.
const historySteps = [2000, 5000, 10000];

/// How many of the lines compared to find [shown] in a deeper read.
const _anchorLines = 50;

/// How many lines are compared at most where the anchor matches: in
/// repetitive text it can match at each of 10000 lines, and this runs on
/// the UI isolate.
const _maxCompared = 500;

/// How many lines of [deeper], a read of more of the pane's history, come
/// before the first line of [shown], an older read that the user looks at;
/// null when [deeper] does not hold its first lines, or holds them in two
/// places alike.
///
/// Lines are compared with their escape sequences and trailing blanks
/// dropped. New output since [shown] moves its lines up in [deeper], never
/// down, so only places from where they would stand without new output
/// up count. Of those where the first [_anchorLines] lines match, the one
/// whose match goes on longest wins: the screen at the bottom of [shown]
/// changes, the history above does not, and a run of repeated lines at its
/// top also matches shifted by the new output.
int? olderLines(List<String> shown, List<String> deeper) {
  final anchor = shown.length < _anchorLines ? shown.length : _anchorLines;
  if (anchor == 0 || deeper.length < anchor) return null;
  final want = [for (final line in shown.take(_maxCompared)) _key(line)];
  // Most places fail at their first line: strip only the lines compared.
  final keys = List<String?>.filled(deeper.length, null);
  var at = deeper.length - shown.length;
  if (at > deeper.length - anchor) at = deeper.length - anchor;
  int? best;
  var bestRun = 0;
  var tied = false;
  for (; at >= 0; at--) {
    var most = deeper.length - at;
    if (most > want.length) most = want.length;
    var run = 0;
    while (run < most &&
        (keys[at + run] ??= _key(deeper[at + run])) == want[run]) {
      run++;
    }
    if (run < anchor) continue;
    if (run > bestRun) {
      best = at;
      bestRun = run;
      tied = false;
    } else if (run == bestRun) {
      tied = true;
    }
  }
  return tied ? null : best;
}

String _key(String line) => stripAnsi(line).trimRight();
