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
- `find.text` also matches a text field's value: after a form closes, wait
  for a widget only the next screen has (`app_flow_live_test`, #9).
- Some test files are not `dart format`-clean: format only the lines you
  change.
