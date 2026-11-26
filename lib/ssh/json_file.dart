import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One JSON object kept in one file.
///
/// A write goes to a temporary file of its own first and then replaces the
/// file with a rename, so a crash or another writer never leaves half a
/// file. [update] calls run one at a time, and each holds an exclusive lock
/// on `<file>.lock` from its read to its rename, so two changes cannot
/// overwrite each other, also from another process such as a second
/// instance of the desktop app. The lock is per process: isolates of one
/// process do not wait for each other.
///
/// A file that is not a JSON object is an error, not an empty store: the
/// app must not silently drop saved hosts or trusted host keys.
class JsonFile {
  JsonFile(this.file);

  final File file;

  Future<void> _last = Future.value();

  /// The object as of the last [update] started before this call: a read
  /// waits for the updates already queued.
  Future<Map<String, Object?>> read() async {
    await _last;
    return _read();
  }

  Future<Map<String, Object?>> _read() async {
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
    final done = _last.then(
      (_) => _locked(() async {
        final data = await _read();
        final changed = change(data);
        if (changed) await _write(data);
        return changed;
      }),
    );
    _last = done.catchError((_) => false); // A failed update must not block the next.
    return done;
  }

  /// Runs [body] while this process holds the lock file.
  Future<T> _locked<T>(Future<T> Function() body) async {
    await file.parent.create(recursive: true);
    final lock = await File('${file.path}.lock').open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      return await body();
    } finally {
      // Closing releases the lock.
      await lock.close();
    }
  }

  Future<void> _write(Map<String, Object?> data) async {
    // Unique per write, also between isolates of one process.
    final tmp = File('${file.path}.$pid.${_random.nextInt(1 << 32)}.tmp');
    try {
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  static final _random = Random();
}
