---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4qxb7dx67cy3eg4a0s6p8a2
  text: |-
    Research done.
    - `BackgroundToolRunner.start(arguments:)` throws only at `ownResult.get()`. The terminal event of an inline settle already has the true outcome: `ToolRun.settle` computes it from the result and the stop outcome. A sweep terminal has the canceler outcome (process run) and the latest progress detail, which is the pending envelope text.
    - `RunToCompletionRunner.spanResult(of:)` already holds the timeout rule of ^vsvb1hx (a timeout goes back as a value, so the span gets no error status). Plan: move it to `ToolCallSpan` and use it in both runners, so that no copy exists.
    - Interval choice: the span and the duration cover the start of the run AND the wait up to the settle period. The outcome is known only after the wait, and the span already ends after the wait, so this is the one interval that both can measure. Doc comments of `callInBackground`, `ToolRunKind.background` and `ToolCallSpan.record(outcome:on:)` change to state it.
    - New span attribute key `tool.settled_inline` in `ExtrasTelemetry.AttributeKey`.
  timestamp: 2026-10-12T11:18:11.133156+00:00
- actor: claude-code
  id: 01m4qxkfgp23mv4j6edvf3r458
  text: |-
    Implementation landed (TDD).
    - RED: 6 new tests in ToolCallSpanTests failed for the expected reasons (no `tool.settled_inline`; no metric for a throwing, timed-out or swept call; swept call recorded `succeeded`).
    - GREEN: `start(arguments:)` no longer throws. It returns a private `Answer` (the result, and the terminal event of a run that settled inside the settle period, or nil). `callInBackground` records through the new `ToolCallSpan.record(settledTerminal:on:)` BEFORE it gives the result back, so each call records one count and one duration, also when it throws.
    - Outcome: settled run -> `record(outcomeOf: terminal)` (also for the `terminal.detail` path of a sweep or a process stop; nil outcome -> `lost`). Pending envelope -> new `ToolCallSpan.outcomeOfStartedRun` (`.succeeded`).
    - Timeout rule: `spanResult(of:)` moved from `RunToCompletionRunner` to `ToolCallSpan`; both runners use it. A background timeout inside the settle period gives no error status.
    - Interval: start + wait up to the end of the settle period. Doc comments of `callInBackground`, `ToolRunKind.background`, `record(outcome:on:)` and the `ToolCallSpan` header now state it.
    - Test helpers: `expectBackgroundCall(...)` and `expectSameInterval(...)` in ToolCallSpanTests; the existing slow-report test now uses `expectSameInterval` too (no copy of the timer-vs-span check). Existing test renamed in text only: "a background call that answers at once with the pending envelope gives one count and one duration of success".
    - Content-safety test forbids the tool output (argument marker echoed by FastTool) and the failure detail `String(describing: FixtureError())`.
    - Note: a sweep terminal has the latest progress detail, which is the pending envelope text. The content-safety test cannot forbid it up front (the completion token is not known before the call), and the completion token is a legal attribute of the run span.
  timestamp: 2026-10-12T11:22:41.558033+00:00
- actor: claude-code
  id: 01m4qxkk9hknkfxbjr44g7f7qb
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift, Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift, Sources/FoundationModelsExtras/Hosting/RunToCompletionRunner.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift. `swift test --filter ToolCallSpanTests`: 20/20 pass. `swift test`: 985 tests in 90 suites pass (11 known issues that existed before); the only warning is the mlx-swift "missing creator for mutated node" line.
    - next: /review
  timestamp: 2026-10-12T11:22:45.425568+00:00
depends_on:
- 01M4NXY9EN48CC4EPJDYXF12XZ
position_column: doing
position_ordinal: '80'
title: 'Background tool telemetry: count every call, record the true outcome, and separate the start time from the settle wait'
---
## What

`BackgroundToolRunner.callInBackground(arguments:)` (`Sources/FoundationModelsExtras/Hosting/BackgroundToolRunner.swift:48`) records the tool-call metrics of a background call. It has three problems.

1. A call that throws gives no metric. When the run ends with an error inside the settle period, `start(arguments:)` (`:96`) throws at `try ownResult.get()` (`:135`). Thus `ToolCallSpan.record(outcome: .succeeded, on: call)` (`:53`) does not run, and the call gives no count and no duration.
2. The outcome is not true. `:53` always records `.succeeded`. When the run plane settles the run while its body still runs (a sweep, or a stop of a process), the answer comes from `terminal.detail` (`:133`), but the outcome is still `.succeeded`. A run that the body settles inside the settle period also has its own terminal outcome.
3. The interval does not agree with the doc comment. The duration includes the settle wait (`site.runPlane.wait`, `:122`). `ToolCallSpan.ToolRunKind.background` (`Sources/FoundationModelsExtras/Hosting/ToolCallSpan.swift:32-33`) says that the span and the duration cover only the start, but the doc comment of `callInBackground` (`:42`) says "the start and the wait", and `ToolCallSpan.record(outcome:on:)` (`:95-98`) also says "the start only".

Approach:
- Record each call one time, also when `start` throws: record the outcome before the throw (for example with `defer`, or a `do`/`catch` that records and then throws again).
- Record the true outcome: the terminal outcome when the run settled inside the settle period (from `terminal.outcome`, also for the `terminal.detail` path), the outcome of the thrown error when `start` throws, and `.succeeded` when the call returns the pending envelope (the start succeeded).
- Add the span attribute `tool.settled_inline` (`true` when the run settled inside the settle period, else `false`). Put the key in `ExtrasTelemetry.swift`.
- Choose one interval, and make the code and each doc comment agree. Use the shared bounded outcome mapping of task `w9g6hm8`, so that `.other` gives `other`, and the timeout rule of task `vsvb1hx`, so that a timeout is not an error.

## Acceptance Criteria
- [x] A background call whose run fails inside the settle period records one count and one duration, with `tool.outcome=failed`.
- [x] A call that the run plane settles while the body still runs records the terminal outcome of the run plane, not `succeeded`.
- [x] Each background span has `tool.settled_inline` set to `true` or `false`.
- [x] The measured interval and the doc comments of `callInBackground`, `ToolRunKind.background` and `ToolCallSpan.record(outcome:on:)` state the same interval.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift`: with `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test a run that succeeds inline, a run that fails inline, a run that continues after the settle period (pending envelope), and a run that the sweep settles while its body still runs.
- [x] A test that the recorded duration agrees with the chosen interval (for example, a run that continues after a long settle period).
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the tool output and the terminal detail.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug