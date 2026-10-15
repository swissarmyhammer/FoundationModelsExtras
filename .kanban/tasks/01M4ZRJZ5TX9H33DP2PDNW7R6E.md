---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4zrma72ahfy0kx686nx0d28
  text: |-
    ### T0 inventory — done
    Search: every package under /Users/wballard/github/swissarmyhammer, all files, not .build, checkouts or .kanban.

    Outside Extras: no code uses one of the seven items.
    - EditorKit Sources/EditorMacrosPlugin/PlaceholderMacro.swift:98-99 and Tests/EditorMacrosTests/EditorKitMacroErrorTests.swift:7,65: `MessageID` is the SwiftDiagnostics type of swift-syntax. It stays.
    - FoundationModelsRouter/generation-queue.md:98,255,267,269,271,272,348: an old plan document names `MessageID` and `MessageCancellationResult` as history. No code.
    - mailbox.md (the plan) and the .sah and .shell logs: text only.

    Inside Extras:
    - Sources/FoundationModelsExtras/ModelPool/Mailbox.swift (Mailbox, MailboxAnswer).
    - Sources/FoundationModelsExtras/ModelPool/MessageQueue.swift (MessageID, MessageQueueMutationResult, MessageCancellationResult, MessageQueueDepth). No other type uses them.
    - Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift:557-558 (`QueueName.mailbox`).
    - Tests/FoundationModelsExtrasTests/ModelPool/MailboxTests.swift (the whole file).
    - Tests/FoundationModelsExtrasTests/Telemetry/QueueTelemetryTests.swift:130 (the list of queue names has "mailbox").
    - README.md:16 and the section "Posting to a session: `Mailbox`" (lines 778-836).
    - plan.md:305, 307, 343 (names `Mailbox` in the scope text).
    - Stays: Sources/OperationsMacros/OperationsMacros.swift and Tests/OperationsMacrosTests/OperationMacroTests.swift (`MessageID` of swift-syntax); Mail.swift:19 (`messageId` of ACP).
  timestamp: 2026-10-15T12:29:41.474120+00:00
position_column: done
position_ordinal: ff8d80
title: 'Mail step 8 T0: inventory of each use of the old mailbox types in the family packages'
---
Search every family package under /Users/wballard/github/swissarmyhammer (Sources, Tests, IntegrationTests, Examples, Tools, docs, README, DocC; not .build) for each use of these items:

- `Mailbox`
- `MailboxAnswer`
- `MessageID`
- `MessageQueueDepth`
- `MessageCancellationResult`
- `MessageQueueMutationResult`
- `QueueName.mailbox`

`MessageID` in OperationsMacros (Sources/OperationsMacros/OperationsMacros.swift:46 and Tests/OperationsMacrosTests) is the SwiftDiagnostics type of swift-syntax. It is not ours, and it stays.

- [ ] Search all family packages.
- [ ] Record each use, with file and line.
- [ ] Report each use outside Extras before T1 starts.

#mail-step-8