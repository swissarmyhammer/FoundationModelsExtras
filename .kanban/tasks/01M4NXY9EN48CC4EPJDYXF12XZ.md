---
assignees:
- claude-code
depends_on:
- 01M4NXXX8C2BZAAK141DW9063W
position_column: todo
position_ordinal: '8580'
title: 'Queue metrics: the tool event delivery chain (SerialAsyncChain in RunEventFunnel) records depth and delivery timing'
---
## What

`RunEventFunnel` sends each event of a tool run upstream through a `SerialAsyncChain` (`Sources/FoundationModelsExtras/Hosting/ToolRun.swift:287`, `private var deliveries = SerialAsyncChain()`; the funnel calls `deliveries.enqueue` at `:396`). A slow upstream sink makes the chain grow, but no metric shows it.

Files:
- `Sources/FoundationModelsExtras/ModelPool/SerialAsyncChain.swift` (public struct, `:6`; `enqueue(body:)` at `:17`).
  - Add an optional `QueueTelemetry` (task `w9g6hm8`). `QueueTelemetry` is internal, thus add an internal init `init(telemetry: QueueTelemetry?)`, or an internal stored property, and keep the public `init()` with no telemetry.
  - In `enqueue(body:)`: `enqueued` before the `Task` starts; `started` after `await previous?.value` (`:20`); `completed` with `succeeded` after `await body()` (`:21`). The body does not throw, so a delivery always succeeds.
- `Sources/FoundationModelsExtras/Hosting/ToolRun.swift:287`: make the chain of `RunEventFunnel` with the queue name `tool_events`.
- Put each new name in `ExtrasTelemetry.swift`. Make the metric objects at call time. Never record the event, the detail or the display content.

## Acceptance Criteria
- [ ] `SerialAsyncChain()` compiles with no change at each call site, and records no metric.
- [ ] A chain with telemetry records `queue.wait` (enqueue to start), `queue.run` (start to end) and one `queue.tasks` count for each delivery.
- [ ] The depth meter is the count of deliveries that did not end, and goes back to 0.
- [ ] The chain of `RunEventFunnel` uses `queue.name=tool_events`.

## Tests
- [ ] `Tests/FoundationModelsExtrasTests/ModelPool/SerialAsyncChainTests.swift` (the file exists): with `MetricsTestKit` `TestMetrics`, test the depth while a held delivery blocks two later ones, the wait time of a later delivery, and the count. Test that `SerialAsyncChain()` records nothing.
- [ ] A funnel test in `Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift` (or `ToolDisplayEventTests.swift`, which already use `RunEventFunnel`): a tool run that posts events records `queue.name=tool_events` counts.
- [ ] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the event detail.
- [ ] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature