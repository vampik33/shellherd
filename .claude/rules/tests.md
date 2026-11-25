---
paths:
  - "test/**"
  - "dart_test.yaml"
---

# Tests

- Offline tests use the in-memory servers in test/support (`FakeHerdr` in
  fake_herdr.dart, fake_hc.dart). Live tests carry a tag from dart_test.yaml
  and skip when their program is missing.
- Wait with `until`/`eventually` (test/support/poll.dart), never a fixed
  delay.
- Never touch the user's own herdr or herdr-core: use the throwaway sessions
  `HerdrTestSession` and `HcTestSession`, which run `hc` without the
  `HC_TERMINAL_*` variables and with `HC_SESSION=<name>`.
