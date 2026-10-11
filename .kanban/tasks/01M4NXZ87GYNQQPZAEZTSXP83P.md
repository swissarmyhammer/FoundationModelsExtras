---
assignees:
- claude-code
depends_on:
- 01M4NXY9EN48CC4EPJDYXF12XZ
position_column: todo
position_ordinal: '8780'
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
- [ ] A background call whose run fails inside the settle period records one count and one duration, with `tool.outcome=failed`.
- [ ] A call that the run plane settles while the body still runs records the terminal outcome of the run plane, not `succeeded`.
- [ ] Each background span has `tool.settled_inline` set to `true` or `false`.
- [ ] The measured interval and the doc comments of `callInBackground`, `ToolRunKind.background` and `ToolCallSpan.record(outcome:on:)` state the same interval.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift`: with `W3CInMemoryTracer` and `MetricsTestKit` `TestMetrics`, test a run that succeeds inline, a run that fails inline, a run that continues after the settle period (pending envelope), and a run that the sweep settles while its body still runs.
- [ ] A test that the recorded duration agrees with the chosen interval (for example, a run that continues after a long settle period).
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the tool output and the terminal detail.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #bug