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
- A background service that notifies you when an agent is blocked or done.

## Requirements

- A phone with Android 7.0 or newer.
- On each computer: an SSH server, and herdr or the Herdr desktop app.
  The live pane screen needs herdr 0.9.5 or newer; older versions fall back
  to re-reading the pane.
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

    f4ba4f8c2b4bc3779b32569971dae1d9c4a88071418e92adccfafe90be2a5654

## Security

Private keys and passwords stay on the phone, in storage that the Android
Keystore encrypts, and the app's data is left out of Android backups. A
server's key is trusted on first use, after you confirm its fingerprint; a
changed key stops the connection. See [SECURITY.md](SECURITY.md) for the
details and for how to report a vulnerability.

## Build

Flutter 3.47.9 (the revision in `.metadata`).

Linux desktop, on Ubuntu:

    sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
    flutter run -d linux

Android needs the Android SDK (platform 36, build-tools 36, NDK 28.2.13676358)
and JDK 17 or newer; `flutter doctor` lists what is missing.

## Test

    flutter analyze
    flutter test --exclude-tags herdr,hc,sshd,docker   # offline tests only

Without `--exclude-tags`, the tests also start a throwaway sshd, herdr
server, herdr-core or Docker container (tags in `dart_test.yaml`). A test
whose program is missing skips itself.

## Release

Release builds are signed with the key named in `android/key.properties`
(gitignored, as is the keystore):

    storeFile=<absolute path to the .jks>
    storePassword=...
    keyAlias=...
    keyPassword=...

Without it, `flutter build apk --release` stops. Every release must use the
same key, or it will not install over the previous one. `apksigner` is in the
Android SDK's build-tools:

    flutter build apk --release
    apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk

Compare the certificate SHA-256 with the previous release's APK, then tag
`vX.Y.Z` on main and attach the APK to the GitHub release as `shellherd.apk`.

## License

MIT, see [LICENSE](LICENSE). The bundled fonts, Geist and JetBrains Mono, are
under the SIL Open Font License 1.1 (`assets/fonts`).
