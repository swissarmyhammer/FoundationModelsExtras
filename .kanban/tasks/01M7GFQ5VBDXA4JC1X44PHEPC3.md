---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7gg21rpat082pg33avb15gn
  text: |-
    ### test — green
    - evidence: `swift test`: 1860 tests in 178 suites passed, 34 tests in 3 suites passed. The new suite InMemorySessionDirectoryPinTests has 10 tests.
    - next: commit, then push when the CI queue of Extras is empty. RouterSessionDirectory and the ForwardingSessionDirectory of Multitool must add setPinned and markUsed.
  timestamp: 2026-11-15T20:58:23.382297+00:00
position_column: done
position_ordinal: ffe680
title: 'SessionDirectory port: pin, unpin and last use of a session (EXTRAS-3 Step 2)'
---
## What
Add the pin and the last use of a session to the `SessionDirectory` port (D118, D184). Multitool (MT-2, MT-10) and the Router (ROUTER-3) need it.

- `SessionSummary.pinnedAt: Date?` (the pin order), the computed `isPinned`, and `SessionSummary.lastUsedAt: Date?`. A summary encoded before these fields decodes with `nil`.
- `SessionDirectory.setPinned(_:of:)` and `SessionDirectory.markUsed(_:)`. Each sends `factsChanged` when the summary changes. A second pin keeps the first `pinnedAt`.
- `SessionQuery.pinned: Bool?` (a filter) and `SessionQuery.order: SessionOrder` (`newestFirst`, `pinOrder`, `lastUsedFirst`).
- `InMemorySessionDirectory` supports all of this. A test sets a fixed `lastUsedAt` with `register(_:)` or with the `now` clock.

The port has no storage rule. The Router keeps the values where it decides (a machine-local usage store, not the recordings).

## Acceptance
- [ ] The new fields, methods, filter and order are on the port, with doc comments.
- [ ] `InMemorySessionDirectory` implements them.
- [ ] Tests cover pin, a second pin, unpin, mark used, the events, the filter, both orders and the decode of an old summary.
- [ ] `swift test` passes. #feature