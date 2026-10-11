---
assignees:
- claude-code
depends_on:
- 01M4NXQSMZF2TE7AP0GW9G6HM8
position_column: todo
position_ordinal: '8680'
title: 'Tool-call telemetry: a run-to-completion timeout is not an error, and each call records one count and one duration'
---
## What

The run-to-completion tool telemetry has two problems. (The old parts (a), (c) and (d) of this task are now in other tasks: (a) the bounded outcome mapping is in `w9g6hm8`; (c) the tracer of nested mounts is in `0248sqn`; (d) the timer of `ContextBindingTool` is in `d7te7e3`.)

(b) A timeout is recorded as an error. `RunToCompletionRunner.callToCompletion(arguments:)` (`Sources/FoundationModelsExtras/Hosting/RunToCompletionRunner.swift:34`) says at `:28` that a timeout is not a failure. But `settlement.result.get()` (`:48`) throws `ToolMountError.timedOut`, and `TracedCall` gives the span the error status. A timeout must record `tool.outcome=timed_out` and no error status. The model must still get the same thrown `ToolMountError.timedOut`. Each other error keeps the error status.

(e) A call can record no count and no duration. In `RunToCompletionRunner.callToCompletion`, the outcome comes from `settlement.terminal.outcome`, but that value can be `nil` (a terminal event with no outcome). Each run-to-completion call must record exactly one count and one duration, also when `settlement.terminal.outcome` is `nil`. Choose one fixed outcome for that case (from the shared mapping of task `w9g6hm8`), and state it in the doc comment.

Use the shared bounded outcome mapping of task `w9g6hm8` for each outcome value.

## Acceptance Criteria
- [ ] A run-to-completion call that times out records `tool.outcome=timed_out`, has no error status and no `error.type` on its span, and still throws `ToolMountError.timedOut`.
- [ ] Each other error of a run-to-completion call keeps the error status.
- [ ] Each run-to-completion call records exactly one count and one duration, also when `settlement.terminal.outcome` is `nil`.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift`: with `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, a test for the timeout: `tool.outcome=timed_out`, no error status, no `error.type`, and the thrown `ToolMountError.timedOut`.
- [ ] A test for a terminal event that has no outcome: the call records exactly one count and one duration.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug