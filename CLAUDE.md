# shellherd

@README.md

The README is the source for build, test, contributing and release steps;
this file adds only what agents need. Area rules are in `.claude/rules/`.

## Commands

```sh
xvfb-run -a flutter run -d linux   # no display; send q on stdin to quit
sg docker -c "flutter test"        # full suite, ~90 s
```

Run plain `flutter test` once `id -nG` lists docker.

## Layout

- lib/ssh: hosts, keys, known_hosts, secret store, SshConnector (password,
  key, Tailscale `none` auth)
- lib/herdr/api: herdr client (NDJSON, one request per connection) and hc
  client (herdr-core JSON-RPC, persistent)
- lib/herdr: caches, links, PaneApi (server_api.dart) shared by both
  backends; ui/ = screens
- lib/terminal: SSH and mosh shell sessions, key bar
- lib/notify: AgentWatcher per host, WatchHub; on Android it runs in a
  foreground-service isolate (background_service.dart)
- lib/ui: host list, host form, host-key and Tailscale check dialogs
- test/support: fakes, throwaway servers and wait helpers for the tests

## Rules

- Bound every SSH channel open and exec with `boundedOpen`
  (lib/bounded_open.dart): dartssh2 keepalive has no reply deadline, so a
  stalled link hangs forever.
