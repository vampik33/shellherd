import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/terminal/terminal_binding.dart';
import 'package:xterm/xterm.dart';

/// A binding that records what reaches it.
class _Recorded {
  _Recorded(Terminal terminal) {
    binding = TerminalBinding(
      terminal,
      send: sent.add,
      resize: (w, h, _, _) => sizes.add((w, h)),
    );
  }

  late final TerminalBinding binding;
  final sent = <String>[];
  final sizes = <(int, int)>[];
}

void main() {
  late Terminal terminal;

  setUp(() => terminal = Terminal());

  test('bind routes input and resizes', () {
    final a = _Recorded(terminal)..binding.bind();
    terminal.textInput('ls');
    terminal.resize(100, 30);
    expect(a.sent, ['ls']);
    expect(a.sizes, [(100, 30)]);
  });

  test('after unbind, input and resizes are dropped', () {
    final a = _Recorded(terminal)..binding.bind();
    final onOutput = terminal.onOutput!;
    final onResize = terminal.onResize!;
    a.binding.unbind();
    expect(terminal.onOutput, isNull);
    expect(terminal.onResize, isNull);
    // A callback someone kept from before still finds the binding closed.
    onOutput('late');
    onResize(90, 20, 0, 0);
    expect(a.sent, isEmpty);
    expect(a.sizes, isEmpty);
  });

  test('unbinding twice is harmless', () {
    final a = _Recorded(terminal)..binding.bind();
    a.binding
      ..unbind()
      ..unbind();
    expect(terminal.onOutput, isNull);
    expect(terminal.onResize, isNull);
  });

  test('unbinding after a later binding leaves the later one working', () {
    final a = _Recorded(terminal)..binding.bind();
    final b = _Recorded(terminal)..binding.bind();
    a.binding.unbind();
    terminal.textInput('pwd');
    terminal.resize(120, 40);
    expect(b.sent, ['pwd']);
    expect(b.sizes, [(120, 40)]);
    expect(a.sent, isEmpty);
    expect(a.sizes, isEmpty);
  });

  test('unbind before any bind leaves the callbacks of others', () {
    final typed = <String>[];
    final sized = <int>[];
    terminal
      ..onOutput = typed.add
      ..onResize = (w, _, _, _) => sized.add(w);
    _Recorded(terminal).binding.unbind();
    terminal.textInput('x');
    terminal.resize(70, 20);
    expect(typed, ['x']);
    expect(sized, [70]);
  });
}
