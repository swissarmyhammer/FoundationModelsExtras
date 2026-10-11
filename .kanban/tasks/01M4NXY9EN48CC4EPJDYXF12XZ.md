---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4phdy6tjtpbd77hmefbjd8s
  text: |-
    Research done. Discoveries:
    - `QueueName.toolEvents = "tool_events"` is already in `ExtrasTelemetry.swift`. No new name is necessary.
    - `SerialAsyncChain()` has one production call site: `RunEventFunnel.deliveries` in `ToolRun.swift`. The tests call `SerialAsyncChain()` two times.
    - The funnel calls `deliveries.enqueue` in the actor, on the task of the poster. Thus `QueueTelemetry.enqueued()` gets the metrics factory of the poster (task local), and the ticket keeps it for the delivery `Task`.
    - Plan: an internal `init(telemetry:)`, a private `DeliveryRecord` (telemetry and ticket) that is `nil` for `SerialAsyncChain()`. `enqueued` at enqueue, `started` after the previous delivery ends, `completed(.succeeded)` after the body.
  timestamp: 2026-10-11T22:30:42.650968+00:00
- actor: claude-code
  id: 01m4pj7z21n3g1a21b2tbqb3c5
  text: |-
    Implementation landed.
    - `SerialAsyncChain`: internal `init(telemetry:)`; the public `init()` calls it with `nil`. A private `DeliveryRecord` (recorder and ticket) is made at enqueue on the task of the caller, so the ticket keeps the metrics factory of the caller. The delivery task calls `start()` after the previous delivery ends and `complete()` (outcome `succeeded`) after the body.
    - `RunEventFunnel.deliveries` uses `QueueTelemetry(name: .toolEvents)`. No new name was necessary.
    - TDD: the chain tests failed first (no `init(telemetry:)`); the two funnel tests failed first with `.missingMetric(... queue.name tool_events ...)` and an empty capture. Both pass now.
    - Discovery: five existing tests counted the exact metric records of a tool call. A call that sends an event upstream (a failed call, a timed-out call, a background call with its pending envelope and terminal event) now also records the `tool_events` queue metrics. I put the label sets in `MountFixtures` (`metricLabelsOfOneToolCall`, `metricLabelsOfOneQueue`, `metricLabelsOfACallThatSendsItsTerminal`, `metricLabelsOfASettledBackgroundCall`) and gave `expectOneCall` in `ToolCallSpanTests` and `ExtrasContentSafetyTests` a `metricLabels` parameter. A silent success sends no event, thus it records no `tool_events` metric.
    - Full `swift test`: 979 Swift Testing tests in 90 suites pass (11 known issues, from `withKnownIssue` before this change), and the XCTest runs pass. The only warning is the mlx-swift `missing creator for mutated node` line from the dependency build.
  timestamp: 2026-10-11T22:44:55.489072+00:00
- actor: claude-code
  id: 01m4pj860qcya2djc2btyb19v9
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsExtras/ModelPool/SerialAsyncChain.swift, Sources/FoundationModelsExtras/Hosting/ToolRun.swift, Tests/FoundationModelsExtrasTests/ModelPool/SerialAsyncChainTests.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift, Tests/FoundationModelsExtrasTests/Hosting/MountFixtures.swift, Tests/FoundationModelsExtrasTests/Hosting/ToolCallSpanTests.swift, Tests/FoundationModelsExtrasTests/Telemetry/ExtrasContentSafetyTests.swift (7 paths); `swift test` 979 tests in 90 suites pass, 0 failures.
    - next: /review
  timestamp: 2026-10-11T22:45:02.615048+00:00
- actor: claude-code
  id: 01m4pj8bvtpgkcvjjysx4f3dbf
  text: 'Correction to the step record above: the count is 7 files, not 6. The list of 7 paths is correct.'
  timestamp: 2026-10-11T22:45:08.602036+00:00
depends_on:
- 01M4NXXX8C2BZAAK141DW9063W
position_column: doing
position_ordinal: '80'
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
- [x] `SerialAsyncChain()` compiles with no change at each call site, and records no metric.
- [x] A chain with telemetry records `queue.wait` (enqueue to start), `queue.run` (start to end) and one `queue.tasks` count for each delivery.
- [x] The depth meter is the count of deliveries that did not end, and goes back to 0.
- [x] The chain of `RunEventFunnel` uses `queue.name=tool_events`.

## Tests
- [x] `Tests/FoundationModelsExtrasTests/ModelPool/SerialAsyncChainTests.swift` (the file exists): with `MetricsTestKit` `TestMetrics`, test the depth while a held delivery blocks two later ones, the wait time of a later delivery, and the count. Test that `SerialAsyncChain()` records nothing.
- [x] A funnel test in `Tests/FoundationModelsExtrasTests/Hosting/ToolContextTests.swift` (or `ToolDisplayEventTests.swift`, which already use `RunEventFunnel`): a tool run that posts events records `queue.name=tool_events` counts.
- [x] A content-safety test with `TelemetryCapture.run(forbidding:)` that forbids the event detail.
- [x] `swift test` passes with no warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#telemetry #feature