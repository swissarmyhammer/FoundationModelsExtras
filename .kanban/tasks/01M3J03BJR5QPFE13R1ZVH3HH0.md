---
assignees:
- claude-code
position_column: doing
position_ordinal: '80'
title: 'Add tests for ToolRun.stop(using:): a second stop gives the task of the first stop'
---
Sources/FoundationModelsExtras/Hosting/ToolRun.swift:230-240

Coverage: 98.9% (185/187 lines)

Uncovered lines: 233 (line 343 is a closing brace and is not a gap)

`func stop(using canceler: @escaping @Sendable () async -> OperationOutcome) -> Task<OperationOutcome, Never>`

The first call starts the canceler in a task and keeps the task. A second call must return the same task and must not run the canceler again (line 233). No test calls `stop` two times.

What to test:
- Call `stop(using:)` two times on one run, with a canceler that counts its calls. Both calls give the same outcome, and the canceler ran one time.
- Also through the public path: cancel one `.process` background run two times (for example, `ToolContext.cancel` and a timeout). The process canceler runs one time. #coverage-gap