---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4zrp3ayy0cx3b5845tmsx63
  text: |-
    Research done.
    - No type that stays uses a type of ModelPool/MessageQueue.swift. Only Mailbox.swift, MailboxTests.swift and README.md name MessageID, MessageQueueDepth, MessageCancellationResult and MessageQueueMutationResult. MailQueue and the Mail types do not use them.
    - MessageID in Sources/OperationsMacros and Tests/OperationsMacrosTests is the SwiftDiagnostics type. It stays.
    - QueueName.mailbox: only Mailbox.swift uses it. QueueTelemetryTests "each queue name and each queue outcome has its fixed raw value" lists its raw value.
    - MailboxTests.swift holds two suites: MailboxTests and MailboxTelemetryTests. Its helpers (TestMailbox, TestPump) are private. No other test file names the removed items.
    - No CHANGELOG file and no DocC catalog in the repo. No other doc comment in Sources links to the removed symbols. Mail.swift names "messageId" of an ACP prompt; that is not our type and stays.
    - README: the intro names Mailbox, and the section "Posting to a session: `Mailbox`" documents it. The README has no table of contents.
    - plan.md names Mailbox in the model pool decision and in the FoundationModelsRouter row.
  timestamp: 2026-10-15T12:30:39.966039+00:00
- actor: claude-code
  id: 01m4zrwzrcccnvb8n0t090k77c
  text: |-
    Implementation done. All changes are deletions or text corrections.
    - Deleted Sources/FoundationModelsExtras/ModelPool/Mailbox.swift (Mailbox, MailboxAnswer).
    - Deleted Sources/FoundationModelsExtras/ModelPool/MessageQueue.swift (MessageID, MessageQueueDepth, MessageCancellationResult, MessageQueueMutationResult).
    - Removed QueueName.mailbox and its doc comment from Telemetry/ExtrasTelemetry.swift.
    - Deleted Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift. It held two suites: "Mailbox: post, inspect, edit, cancel, and the batches of the pump" (MailboxTests) and "Mailbox: the queue metrics of each letter" (MailboxTelemetryTests). No other test file tested only the removed items, so no other test was deleted.
    - QueueTelemetryTests "each queue name and each queue outcome has its fixed raw value": removed "mailbox" from the expected raw values.
    - README.md: removed Mailbox from the intro list, and removed the section "Posting to a session: `Mailbox`". The README has no table of contents.
    - plan.md: the model pool rule now names the pool and the work queue only. The FoundationModelsRouter row now says its mail goes through the MailQueue of this package.
    - Not done: the separate TDD RED run of the changed QueueTelemetryTests expectation. The order permits one build and one full test run only.
    - Note: the validator rule dump for .swift and .md is 754,000 characters. It was too large to read whole. The change has only deletions and text corrections.
  timestamp: 2026-10-15T12:34:25.676208+00:00
- actor: claude-code
  id: 01m4zrx2vra2navdyg8s1h54k1
  text: |-
    ### implement — changed
    - evidence: deleted Sources/FoundationModelsExtras/ModelPool/Mailbox.swift, Sources/FoundationModelsExtras/ModelPool/MessageQueue.swift, Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift; edited Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Tests/FoundationModelsExtrasTests/Telemetry/QueueTelemetryTests.swift, README.md, plan.md. `swift build --build-tests`: Build complete, one warning only ("missing creator for mutated node" for the mlx-swift_Cmlx.bundle dependency product; it comes from the SwiftPM build graph, not from a source file). `swift test` (one run): 1118 tests in 105 suites passed, 0 failures, 0 skipped.
    - next: /review
  timestamp: 2026-10-15T12:34:28.856119+00:00
depends_on:
- 01M4ZRJZ5TX9H33DP2PDNW7R6E
position_column: doing
position_ordinal: '80'
title: 'Mail step 8 T1: remove Mailbox, MailboxAnswer, the MessageQueue types and QueueName.mailbox'
---
Remove these seven public items from FoundationModelsExtras:

- `Mailbox`
- `MailboxAnswer`
- `MessageID`
- `MessageQueueDepth`
- `MessageCancellationResult`
- `MessageQueueMutationResult`
- `QueueName.mailbox`

Keep `MailQueue`, the `Mail` types and `QueueName.mailQueue`.

- [x] If a type in ModelPool/MessageQueue.swift is still used by a type that stays, report it before you remove it.
- [x] Remove the seven items.
- [x] Remove their tests: MailboxTests and each other test that tests only these items. This deletion is decided.
- [x] Remove or correct each doc and comment that names them (README, DocC, CHANGELOG, doc comments).

#mail-step-8