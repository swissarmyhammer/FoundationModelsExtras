---
assignees:
- claude-code
depends_on:
- 01M4NXXETD1P6X4V8RMA0XRDQ5
position_column: todo
position_ordinal: '8480'
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
- [ ] Each started run adds 1 to the depth meter, and its settle takes 1 away. The depth is 0 after each run settles.
- [ ] Each run records one `queue.tasks` count with `queue.name=run_plane` and the bounded `queue.outcome` of task `w9g6hm8`, also when the sweep settles the run. A `lost` run records `lost`, not `failed`.
- [ ] Each pending elicitation records one `queue.tasks` count with `queue.name=elicitation` at answer, accept or sweep, and the `elicitation` depth goes back to 0.
- [ ] The wait of an elicitation is not part of the tool-call duration or of the `run_plane` timers.
- [ ] Each run body has one `FoundationModelsExtras.run` span and one "enter" log record, with `tool.name` and the run kind.
- [ ] No metric dimension carries the completion token or the op.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/Hosting/RunPlaneActorTests.swift`: with `MetricsTestKit` `TestMetrics`, test the depth, the timers and the outcome for a run that succeeds, a run that fails, a run that times out, a run that is lost, a run that the sweep settles, and a duplicate token.
- [ ] Tests for the `elicitation` queue: an elicitation that gets an answer, one that is accepted, and one that the sweep removes. Each records one count, and the depth goes back to 0.
- [ ] A span test with `W3CInMemoryTracer`: a body that does not return has an open span and an enter record; a body that returns ends its span.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the progress detail and the terminal detail.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature