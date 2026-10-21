---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'EXTRAS-3: SessionDirectory port and its value types in Sources/FoundationModelsExtras/Sessions/'
---
Spec: TestudoApp/features/packages/foundationmodels-extras.md EXTRAS-3; the full design is FoundationModelsMultitool/session.md section 6 (the protocol and the value types, copy them as given, except the rename below) and section 7 (event stream rules). The Router implements the port (ROUTER-3); Multitool's `sessions` tool (MT-2) and `sessions` graph (MT-10) are blocked on it.

## Decisions from the Router session (via the Multitool coordinator)

1. **`SessionOrigin` is named `SessionDirectoryOrigin`.** FoundationModelsHooks has a public `SessionOrigin`, which Router uses (`SessionConfiguration.hookOrigin`). All the other names were checked against the public types of every FoundationModels* package and TestudoApp. None of them clash, so they keep the names of session.md.
2. `Mail` gets no new fields. The Router keeps its own message record (inReplyTo, chain depth, UI client id, read flag). `SessionMessage`, the value that `inbox` returns, still has `inReplyTo` and `from` as section 6 lists them.
3. `send` takes the sender (`SessionMessageSender`: a session id, or the user with a client id), and the directory chooses the body. A UI sender is delivered as `.userMessage(prompt:options:)` with sender `.user`, and a session sender as `.agentMessage(from:content:)`. Write this in the doc comment of `send`.
4. `MailBody` gets no new field for sender details. The directory renders a header into the content.

## What to build

`Sources/FoundationModelsExtras/Sessions/`, next to `Mail/`:
- enums `SessionKind`, `SessionState`, `SessionDirectoryOrigin`;
- `SessionSummary` (its `origin` property has the type `SessionDirectoryOrigin`), `SessionQuery`, `SessionAddress`, `SessionMessageSender`, `OutgoingSessionMessage`, `SessionMessage`, `SessionSendReceipt` (with `Outcome`), `SessionStartRequest`, `SessionDirectoryEvent`, `SessionDirectoryError`;
- `protocol SessionDirectory: Sendable` with `sessions(matching:)`, `summary(of:)`, `start(_:)`, `addTags(_:to:)`, `removeTags(_:from:)`, `setTitle(_:of:)` (D84), `send(_:)`, `inbox(of:markRead:)`, `archive(_:by:)`, `events()`.

All types are `Sendable` and `Codable`, use `ULID` for session ids and `MailID` for message ids, and use no Router type and no ACP type. Give public memberwise inits (with sensible defaults for `SessionQuery`: `includesRecorded`, `limit`). One file per type group, doc comments on each public symbol.

## Acceptance criteria

- [ ] All types of session.md section 6 exist with those names and shapes, with `SessionOrigin` renamed to `SessionDirectoryOrigin`.
- [ ] `Codable` round trip test for each value type, including each enum case of `SessionAddress`, `SessionMessageSender` and `SessionDirectoryEvent`.
- [ ] The doc comment of `send` states decision 3.
- [ ] No import of Router or ACP types in the folder.

#sessions