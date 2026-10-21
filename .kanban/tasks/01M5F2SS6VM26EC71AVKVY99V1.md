---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'EXTRAS-3: SessionDirectory port and its value types in Sources/FoundationModelsExtras/Sessions/'
---
Spec: TestudoApp/features/packages/foundationmodels-extras.md EXTRAS-3; the full design is FoundationModelsMultitool/session.md section 6 (the protocol and the value types, copy them as given) and section 7 (event stream rules). The Router implements the port (ROUTER-3); Multitool's `sessions` tool (MT-2) and `sessions` graph (MT-10) are blocked on it.

## What to build

`Sources/FoundationModelsExtras/Sessions/`, next to `Mail/`:
- enums `SessionKind`, `SessionState`, `SessionOrigin`;
- `SessionSummary`, `SessionQuery`, `SessionAddress`, `SessionMessageSender`, `OutgoingSessionMessage`, `SessionMessage`, `SessionSendReceipt` (with `Outcome`), `SessionStartRequest`, `SessionDirectoryEvent`, `SessionDirectoryError`;
- `protocol SessionDirectory: Sendable` with `sessions(matching:)`, `summary(of:)`, `start(_:)`, `addTags(_:to:)`, `removeTags(_:from:)`, `setTitle(_:of:)` (D84), `send(_:)`, `inbox(of:markRead:)`, `archive(_:by:)`, `events()`.

All types are `Sendable` and `Codable`, use `ULID` for session ids and `MailID` for message ids, and use no Router type and no ACP type. Give public memberwise inits (with sensible defaults for `SessionQuery`: `includesRecorded`, `limit`). One file per type group, doc comments on each public symbol.

## Acceptance criteria

- [ ] All types of session.md section 6 exist with those names and shapes.
- [ ] `Codable` round trip test for each value type, including each enum case of `SessionAddress`, `SessionMessageSender` and `SessionDirectoryEvent`.
- [ ] No import of Router or ACP types in the folder.

#sessions