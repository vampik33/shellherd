---
paths:
  - "lib/main.dart"
  - "lib/notify/**"
  - "test/notify/**"
---

# Notifications

- Choose platform behaviour by `Platform.isAndroid`, read once in `main()`,
  not by `defaultTargetPlatform`: a debug build can emulate another platform.
- The flutter_local_notifications facade dispatches by
  `defaultTargetPlatform`, so `LocalNotifier` calls the Linux plugin
  directly.
- The Linux plugin learns a notification's desktop id only from the answer
  to `Notify` and keeps one per id: Linux show/cancel go through `_inOrder`
  (per-id order, deadline, held shows). Keep its tests' fake modelling that.
