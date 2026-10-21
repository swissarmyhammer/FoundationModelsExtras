---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f2zr7k1b7c76g7d0ajdcnv
  text: 'Research: GraphQL toolkit lives in Sources/FoundationModelsExtras/GraphQL/. `API.subscribe(to:...)` (GraphQLRun.swift) maps the engine result stream through `AsyncThrowingStream.encoding`, which today does `finish(throwing:)` on any error — so a CodedError thrown by a subscription source stream (GraphQLSwift `subscribe` re-throws the source error out of the result stream) reaches the caller as a bare Swift error, NOT as a response with `extensions.code`. To meet "RESYNC_REQUIRED that ends a subscription reaches the caller with extensions.code", `encoding` must turn a thrown CodedError into a final `{errors:[...]}` response and then finish. ExampleGraph has no Subscription type; the end-to-end test builds its own small Graphiti API with a `noteChanges(after:)` subscription field so the existing ExampleGraph tests do not change. No Deque in the target deps (only OrderedCollections), so the ChangeLog buffer is an Array trimmed from the front. Settled with consumers: element `ChangeLogEntry<Event> { cursor, at: Date, event }`; `after: nil` = live only; unparseable cursor = RESYNC_REQUIRED; buffer size is an init argument with a default.'
  timestamp: 2026-10-21T11:19:18.515162+00:00
- actor: claude-code
  id: 01m5f3dw2yfqs7cyf9g7tptxde
  text: |-
    Implementation landed (not committed). New: Sources/FoundationModelsExtras/GraphQL/ChangeLog.swift (ChangeLogEntry<Event> {cursor, at: Date, event}; internal ChangeLogCursor, wire text `<epoch>:<sequence>`, epoch = UUID per instance, empty-log cursor = sequence 0; actor ChangeLog<Event> with init(capacity: Int = 1024), append(_:) -> entry (@discardableResult), cursor, changes(after:where:)). Sources/FoundationModelsExtras/GraphQL/IDChange.swift (optional helper: ChangedIDs event + IDChange for the shared <Noun>Change shape, at: DateTime). CodedError.swift: notFound(kind:id:) -> NOT_FOUND, resyncRequired(reason:) -> RESYNC_REQUIRED. GraphQLRun.swift: `encoding` now turns a CodedError that ends the subscription source stream into one last `{errors:[...]}` response with extensions.code, then finishes (other errors still finish(throwing:)) — needed because GraphQLSwift rethrows source-stream errors raw.
    Design notes: changes() is actor-isolated, so the replay and the subscriber registration are atomic (no gap, no repeat between replay and live). A cursor equal to newest - buffer.count replays the whole buffer (no event lost); anything older is RESYNC. Each subscriber stream uses .bufferingOldest(capacity); a `.dropped` yield ends that stream with RESYNC_REQUIRED after the buffered events (slow subscriber can't silently lose events). Terminated streams are removed both on onTermination (weak-self Task hop) and on a `.terminated` yield.
    TDD note: the ChangeLog unit tests were written before the code but their compile-RED run was skipped (code written before the first run); the e2e subscription test was watched RED (stream threw the bare error) before the GraphQLRun change.
  timestamp: 2026-10-21T11:27:01.214628+00:00
- actor: claude-code
  id: 01m5f3dzdarkdtkpqkm0hgb3p7
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsExtras/GraphQL/ChangeLog.swift (new), Sources/FoundationModelsExtras/GraphQL/IDChange.swift (new), Sources/FoundationModelsExtras/GraphQL/CodedError.swift, Sources/FoundationModelsExtras/GraphQL/GraphQLRun.swift, Tests/FoundationModelsExtrasTests/GraphQL/ChangeLogTests.swift (new), Tests/FoundationModelsExtrasTests/GraphQL/ChangeLogSubscriptionTests.swift (new), Tests/FoundationModelsExtrasTests/GraphQL/GraphQLResponseConventionTests.swift. `swift test`: all runs passed (1403 + 410 + 131 + 44 + 40 + 26 tests, 0 failures); the only warning is the SwiftPM "missing creator for mutated node" on the mlx-swift_Cmlx bundle, which no source file of this change produces.
    - next: /review
  timestamp: 2026-10-21T11:27:04.618756+00:00
- actor: claude-code
  id: 01m5f3rz9xkbqxe37k1x02ms1w
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (f126153) — 0 findings, 0 confirmed, 1 refuted, 7 files attempted, 0 failed; 12 .kanban/ files excluded by .reviewignore
    - next: none — task moved to done
  timestamp: 2026-10-21T11:33:04.957482+00:00
- actor: claude-code
  id: 01m5f3sbk1xb20w4qpq6zkw28a
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files (ChangeLog.swift, IDChange.swift, CodedError.swift, GraphQLRun.swift + 3 test files)
    - test: green — swift test, 1403 tests in 137 suites, 0 failed, 0 skipped
    - commit: f126153
    - review: clean — 0 findings
  timestamp: 2026-10-21T11:33:17.537755+00:00
position_column: done
position_ordinal: ffb580
title: 'EXTRAS-10: ChangeLog<Event> and the shared codes NOT_FOUND / RESYNC_REQUIRED'
---
Highest priority: it blocks the `changes` subscription task of every endpoint package (settings, snapshots, sessions, agents, skills, kanban). The Multitool session (foundationmodelsmultitool-bc) coordinates the work and needs the main sha when this lands.

Spec: TestudoApp/features/packages/foundationmodels-extras.md, EXTRAS-9 rules 8 and 9 and EXTRAS-10; decision D115 in features/decisions.md. The consumers agreed these names on their boards (kanban gate 5pf8w1x), so **do not rename them** without telling foundationmodelsmultitool-bc first.

## What to build (Sources/FoundationModelsExtras/GraphQL/)

- `ChangeLog<Event: Sendable>`: an `actor`, with a random epoch for each instance and a buffer of fixed size (the size is an init argument, with a default).
  - `append(_ event:)` stores the event and gives the next cursor and the time (`at`).
  - `cursor` gives the newest cursor (the cursor of an empty log is valid, so `changes(after: cursor)` on an empty log waits for the first event).
  - `changes(after: String?, where: @Sendable (Event) -> Bool = { _ in true })` gives an `AsyncThrowingStream`: first the replay of the buffered events after the cursor, then the live events, in order. The predicate filters each event for this one subscriber after the replay, and keeps the order. `after: nil` means live events only.
  - The stream ends with the `RESYNC_REQUIRED` error when the cursor is not in the buffer any more, has another epoch, is after the newest event, or does not parse.
  - The stream element carries the cursor and the time with the event (for example `ChangeLogEntry<Event> { cursor, at, event }`), so a resolver can fill `cursor` and `at` of `<Noun>Change`.
  - A terminated stream removes its subscriber.
- The cursor is an opaque `String` on the wire (`cursor: String!`, `changes(after: String)`). It encodes the epoch and a sequence number.
- `GraphQLToolkitError` (CodedError.swift) gets `notFound` → `NOT_FOUND` and `resyncRequired` → `RESYNC_REQUIRED`, with messages that tell the caller how to correct the call (query the state again, then subscribe with the new `cursor`).
- Optional, if it fits: a small generic helper for the event shape `<Noun>Change { cursor: String!, at: DateTime!, added: [ID!]!, changed: [ID!]!, removed: [ID!]! }` (one event can hold many ids, for example one reload of a catalog).

## Acceptance criteria

- [x] `append` gives strictly increasing cursors; `cursor` is the newest.
- [x] `changes(after:)` replays the buffered events after the cursor, then the live ones, in order.
- [x] The `where` predicate filters per subscriber and keeps the order, for the replay and the live events.
- [x] RESYNC_REQUIRED for: a cursor that left the buffer, another epoch (a second `ChangeLog` instance), a cursor after the newest event, a cursor that does not parse.
- [x] Two instances have different epochs.
- [x] The new codes are UPPER_SNAKE and in `GraphQLToolkitError`; a RESYNC_REQUIRED that ends a subscription reaches the caller with `extensions.code`.
- [x] Doc comments on each public symbol; tests in Tests/FoundationModelsExtrasTests.

#graphql #priority