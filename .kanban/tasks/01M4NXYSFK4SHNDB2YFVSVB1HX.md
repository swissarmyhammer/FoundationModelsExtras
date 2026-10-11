---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4p23bw5ext19v9mgpyws8n4
  text: |-
    Research done.
    - `TracedCall.run` gives the error status and `error.type` to each error that the body throws. Thus `RunToCompletionRunner.callToCompletion` must not throw a timeout inside the span body. Plan: the body gives the timeout back as a `Result` value, and each other error is still thrown inside the body (it keeps the error status). The runner throws the `Result` after the span ends, so the model gets the same `ToolMountError.timedOut`.
    - `ToolRun.settle` always gives the terminal event an outcome, but `OperationEvent.outcome` is optional. Plan: a new `ToolCallSpan.record(outcomeOf:on:)` records the outcome of a terminal event, and it uses `OperationOutcome.lost` when the event has no outcome ("the outcome is unknowable"). A generic type (`RunToCompletionRunner`) cannot hold a stored `static let`, so the constant goes on `ToolCallSpan`.
    - The test of the nil case calls `ToolCallSpan.record(outcomeOf:on:)` directly, because `ToolRun` has no seam that makes a terminal event with no outcome.
  timestamp: 2026-10-11T18:02:47.557061+00:00
- actor: claude-code
  id: 01m4p2fvtj65nrnjg8txj1vsyt
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsExtras/Hosting/RunToCompletionRunner.swift (the span body gives a timeout back as a `Result` value through the new private `spanResult(of:)`, and the runner throws it after the span ends; it records the outcome with `ToolCallSpan.record(outcomeOf:on:)`), Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift (new `record(outcomeOf:on:)` and `outcomeOfTerminalWithNoOutcome = .lost`), Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift (2 new tests: the timeout, and a terminal event with no outcome; the failure test now also checks the error status and the `error.type`). TDD: the timeout test failed first on `span.status == nil` and `error.type == nil`; the nil-outcome test failed first to compile (no `record(outcomeOf:on:)`). `swift test`: XCTest 381 tests pass; Swift Testing 935 tests in 89 suites pass with 11 known issues that the suites declare; 0 failures; 0 compiler warnings. The only build line is the known "missing creator for mutated node ... mlx-swift_Cmlx.bundle" line of SwiftPM (recorded on ^483vhbg).
    - next: review. Note: `BackgroundToolRunner` can also use `record(outcomeOf:on:)`; task ^z87gyn owns that runner.
  timestamp: 2026-10-11T18:09:37.106446+00:00
depends_on:
- 01M4NXQSMZF2TE7AP0GW9G6HM8
position_column: doing
position_ordinal: '80'
title: 'Tool-call telemetry: a run-to-completion timeout is not an error, and each call records one count and one duration'
---
## What

The run-to-completion tool telemetry has two problems. (The old parts (a), (c) and (d) of this task are now in other tasks: (a) the bounded outcome mapping is in `w9g6hm8`; (c) the tracer of nested mounts is in `0248sqn`; (d) the timer of `ContextBindingTool` is in `d7te7e3`.)

(b) A timeout is recorded as an error. `RunToCompletionRunner.callToCompletion(arguments:)` (`Sources/FoundationModelsExtras/Hosting/RunToCompletionRunner.swift:34`) says at `:28` that a timeout is not a failure. But `settlement.result.get()` (`:48`) throws `ToolMountError.timedOut`, and `TracedCall` gives the span the error status. A timeout must record `tool.outcome=timed_out` and no error status. The model must still get the same thrown `ToolMountError.timedOut`. Each other error keeps the error status.

(e) A call can record no count and no duration. In `RunToCompletionRunner.callToCompletion`, the outcome comes from `settlement.terminal.outcome`, but that value can be `nil` (a terminal event with no outcome). Each run-to-completion call must record exactly one count and one duration, also when `settlement.terminal.outcome` is `nil`. Choose one fixed outcome for that case (from the shared mapping of task `w9g6hm8`), and state it in the doc comment.

Use the shared bounded outcome mapping of task `w9g6hm8` for each outcome value.

## Acceptance Criteria
- [x] A run-to-completion call that times out records `tool.outcome=timed_out`, has no error status and no `error.type` on its span, and still throws `ToolMountError.timedOut`.
- [x] Each other error of a run-to-completion call keeps the error status.
- [x] Each run-to-completion call records exactly one count and one duration, also when `settlement.terminal.outcome` is `nil`.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift`: with `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, a test for the timeout: `tool.outcome=timed_out`, no error status, no `error.type`, and the thrown `ToolMountError.timedOut`.
- [x] A test for a terminal event that has no outcome: the call records exactly one count and one duration.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug