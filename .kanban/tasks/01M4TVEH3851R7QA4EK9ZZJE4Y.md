---
assignees:
- claude-code
position_column: done
position_ordinal: ff8780
title: 'Mail step 1.8: add the general MailQueue'
---
Add `public final class MailQueue: Sendable` in Sources/FoundationModelsExtras/Mail/MailQueue.swift: a FIFO queue of Mail with one Mutex and no answers. It has put (duplicate and closed refusal), take(admitting:) with a rule over the candidate and the batch so far, putBack, cancel, replace, a pause counter, drain, close, pending, depthByKind and waitForMail. Telemetry uses the queue name mail_queue. Tests are in Tests/FoundationModelsExtrasTests/Mail/MailQueueTests.swift. Mailbox and the MessageQueue types do not change. #mail