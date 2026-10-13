---
assignees:
- claude-code
position_column: done
position_ordinal: ff8680
title: 'Mail step 1.7: add QueueName.mailQueue'
---
In Telemetry/ExtrasTelemetry.swift, add `case mailQueue = "mail_queue"` to QueueName, with the doc "The mail queue of a session." Keep `case mailbox` (step 8 removes it). Update the allCases expectation in Tests/FoundationModelsExtrasTests/Telemetry/QueueTelemetryTests.swift.

Done when: swift build and swift test pass for the full Extras package, with no new warnings. Then commit.

Source of truth: /Users/wballard/github/swissarmyhammer/mailbox.md, sections 4, 5, 8. #mail