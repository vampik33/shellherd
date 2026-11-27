import 'package:flutter/material.dart';

import '../../ui/palette.dart';
import '../earlier_load.dart';

/// The top of a list that starts after the start of what it shows, such
/// as a chat cut at the start of its transcript: it loads [what] once it is
/// built, near the top of the screen, or says why it does not.
class EarlierRow extends StatelessWidget {
  const EarlierRow(
    this.state,
    this.onLoad, {
    super.key,
    this.what = 'Earlier messages',
  });

  final EarlierLoad state;

  /// Null where nothing can load them.
  final VoidCallback? onLoad;

  /// What loads, as a sentence starts it, such as "Earlier messages".
  final String what;

  @override
  Widget build(BuildContext context) {
    final load = onLoad;
    if (load == null) return _Note('$what are not shown.');
    switch (state) {
      case EarlierLoad.idle:
        // Not during the build: the load changes what the list shows.
        WidgetsBinding.instance.addPostFrameCallback((_) => load());
        return _Loading(what.toLowerCase());
      case EarlierLoad.loading:
        return _Loading(what.toLowerCase());
      case EarlierLoad.failed:
        return InkWell(
          onTap: load,
          child: _Note('Cannot load ${what.toLowerCase()}. Tap to try again.'),
        );
      case EarlierLoad.capped:
        return _Note('$what are not loaded.');
      case EarlierLoad.none:
        return _Note('$what are not shown.');
    }
  }
}

class _Loading extends StatelessWidget {
  const _Loading(this.what);

  final String what;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(
          'Loading $what…',
          style: const TextStyle(fontSize: 12, color: Graphite.dim),
        ),
      ],
    ),
  );
}

/// One line that says why nothing loads.
class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12, color: Graphite.dim),
    ),
  );
}
