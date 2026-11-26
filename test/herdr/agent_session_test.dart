import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';

import '../support/fake_snapshots.dart';

Pane _pane(Object? session) => Pane.fromJson(
  fakePane('w1:p1', 'w1', 'working', {
    'agent': 'claude',
    'agent_session': session,
  }),
);

void main() {
  test('a Claude session id is the session of the pane', () {
    // What herdr keeps when its Claude hook reports both id and path.
    final pane = _pane({
      'source': 'herdr:claude',
      'agent': 'claude',
      'kind': 'id',
      'value': '0d6c1f3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f',
    });
    expect(pane.agentSession?.kind, AgentSessionKind.id);
    expect(
      pane.agentSession?.claudeSession,
      '0d6c1f3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f',
    );
  });

  test('a path, another agent or an unknown kind gives no session', () {
    for (final session in [
      {'source': 's', 'agent': 'claude', 'kind': 'path', 'value': '/x.jsonl'},
      {'source': 's', 'agent': 'codex', 'kind': 'id', 'value': 'abc'},
      {'source': 's', 'agent': 'claude', 'kind': 'socket', 'value': 'abc'},
    ]) {
      final pane = _pane(session);
      expect(pane.agentSession, isNotNull);
      expect(pane.agentSession!.claudeSession, isNull, reason: '$session');
    }
    expect(
      _pane({'source': 's', 'agent': 'claude', 'kind': 'socket', 'value': 'x'})
          .agentSession!
          .kind,
      AgentSessionKind.unknown,
    );
  });

  test('a missing or malformed session is none, not a broken snapshot', () {
    for (final session in [
      null,
      'id',
      42,
      {'agent': 'claude', 'kind': 'id'},
      {'source': 's', 'agent': 'claude', 'kind': 7, 'value': 'abc'},
    ]) {
      expect(_pane(session).agentSession, isNull, reason: '$session');
    }
  });
}
