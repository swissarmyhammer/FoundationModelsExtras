---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f5k9z5dvwnrnzecz1webv9
  text: 'Research: session.md section 6 lists 14 types plus the protocol; section 7 lists the five event rules (bufferingNewest(256), per-session order, started before stateChanged, subagent events, text limit) — these go into the doc comments of `events()` and `SessionDirectoryEvent`, since a protocol cannot enforce them. Mail/ style: one type per file, `import ULID` only where needed, doc comment on every public member and enum case, public memberwise init with `- Parameters:` docs. ULID and MailID are Codable (MailID as one string). No name of the 15 clashes inside Extras. Tests go in Tests/FoundationModelsExtrasTests/Sessions/ (Swift Testing, parameterized round trips as in OriginTests). Validators: missing_docs on every public decl (incl. enum cases and stored properties), no_magic_numbers, swift-format idioms (UseSynthesizedInitializer applies only to internal inits, so the public inits stay).'
  timestamp: 2026-10-21T12:04:56.421416+00:00
- actor: claude-code
  id: 01m5f5yg7d03xww1z8bnevazrk
  text: |-
    Implementation landed (TDD: the new tests failed to compile first, as the types were missing, then passed).

    Choices to know:
    - One type per file, as in Mail/ (14 source files). `SessionSendReceipt.Outcome` is nested in its receipt.
    - `SessionDirectoryError` also conforms to `Codable`. Section 6 leaves it out, but the card says all types are Codable, and the round trip test covers each case.
    - `SessionQuery.defaultLimit = 20`, the default of `list sessions` in section 8.2. The graph uses 50 (section 11.2) and passes its own limit. `includesRecorded` defaults to false.
    - Public inits: optional fields default to nil, and `SessionStartRequest.tags` and `SessionMessage.isRead` default to `[]` and false.
    - `archive(_:by:)` names its parameter `archiver` inside. The external label stays `by`.
    - The rules of section 7 are written in the doc comments of `events()` and `SessionDirectoryEvent`, because a protocol cannot enforce them.
    - `SessionsSourceBoundaryTests` checks that each file under Sessions/ imports only Foundation and ULID (the no-Router/no-ACP criterion).

    Lint: swiftlint with missing_docs, no_magic_numbers and force_unwrapping reports 0 on both folders. The first run flagged two Date literals in SessionFixtures, and they are now named constants. swift format lint reports 0 for the seven idiom rules.
  timestamp: 2026-10-21T12:11:03.277186+00:00
- actor: claude-code
  id: 01m5f5yk9jg79rajwy6qg0v4jg
  text: |-
    ### implement — changed
    - evidence: 14 new sources in Sources/FoundationModelsExtras/Sessions/ (SessionKind, SessionState, SessionDirectoryOrigin, SessionSummary, SessionQuery, SessionAddress, SessionMessageSender, OutgoingSessionMessage, SessionMessage, SessionSendReceipt, SessionStartRequest, SessionDirectoryEvent, SessionDirectoryError, SessionDirectory) and 10 new test files in Tests/FoundationModelsExtrasTests/Sessions/. `swift test`: every run passed (largest 1442 tests in 149 suites), 0 failures. `swift test --filter Session`: 52 tests in 23 suites passed. The one warning is the build-system "missing creator for mutated node" line from the mlx-swift_Cmlx bundle, which is not from this change.
    - next: /review
  timestamp: 2026-10-21T12:11:06.418718+00:00
position_column: doing
position_ordinal: '80'
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

- [x] All types of session.md section 6 exist with those names and shapes, with `SessionOrigin` renamed to `SessionDirectoryOrigin`.
- [x] `Codable` round trip test for each value type, including each enum case of `SessionAddress`, `SessionMessageSender` and `SessionDirectoryEvent`.
- [x] The doc comment of `send` states decision 3.
- [x] No import of Router or ACP types in the folder.

#sessions