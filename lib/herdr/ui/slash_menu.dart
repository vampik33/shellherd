import 'dart:math';

import 'package:flutter/material.dart';

import '../../ui/palette.dart';
import '../transcript/slash_commands.dart';

/// The slash commands that match what is typed, above the composer. A tap
/// on one picks it.
class SlashMenu extends StatelessWidget {
  const SlashMenu({
    super.key,
    required this.commands,
    required this.onPick,
    this.note,
  });

  final List<SlashCommand> commands;
  final void Function(SlashCommand) onPick;

  /// A line above the commands, such as that the host's are being read.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    // A third of what the keyboard leaves, at most 240: the key bar and
    // the composer below it must still fit. From the view: the Scaffold
    // takes the keyboard out of the body's MediaQuery.
    final media = MediaQueryData.fromView(View.of(context));
    final room =
        media.size.height - media.viewInsets.bottom - media.padding.vertical;
    return Container(
      constraints: BoxConstraints(maxHeight: min(240, max(0, room / 3))),
      margin: const EdgeInsets.fromLTRB(6, 2, 6, 0),
      decoration: BoxDecoration(
        color: Graphite.popover,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Graphite.border),
      ),
      clipBehavior: Clip.antiAlias,
      // The note stays above the list, which scrolls.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: Text(
                note,
                style: const TextStyle(color: Graphite.dim, fontSize: 12),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [for (final c in commands) _row(c)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(SlashCommand c) => InkWell(
    onTap: () => onPick(c),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '/${c.name}',
                  style: const TextStyle(
                    fontFamily: monoFont,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (c.argumentHint.isNotEmpty)
                  TextSpan(
                    text: '  ${c.argumentHint}',
                    style: const TextStyle(
                      fontFamily: monoFont,
                      color: Graphite.dim,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          if (c.description.isNotEmpty)
            Text(
              c.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Graphite.muted, fontSize: 12),
            ),
        ],
      ),
    ),
  );
}
