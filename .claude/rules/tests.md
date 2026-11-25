---
paths:
  - "test/**"
  - "dart_test.yaml"
---

# Tests

- Offline tests use the in-memory servers in test/support (`FakeHerdr` in
  fake_herdr.dart, fake_hc.dart).
- Wait with `until`/`eventually` (test/support/poll.dart), never a fixed
  delay.
- Live tests start their herdr and herdr-core with `HerdrTestSession` and
  `HcTestSession`.
