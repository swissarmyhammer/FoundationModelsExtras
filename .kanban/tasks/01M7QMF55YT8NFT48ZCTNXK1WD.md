---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qmgyhfyed91v8n6qrabzdb
  text: |-
    Research before the change.

    Dependent tests in sibling packages that expect `messageDelivered` for a queued message at the send (not changed):
    - FoundationModelsMultitool/Tests/FoundationModelsMultitoolTests/SessionsGraphChangesTests.swift:234 — the ActionCase "send to a working session" (prepare calls `startUserTurn`, then sendMessage). The test `eachActionGivesOneChange` (line 254) expects at line 271 that the first change names the target. The change feed maps `.messageDelivered` to a change of `message.to` (Sources/FoundationModelsMultitool/Capabilities/Sessions/SessionsGraphChanges.swift:56). After this change the send to a working target gives no event, thus the first change is the marker and the case fails.
    - No other sibling test reads events after a queued send. ACPAgent, TestudoApp and the other packages do not use InMemorySessionDirectory in tests.

    Router rule (origin/main 709d82c5, RouterSessionDirectory.swift `Registry.awaitingDelivery`, `inbox(of:markRead:)`, `sendDelivered(_:)`, `forgetDeliveries(to:)`; Session/MailFate.swift): the event comes when the pump takes the mail. `inbox(of:markRead: true)` sends the event one time for each marked message that still waits; a later take sends no second event. A cancelled or lost mail, and a message to a session that is archived or unregisters, sends no event.
  timestamp: 2026-11-18T15:31:06.927906+00:00
- actor: claude-code
  id: 01m7qms8kryg1ygndsy8sdfmyn
  text: |-
    Implementation done.

    - A send to a working target stores the message as queued and sends no event. `takeQueuedMessages(of:)` (InMemorySessionDirectoryState.swift) takes the queued messages out of the queue and sends one `messageDelivered` for each, in the order of the sends. `finishTurn` calls it after the idle state event and before the state event of the new turn. `inbox(of:markRead: true)` calls it before it marks the messages read, thus a read of a queued message sends the event one time, and the later turn sends no second event. `archive` clears the queue flags, thus a queued message of an archived session never sends the event (also not at a later inbox read), the same as the Router `forgetDeliveries(to:)`.
    - Docs updated: `SessionDirectoryEvent.messageDelivered`, `SessionDirectory.send` and `inbox`, `InMemorySessionDirectory` (type doc, `send`, `inbox`, `archive`), `finishTurn` test hook, and the internal `deliver`/`record`/`store`/`finishTurn`/`archive`/`inbox` docs.
    - Tests: new file Tests/FoundationModelsExtrasTests/Sessions/InMemorySessionDirectoryDeliveredEventTests.swift (6 tests: no event at a queued send, two queued messages in order, inbox read sends the event, read then turn gives one event, inbox read of a taken message gives no event, archive before the turn gives no event). The existing test "a queued message that is not read starts the next turn when the turn ends" in InMemorySessionDirectoryDeliveryTests.swift now expects `.messageDelivered` between the idle and the working state events. The existing tests `anIdleTargetGetsDelivered` and `aWorkingTargetGetsQueued` cover the idle send and the queued receipt, so the new file does not copy them.
    - Not changed: the sibling test FoundationModelsMultitool/Tests/FoundationModelsMultitoolTests/SessionsGraphChangesTests.swift:234 (case "send to a working session" of `eachActionGivesOneChange`, assertion at line 271) expects a change at a queued send. It will fail with this change; Multitool must update it.
  timestamp: 2026-11-18T15:35:39.384680+00:00
- actor: claude-code
  id: 01m7qmsbpa6qqwyd3fxd2k8j5f
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsExtras/Sessions/{SessionDirectoryEvent,SessionDirectory,InMemorySessionDirectory,InMemorySessionDirectory+TestHooks,InMemorySessionDirectoryState,InMemorySessionDirectoryState+Messages}.swift, Tests/FoundationModelsExtrasTests/Sessions/{InMemorySessionDirectoryDeliveredEventTests (new),InMemorySessionDirectoryDeliveryTests}.swift. `swift test --filter FoundationModelsExtrasTests`: 2039 tests in 195 suites passed, no warnings in changed files. Dependent test not changed: FoundationModelsMultitool/Tests/FoundationModelsMultitoolTests/SessionsGraphChangesTests.swift:234 (assertion :271).
    - next: /review
  timestamp: 2026-11-18T15:35:42.538033+00:00
position_column: doing
position_ordinal: '80'
title: messageDelivered comes when the target takes the message, not when the message goes into the queue
---
The Router (origin/main 709d82c5) now sends `SessionDirectoryEvent.messageDelivered` when the target takes the message. A queued message gives the event when its turn starts, before the first model output. The Router does not send the event when the message goes into the queue. The Extras doc and the in-memory double must agree with the Router.

## Current behavior
- The doc of `messageDelivered` (`Sources/FoundationModelsExtras/Sessions/SessionDirectoryEvent.swift:21-27`) says "The directory put a message in the queue of the target, and the target recorded it."
- `InMemorySessionDirectoryState.record` (`Sessions/InMemorySessionDirectoryState+Messages.swift`, about line 249) sends `messageDelivered` for each message, also for a queued message (`isQueued: true`, receipt `.queued`).
- The end of a turn (`Sessions/InMemorySessionDirectoryState.swift`, about lines 401-415) starts a new turn for the queued messages that are not read, and sends no event for them.

## Work
1. Doc of `messageDelivered`: the event comes when the target takes the message. A message to an idle target gives it at once, when its turn starts. A queued message gives it when the turn for that message starts. A message in the inbox of a recorded session gives no event, as before. Update the docs of `SessionDirectory.send`, `InMemorySessionDirectory` and `record`/`deliver` where they say when the event comes.
2. In-memory directory: a queued message sends no event at the send. When the turn ends and the queued messages that are not read start the next turn, send one `messageDelivered` for each of those messages, in the order of the sends, before the state event of the new turn.
3. A queued message that the target reads with `inbox(of:markRead: true)` before its turn starts: the target took it through the inbox. Decide whether this sends the event, make it the same as the Router (read `FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift` at origin/main), and state the rule in the doc.

## Tests (Swift Testing)
- [x] A send to an idle target gives `messageDelivered` at once (as before).
- [x] A send to a working target gives a `.queued` receipt and no `messageDelivered` at the send.
- [x] When the turn ends, the queued message gives `messageDelivered`, before the state event of the new turn.
- [x] Two queued messages give two events in the order of the sends.
- [x] The inbox rule of work item 3.

## Acceptance
- All tests pass.
- Before the change, search the sibling packages under /Users/wballard/github/swissarmyhammer/ (Multitool, ACPAgent, TestudoApp; skip .build and worktrees) for tests that use InMemorySessionDirectory and expect `messageDelivered` for a queued message at the send. Do not change them. List each with file:line. #at-sessions