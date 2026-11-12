# shellherd

Flutter app (Android; Linux desktop for development) that logs in to hosts over SSH, opens a terminal (SSH or mosh), and watches coding agents in herdr panes, with notifications.

## Commands

```bash
flutter run -d linux                                   # desktop build for development
flutter analyze                                        # must be clean
flutter test                                           # everything, ~70 s; live tests skip if their program is missing
flutter test --exclude-tags herdr,hc,sshd,docker       # offline only
```

Tags (dart_test.yaml): `herdr` starts a throwaway herdr server, `hc` a throwaway herdr-core,
`sshd` an unprivileged sshd (test/support/test_sshd.dart), `docker` OpenSSH+PAM in Docker (first run builds the image, needs network).

## Layout

- lib/ssh: hosts, keys, known_hosts, secret store, SshConnector (password, key, Tailscale `none` auth)
- lib/herdr/api: herdr client (NDJSON, one request per connection) and hc client (herdr-core JSON-RPC, persistent)
- lib/herdr: caches, links, PaneApi (server_api.dart) shared by both backends; ui/ = screens
- lib/terminal: SSH and mosh shell sessions, key bar
- lib/notify: AgentWatcher per host, WatchHub; on Android it runs in a foreground-service isolate (background_service.dart)
- lib/ui: host list, host form, host-key and Tailscale check dialogs
- docs/plan/shellherd-plan.html: design and build plan (edit this one; *.packed.html and *.artifact.html are ignored build outputs)
- test/support: fake_herdr/fake_hc for offline tests; wait with `until`/`eventually` (poll.dart), not fixed delays

## Gotchas

- Bound every SSH channel open/exec yourself: dartssh2 keepalive has no reply deadline, a stalled link hangs forever.
- Tests must never touch the user's own herdr-core: run `hc` without HC_TERMINAL_* vars and with HC_SESSION=<name> (HcTestSession does).
- herdr reports no event for rename/cwd change and its JSON API has no output stream: the exact screen streams over an SSH exec of `herdr terminal session observe` (lib/herdr/pane_stream.dart), the text view and the fallback poll pane.read.
- dart_mosh is pinned to 0.0.4 and wrapped (ServerOnlyCipher); re-audit before bumping.
- Don't add a "start herdr" action: a server started over SSH lacks the desktop environment.
- Repo will be public: no secrets, home paths, emails or IPs in tracked files.

## Workflow

- Commit subjects: short imperative sentence ("Find the hc socket where hc puts it"); version bumps are "Bump the version to X.Y.Z+N".
- PRs from branches, merged with merge commits.
