import 'package:flutter/foundation.dart';

import '../../ssh/json_file.dart';

/// Whether the chat shows the agent's thinking and tool calls, or only the
/// prompts, the replies and the notes. Hidden until the user shows them;
/// the choice is saved in [_file] under [key], for every chat and the next
/// start of the app.
class ChatDetails extends ValueNotifier<bool> {
  /// Without a file, the choice lasts as long as this object.
  ChatDetails([this._file]) : super(false);

  final JsonFile? _file;

  static const key = 'chat_details';

  /// The user chose, so a late [load] must not undo it.
  var _chosen = false;

  /// Reads the saved choice. A missing or broken file keeps it hidden.
  Future<void> load() async {
    final file = _file;
    if (file == null) return;
    try {
      final saved = (await file.read())[key];
      if (saved is bool && !_chosen) value = saved;
    } catch (e) {
      debugPrint('shellherd: cannot read the chat setting: $e');
    }
  }

  /// Sets the choice and saves it; a failed save keeps it for this run.
  Future<void> choose(bool show) async {
    _chosen = true;
    value = show;
    try {
      await _file?.update((data) => data[key] = show);
    } catch (e) {
      debugPrint('shellherd: cannot save the chat setting: $e');
    }
  }
}
