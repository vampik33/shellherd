import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One JSON object kept in one file.
///
/// A write goes to a temporary file first and then replaces the file with a
/// rename, so a crash never leaves half a file. [update] calls run one at a
/// time, so two changes cannot overwrite each other.
///
/// A file that is not a JSON object is an error, not an empty store: the
/// app must not silently drop saved hosts or trusted host keys.
class JsonFile {
  JsonFile(this.file);

  final File file;

  Future<void> _last = Future.value();

  Future<Map<String, Object?>> read() async {
    if (!await file.exists()) return {};
    final Object? data;
    try {
      data = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw FormatException('${file.path}: ${e.message}');
    }
    if (data is! Map<String, Object?>) {
      throw FormatException('${file.path}: not a JSON object');
    }
    return data;
  }

  /// Reads the object, lets [change] edit it in place, and writes it back.
  Future<void> update(void Function(Map<String, Object?> data) change) =>
      updateIf((data) {
        change(data);
        return true;
      });

  /// [update] that writes only if [change] returns true. Its result is what
  /// [change] returned.
  Future<bool> updateIf(bool Function(Map<String, Object?> data) change) {
    final done = _last.then((_) async {
      final data = await read();
      final changed = change(data);
      if (changed) await _write(data);
      return changed;
    });
    _last = done.catchError((_) => false); // A failed update must not block the next.
    return done;
  }

  Future<void> _write(Map<String, Object?> data) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
