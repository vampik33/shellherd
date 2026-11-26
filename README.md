# shellherd

An Android app that logs in to your computers over SSH, opens a terminal
(SSH or mosh), and watches coding agents running in [herdr](https://herdr.dev)
panes. It notifies you when an agent needs you or has finished. A Linux
desktop build exists for development.

shellherd is an independent project and is not affiliated with herdr.

## Features

- Saved hosts that log in with an SSH key (made on the phone, or an imported
  OpenSSH, RSA or EC key), a password, or Tailscale SSH.
- A terminal over SSH or mosh, with a bar of extra keys.
- The agents of herdr or of the Herdr desktop app (herdr-core) and their
  panes; a herdr pane's screen updates live as it changes.
- A Claude Code agent in herdr or the Herdr app shows as a chat: its
  prompts, replies and tool calls, read from its transcript. Other panes
  show their text.
- A background service that notifies you when an agent is blocked or done.

## Requirements

- A phone with Android 7.0 or newer.
- On each computer: an SSH server, and herdr or the Herdr desktop app.
  The live pane screen needs herdr 0.9.5 or newer; older versions fall back
  to re-reading the pane. In herdr the chat needs herdr's Claude
  integration (`herdr integration install claude`); the Herdr app needs
  nothing more.
- Optional: `mosh-server` for mosh terminals, Tailscale for Tailscale SSH.

## Install

shellherd is not on Google Play. Download `shellherd.apk` from the
[latest release](https://github.com/vampik33/shellherd/releases/latest) and
open it on the phone; Android asks you to allow installs from the browser or
file manager you opened it with. A newer APK installs over the old one and
keeps your hosts and keys.

Every release is signed with the same key. To check an APK before you install
it, compare its certificate with this SHA-256
(`apksigner verify --print-certs shellherd.apk`):

```text
f4ba4f8c2b4bc3779b32569971dae1d9c4a88071418e92adccfafe90be2a5654
```

## Security

Private keys and passwords are stored on the phone, encrypted with a key in
the Android Keystore, and the app's data is left out of Android backups.
Private keys never leave the phone; a password goes only to the server you
log in to, once its key matches the one you trusted.
[SECURITY.md](SECURITY.md) has the details and how to report a vulnerability.

## Development

### Build

Use the Flutter version that CI pins (`flutter-version` in
[.github/workflows/ci.yml](.github/workflows/ci.yml)).

Linux desktop, on Ubuntu:

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
flutter run -d linux
```

If the first Linux build failed (for example, without libsecret), it cached
the wrong install prefix: delete `build/linux` and build again.

Android needs the Android SDK (platform 36, build-tools 36, NDK 28.2.13676358)
and JDK 17 or newer; `flutter doctor` lists what is missing.

### Test

CI runs these two on every pull request; both must pass:

```sh
flutter analyze
flutter test --exclude-tags herdr,hc,sshd,docker   # offline tests only
```

Plain `flutter test` also runs the live tests, which start a throwaway sshd,
herdr server, herdr-core or Docker container (tags in
[dart_test.yaml](dart_test.yaml)). A test whose program is missing skips
itself. The Docker tests need Docker and the password and Tailscale login
tests need paramiko:

```sh
sudo apt install docker.io python3-paramiko
sudo usermod -aG docker $USER   # gives root-equivalent access
```

Until you log in again, a shell without the docker group runs the suite as
`sg docker -c "flutter test"`.

### Contributing

- Work on a branch and open a pull request; pull requests are merged with
  merge commits.
- Commit subjects are short imperative sentences ("Find the hc socket where
  hc puts it"). A version bump is its own commit, "Bump the version to
  X.Y.Z+N", in `pubspec.yaml`.
- The repository is public: no secrets, home paths, email addresses or IP
  addresses in tracked files.

### Release

Release builds are signed with the key named in `android/key.properties`
(gitignored, as is the keystore). Without it, `flutter build apk --release`
stops.

```properties
storeFile=<absolute path to the .jks>
storePassword=...
keyAlias=...
keyPassword=...
```

1. Merge the version bump to main, then build from that commit on a clean
   tree (the last command must print nothing):

   ```sh
   git switch main && git pull --ff-only && git status --short
   ```

2. Build the APK and print its signing certificate (`apksigner` is in the
   Android SDK's build-tools):

   ```sh
   flutter build apk --release
   apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
   ```

3. Check that the certificate SHA-256 matches the one under
   [Install](#install). An APK signed with another key does not install over
   the previous release.
4. Tag the commit you built (`git rev-parse HEAD`), not whatever main is
   then, with an annotated tag `vX.Y.Z` (no `+N`) whose message is
   "shellherd X.Y.Z", and push it.
5. Make a GitHub release from the tag, named "shellherd X.Y.Z", with the APK
   as its only asset, `shellherd.apk`. The notes start with
   "Covers X.Y.Z (#PR)" and end with an Install section that says which
   release's key signed it.

## License

MIT, see [LICENSE](LICENSE). The bundled fonts, Geist and JetBrains Mono, are
under the SIL Open Font License 1.1 (`assets/fonts`).
