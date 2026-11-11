import 'dart:convert';
import 'dart:io';

/// The pids of the mosh-servers of this user that run now and were started
/// over the sshd on [sshPort].
///
/// Other test files start mosh-servers at the same time, and the user can
/// have real sessions open: those must neither count nor be killed. Each
/// test's sshd has its own port, which mosh-server keeps in the
/// `SSH_CONNECTION` of its environment.
Set<int> moshServers(int sshPort) {
  final uid = (Process.runSync('id', ['-u']).stdout as String).trim();
  final r = Process.runSync('pgrep', ['-x', '-u', uid, 'mosh-server']);
  return {
    for (final l in (r.stdout as String).split('\n'))
      if (int.tryParse(l.trim()) case final pid?)
        if (_sshServerPort(pid) == sshPort) pid,
  };
}

/// The server port in the `SSH_CONNECTION` ("client port server port") of
/// [pid], or null when the process is gone or has none.
int? _sshServerPort(int pid) {
  final List<int> bytes;
  try {
    bytes = File('/proc/$pid/environ').readAsBytesSync();
  } on FileSystemException {
    return null;
  }
  const key = 'SSH_CONNECTION=';
  final value = utf8
      .decode(bytes, allowMalformed: true)
      .split('\x00')
      .where((v) => v.startsWith(key))
      .firstOrNull
      ?.substring(key.length)
      .split(' ');
  return value?.length == 4 ? int.tryParse(value![3]) : null;
}

/// Kills the mosh-servers of the sshd on [sshPort] that started after
/// [before] was taken, and returns them: a failed test must not leave one
/// running.
Set<int> killMoshServersSince(Set<int> before, int sshPort) {
  final left = moshServers(sshPort).difference(before);
  for (final pid in left) {
    Process.killPid(pid);
  }
  return left;
}
