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
- Live tests use the throwaway sessions `HerdrTestSession` and
  `HcTestSession`, never the user's own herdr or herdr-core (see CLAUDE.md).
