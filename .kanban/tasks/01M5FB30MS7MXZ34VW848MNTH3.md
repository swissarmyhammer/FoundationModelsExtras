---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5fb51my3egtyb7z64811jsx
  text: 'Research: `InMemorySessionDirectory` is the only conformer of `SessionDirectory` in this package. Messages live in `InMemorySessionDirectoryState.deliveries: [ULID: [Delivery]]`, keyed by recipient, each `Delivery.message` carrying its `isRead` flag (set by `inbox(markRead: true)`). Plan: protocol requirement + doc in SessionDirectory.swift; a non-mutating `message(_:to:)` on the state in InMemorySessionDirectoryState+Messages.swift (looks only in `deliveries[recipient]`, so another session''s mail is unreachable); public forwarding method in InMemorySessionDirectory.swift beside `inbox`. Tests in a new InMemorySessionDirectoryMessageLookupTests.swift using InMemorySessionDirectoryFixtures.'
  timestamp: 2026-10-21T13:42:00.606175+00:00
- actor: claude-code
  id: 01m5fb8p74c0rb9eqjb6nda4b1
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsExtras/Sessions/SessionDirectory.swift (requirement + doc comment), Sources/FoundationModelsExtras/Sessions/InMemorySessionDirectory.swift (public `message(_:to:)`), Sources/FoundationModelsExtras/Sessions/InMemorySessionDirectoryState+Messages.swift (state lookup in `deliveries[recipient]`), Tests/FoundationModelsExtrasTests/Sessions/InMemorySessionDirectoryMessageLookupTests.swift (4 tests, new). RED: compile failure "no member 'message'". GREEN: `swift test --filter InMemorySessionDirectoryMessageLookupTests` 4/4. Full `swift test`: 1509 tests in 155 suites passed, 0 failures. The one build line `warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle` is SwiftPM build-graph output for the mlx dependency bundle and was already there, not a compiler warning from this change.
    - note: an unknown recipient gives nil (no throw), since the spec makes the lookup a nil-or-message answer; `inbox` still throws unknownSession.
    - next: /review
  timestamp: 2026-10-21T13:43:59.972506+00:00
position_column: doing
position_ordinal: '80'
title: 'SessionDirectory.message(_:to:): look up a delivered message by id (EXTRAS-3 amendment)'
---
This amends EXTRAS-3 and EXTRAS-4. The Multitool coordinator asked for it while building the `reply message` op of the sessions tool.

**Problem:** `reply message` takes `inReplyTo`, the id of a message that `read inbox` returned. `inbox(of:markRead:)` returns only unread messages and marks them read, and the port has no lookup by id. So after a read, the tool can't find the original sender to reply to. Multitool works around this with an in-memory record (Multitool card ^nv64e95 removes it once this lands). The Router session is told in parallel (^6peyqxn / ^17nh345). The Router keeps messages.jsonl for each target.

## Work
- Add this requirement to `SessionDirectory` (Sources/FoundationModelsExtras/Sessions/SessionDirectory.swift):
  `func message(_ id: MailID, to recipient: ULID) async throws -> SessionMessage?`
  It returns the message, read or unread, only if it was delivered to `recipient`. It returns `nil` when the id is unknown or was delivered to another session, so a session can't read the mail of other sessions. The doc comment states this, and says that a lookup marks nothing read.
- Implement it in `InMemorySessionDirectory`.
- `MailID` is already the id type of `SessionMessage.id`.

## Acceptance criteria
- [x] An unread message is found for its recipient, and the lookup leaves it unread.
- [x] A message is still found after `inbox(markRead: true)` read it.
- [x] A message delivered to another session gives `nil`, and so does an unknown id.
- [x] Doc comment on the protocol requirement.

#sessions