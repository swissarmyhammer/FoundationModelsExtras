---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4pcz92g9z2rjm9k4be3s411
  text: |-
    Research done.
    - `RunPlane.settle(_:with:)` is the one exit from `runs`. The sweep and `settleByItself` both call it. A late body of a swept run finds no run, thus it records nothing.
    - Elicitations leave the list at three places: `respond` (`.delivered` path), `complete`, and `sweep`. A URL accept stays in the list.
    - `TracedCall.run` throws only the error of its body. The run body does not throw, but the type needs a `catch`.
    - `start` gets no session tracer. `BackgroundToolRunner` owns `site.tracer`, and the body `Task` inherits the task-local tracer and service context of the caller. Thus the run span uses `InstrumentationSystem.tracer` at call time (tracer `nil`), and it is a child of the tool span. I do not change the signature of `start`, because `BackgroundToolRunner.swift` is outside this task.
    - Reuse: `QueueTelemetry`, `ExtrasTelemetry.telemetryOutcome(of:)`, `ToolCallSpan.outcomeOfTerminalWithNoOutcome` (a terminal with no outcome is `lost`), `QueueMetricDimensions` in the tests.
    - Plan: the elicitation task gets no `started` call. Its wait timer is the user think time, and it records no run time. Outcome: `accept` and `decline` give `succeeded` (the user answered), `cancel` and the sweep give `cancelled`.
  timestamp: 2026-10-11T21:12:47.952353+00:00
- actor: claude-code
  id: 01m4pe1myy7ew04fjzbt528e9v
  text: |-
    Implementation done (TDD: RED run showed each new test fail for the missing telemetry; GREEN run passed).
    - `RunPlane.start` enqueues and starts a `run_plane` ticket after the duplicate-token guard. `settle(_:with:)` completes it with `ExtrasTelemetry.telemetryOutcome(of:)`; a terminal with no outcome gives `lost` through `ToolCallSpan.outcomeOfTerminalWithNoOutcome`.
    - Elicitations: `elicitation` ticket at `awaitAnswer`, never started (the wait timer is the think time, no run timer). One `finish(_:with:)` helper completes it at `respond` (delivered path), `complete`, and `sweep`. Accept and decline give `succeeded`, cancel and the sweep give `cancelled`.
    - Run body runs in `TracedCall.run(ExtrasTelemetry.SpanName.run)` with `tool.name`, `run.kind` and `run.completion_token` as span attributes and log metadata. The `catch` of that call is reachable only by type (the body does not throw): it asserts, logs `error.type`, and settles the run as `lost`.
    - New vocabulary in `ExtrasTelemetry.swift`: `SpanName.run`, `AttributeKey.backgroundRunKind`, `AttributeKey.completionToken`, and the same two `LogMetadataKey` names.
    - Blast radius: two existing tests counted every metric of a background call and broke, because the run plane now adds its `run_plane` metrics. `ToolCallSpanTests.aBackgroundStartGivesItsMetrics` and `ExtrasContentSafetyTests.aBackgroundCallCarriesNoContent` now call `runPlane.joinRunBodies()` inside the capture and expect the tool span plus the run span, and the tool-call metrics plus the queue metrics (shared lists in `MountFixtures`). The tool span and the run span can end in each order, thus those checks sort the names.
    - Not done here, recorded as ^j0tmteq: the run span uses `InstrumentationSystem.tracer`, not `site.tracer`, because `start` gets no tracer and `BackgroundToolRunner.swift` is outside this task.
  timestamp: 2026-10-11T21:31:34.238753+00:00
- actor: claude-code
  id: 01m4pe1qxmq1q7tfh2mxsb1r35
  text: |-
    ### implement — changed
    - evidence: `swift test` — 973 tests in 90 suites passed, 11 known issues (from before), no compiler warning (only the mlx-swift_Cmlx.bundle "missing creator" line from the dependency build). 6 files — Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift, Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift, Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift, Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/ExtrasContentSafetyTests.swift
    - next: /review
  timestamp: 2026-10-11T21:31:37.268258+00:00
depends_on:
- 01M4NXXETD1P6X4V8RMA0XRDQ5
position_column: doing
position_ordinal: '80'
title: 'Queue metrics: RunPlane records the open runs and the timing of each run, and a span covers each run body'
---
## What

`RunPlane` (`Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift:10`) holds each background run, but it records no metric and the run body has no span. A background run that hangs after its settle period shows nothing in the telemetry.

Approach:
- Give the run plane one `QueueTelemetry` with the queue name `run_plane` (from task `w9g6hm8`). A run is one queue task.
  - `start(tool:op:kind:completionToken:canceler:body:)` (`:145`): `enqueued`, then at once `started`, after the duplicate-token guard (`:153-155`). A duplicate token records nothing.
  - `settle(_:with:)` (`:491`): `completed`, with the outcome from the terminal event, mapped with the shared bounded mapping of task `w9g6hm8`: `succeeded`, `failed`, `timed_out`, `stopped`, `cancelled`, `lost` or `other`. Do not collapse an outcome to `failed`. `settle` is the one place where a run leaves `runs`, thus the sweep and the settle by the body both pass through it, and each run records one completion only.
  - The depth is the count of open runs (`runs`).
- Give the run plane a second `QueueTelemetry` with the queue name `elicitation`, for `RunPlane.elicitations` (the actor list of pending elicitations in `RunPlaneActor.swift`). One pending elicitation is one queue task.
  - `enqueued` when an elicitation is appended to the list.
  - `completed` when it leaves the list: at answer, at accept, or at sweep. Each elicitation records one completion only.
  - The depth is the count of pending elicitations.
  - The wait of an elicitation is user think time. Keep it out of the tool latency: do not add it to the tool-call duration or to the `run_plane` timers.
- Open a `TracedCall` span `FoundationModelsExtras.run` around the run body in the `Task` at `:156-160` (around `await body()` at `:157`). Attributes: `tool.name`, the run kind (`RunKind`) and the completion token. The span gives an "enter" log record, so a hung body has an enter record and an open span after its settle period.
- Do not record the completion token or the op as a metric dimension, because the cardinality has no limit. The token can be a span attribute.
- Put each new name in `ExtrasTelemetry.swift`. Make the metric objects at call time. Never record tool arguments, tool output, the progress detail or the elicitation content.
- Keep the contract of `joinRunBodies()` (`:399`): after `sweep()`, it returns only when each run body ended.

## Acceptance Criteria
- [x] Each started run adds 1 to the depth meter, and its settle takes 1 away. The depth is 0 after each run settles.
- [x] Each run records one `queue.tasks` count with `queue.name=run_plane` and the bounded `queue.outcome` of task `w9g6hm8`, also when the sweep settles the run. A `lost` run records `lost`, not `failed`.
- [x] Each pending elicitation records one `queue.tasks` count with `queue.name=elicitation` at answer, accept or sweep, and the `elicitation` depth goes back to 0.
- [x] The wait of an elicitation is not part of the tool-call duration or of the `run_plane` timers.
- [x] Each run body has one `FoundationModelsExtras.run` span and one "enter" log record, with `tool.name` and the run kind.
- [x] No metric dimension carries the completion token or the op.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift`: with `MetricsTestKit` `TestMetrics`, test the depth, the timers and the outcome for a run that succeeds, a run that fails, a run that times out, a run that is lost, a run that the sweep settles, and a duplicate token.
- [x] Tests for the `elicitation` queue: an elicitation that gets an answer, one that is accepted, and one that the sweep removes. Each records one count, and the depth goes back to 0.
- [x] A span test with `W3CInMemoryTracer`: a body that does not return has an open span and an enter record; a body that returns ends its span.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the progress detail and the terminal detail.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature