import 'package:xterm/xterm.dart';

/// Joins the input and the resizes of [terminal] to one shell session,
/// from [bind] until [unbind].
///
/// A later session can bind the same terminal before this one ends; [unbind]
/// then leaves the later session's callbacks in place.
class TerminalBinding {
  TerminalBinding(this.terminal, {required this.send, required this.resize});

  final Terminal terminal;

  /// Takes what the user typed.
  final void Function(String data) send;

  /// Takes the new size of the view.
  final void Function(int width, int height, int pixelWidth, int pixelHeight)
  resize;

  var _bound = false;

  /// Routes the input and the resizes of [terminal] to [send] and [resize].
  void bind() {
    _bound = true;
    terminal.onOutput = _onOutput;
    terminal.onResize = _onResize;
  }

  /// Stops passing input and resizes on, and clears the callbacks of
  /// [terminal] that are still this binding's.
  void unbind() {
    _bound = false;
    if (terminal.onOutput == _onOutput) terminal.onOutput = null;
    if (terminal.onResize == _onResize) terminal.onResize = null;
  }

  void _onOutput(String data) {
    if (_bound) send(data);
  }

  void _onResize(int width, int height, int pixelWidth, int pixelHeight) {
    if (_bound) resize(width, height, pixelWidth, pixelHeight);
  }
}
