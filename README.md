# shellherd

Android app (Linux desktop for development) that logs in to hosts over SSH,
opens a terminal (SSH or mosh), and watches coding agents in herdr panes.

## Build

Flutter 3.47.9 (the revision in `.metadata`).

Linux desktop, on Ubuntu:

    sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
    flutter run -d linux

Android needs the Android SDK (platform 36, build-tools 36, NDK 28.2.13676358)
and JDK 17 or newer; `flutter doctor` lists what is missing.

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
