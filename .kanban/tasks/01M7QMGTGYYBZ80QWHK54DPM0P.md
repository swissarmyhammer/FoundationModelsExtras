---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qmzwyp5c9nwcy5bpw9sjk1
  text: |-
    Research done.
    - SessionDirectoryEvent uses the synthesized Codable. A new case does not change the JSON of the old cases.
    - InMemorySessionDirectoryState.deliver(_:chainDepth:to:at:) is the one place that makes a `.queued` and a `.sent` receipt (sendToTag also calls it). A `.delivered` and a `.started` receipt go through record(_:chainDepth:to:at:), which sends messageDelivered.
    - Exhaustive switches in this package: Tests/FoundationModelsExtrasTests/Sessions/InMemorySessionDirectoryDeliveryTests.swift kind(of:). No switch in Sources.
    - Existing tests that expect the old behavior: InMemorySessionDirectoryDeliveryTests "a message to a recorded session sends no event and leaves the session recorded" and InMemorySessionDirectoryDeliveredEventTests "a send to a working session sends no messageDelivered at the send" (it expects no event at all).
    - Sibling switches: FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Sessions/SessionsGraphChanges.swift:52 (exhaustive, no default). FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryLauncherTests.swift:90 has `default:`, thus it compiles with the new case. TestudoApp has no switch on the event.
  timestamp: 2026-11-18T15:39:16.822809+00:00
- actor: claude-code
  id: 01m7qn7kxef1qx234sgzqh3mb1
  text: |-
    Implementation landed.
    - RED: the three behavior tests failed with the case added and no emission (recorded target, needs-input target, queued then delivered). The JSON tests and the idle test passed at once: the synthesized Codable keeps the old JSON, and an idle send never queued.
    - GREEN: InMemorySessionDirectoryState.deliver calls a new `enqueue` helper for the `sent` and `queued` paths. It stores the message and sends `messageQueued` before the receipt returns. `record` (delivered, started) is not changed.
    - Two old tests changed their expectation: the recorded-target test now expects `[.messageQueued(m)]`; "a send to a working session sends no messageDelivered at the send" now checks only for no messageDelivered.
    - Sibling exhaustive switches (not changed): FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Sessions/SessionsGraphChanges.swift:52. RouterSessionDirectoryLauncherTests.swift:90 has `default:`. No other switch in TestudoApp, Router or Multitool.
    - Multitool SessionsGraphChangesTests.swift:234 ("send to a working session"): the send now gives one event, messageQueued with `to` == target. A map to (message.to, .changed) gives one change of the target before the marker, thus the test can pass again.
    - The Router directory does not send messageQueued yet. That is the work of the Router package.

    ### implement — changed
    - evidence: swift test --filter FoundationModelsExtrasTests: 2043 tests in 196 suites passed, 0 warnings in changed files. Files: SessionDirectoryEvent.swift, SessionDirectory.swift, InMemorySessionDirectory.swift, InMemorySessionDirectoryState+Messages.swift, SessionDirectoryEventTests.swift, InMemorySessionDirectoryDeliveryTests.swift, InMemorySessionDirectoryDeliveredEventTests.swift, new InMemorySessionDirectoryQueuedEventTests.swift.
    - next: /review
  timestamp: 2026-11-18T15:43:29.710918+00:00
- actor: claude-code
  id: 01m7qnbjys6yc2zpr1d55mywzd
  text: |-
    ### review — clean
    - evidence: review sha ef25070~1..ef25070 — 0 findings, 0 confirmed, 1 refuted (7 attempted, 0 failed). 8 files reviewed. The 4 .kanban files were not reviewed (.reviewignore).
    - next: The task is in done. Do the remaining acceptance steps: push to origin/main, then send the sha and the decision to foundationmodelsrouter-f1, foundationmodelsmultitool-89 and testudoapp-9a.
  timestamp: 2026-11-18T15:45:39.801118+00:00
depends_on:
- 01M7QMF55YT8NFT48ZCTNXK1WD
position_column: done
position_ordinal: fffa80
title: A directory event for a message that goes into the queue or the inbox of a session
---
Request from TestudoApp. Since the Router changed (709d82c5), `messageDelivered` comes only when the target takes the message. The Router writes the queue ledger (a working target) or the inbox file (a recorded target, receipt `sent`) at the send, and no directory event tells this. Thus `Session.unreadCount` of Multitool (it reads `inbox(of:markRead: false).count`) changes, and the `sessions` change feed gets no `changed` entry until the turn starts or the session opens.

## Decision: a new case, not `factsChanged`
`SessionSummary` has no unread count, so `factsChanged(SessionSummary)` would carry a summary with no change. Its doc says "Tags, title, pin or last use changed", so this use would not be true. A new case also gives the host the message. The cost is one more line in each exhaustive switch.

## Work
1. Add `case messageQueued(SessionMessage)` to `SessionDirectoryEvent` (`Sources/FoundationModelsExtras/Sessions/SessionDirectoryEvent.swift`). Doc: the directory put the message in the queue of a working target, or in the inbox of a recorded target. The target did not take it yet. `messageDelivered` comes later, when the target takes it. A message to an idle target that starts its turn at once gives only `messageDelivered`. Make sure that the Codable form of the enum still decodes the old cases.
2. Update the docs of `SessionDirectory.send` and `SessionDirectory.events()`.
3. InMemorySessionDirectory: send `messageQueued` for a `.queued` receipt and for a `sent` (inbox) receipt, at the send, before the receipt returns. Do not send it for a `.delivered` or `.started` receipt.
4. Change each exhaustive `switch` on `SessionDirectoryEvent` in this package.

## Tests (Swift Testing)
- [x] A send to a working target gives `messageQueued` at the send, then `messageDelivered` when its turn starts.
- [x] A send to a recorded target gives `messageQueued` and no `messageDelivered`.
- [x] A send to an idle target gives no `messageQueued`.
- [x] `messageQueued` round-trips through JSON, and the old cases still decode.

## Acceptance
- All tests pass.
- Search the sibling packages under /Users/wballard/github/swissarmyhammer/ (skip .build and worktrees) for each exhaustive `switch` on `SessionDirectoryEvent`, and list each with file:line. Known: `FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Sessions/SessionsGraphChanges.swift:52`. Do not change them.
- When this is on origin/main, send the sha and this decision to foundationmodelsrouter-f1, foundationmodelsmultitool-89 and testudoapp-9a. #at-sessions