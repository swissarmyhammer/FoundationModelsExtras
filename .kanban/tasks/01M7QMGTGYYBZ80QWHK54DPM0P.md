---
assignees:
- claude-code
depends_on:
- 01M7QMF55YT8NFT48ZCTNXK1WD
position_column: todo
position_ordinal: '80'
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
- [ ] A send to a working target gives `messageQueued` at the send, then `messageDelivered` when its turn starts.
- [ ] A send to a recorded target gives `messageQueued` and no `messageDelivered`.
- [ ] A send to an idle target gives no `messageQueued`.
- [ ] `messageQueued` round-trips through JSON, and the old cases still decode.

## Acceptance
- All tests pass.
- Search the sibling packages under /Users/wballard/github/swissarmyhammer/ (skip .build and worktrees) for each exhaustive `switch` on `SessionDirectoryEvent`, and list each with file:line. Known: `FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Sessions/SessionsGraphChanges.swift:52`. Do not change them.
- When this is on origin/main, send the sha and this decision to foundationmodelsrouter-f1, foundationmodelsmultitool-89 and testudoapp-9a. #at-sessions