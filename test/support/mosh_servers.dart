import 'dart:io';

/// The pids of the mosh-servers of this user that run now.
Set<int> moshServers() {
  final uid = (Process.runSync('id', ['-u']).stdout as String).trim();
  final r = Process.runSync('pgrep', ['-x', '-u', uid, 'mosh-server']);
  return {
    for (final l in (r.stdout as String).split('\n')) ?int.tryParse(l.trim()),
  };
}

/// Kills the mosh-servers that started after [before] was taken, and
/// returns them: a failed test must not leave one running.
Set<int> killMoshServersSince(Set<int> before) {
  final left = moshServers().difference(before);
  for (final pid in left) {
    Process.killPid(pid);
  }
  return left;
}
